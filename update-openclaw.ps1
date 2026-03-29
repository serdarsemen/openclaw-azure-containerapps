# ---------------------------------------------------------------------------
# update-openclaw.ps1 — Update the OpenClaw image without regenerating tokens or config
#
# Prerequisites: OpenClaw already deployed via deploy-openclaw.ps1
# What this does:
#   1. Pulls latest OpenClaw source (or checks out a pinned tag)
#   2. Rebuilds the container image remotely via az acr build
#   3. Updates the Container App via a full YAML template (preserves existing
#      secrets, env vars, NFS volume, probes, and startup commands)
#
# Existing gateway token, OpenClaw config, .md files, and auth state on
# the NFS volume (/home/node/.openclaw) are preserved.
#
# Usage:
#   .\update-openclaw.ps1 -ResourceGroup rg-openclaw
#   .\update-openclaw.ps1 -ResourceGroup rg-openclaw -Tag v2026.2.15
# ---------------------------------------------------------------------------

param(
    [Parameter(Mandatory)] [string] $ResourceGroup = "rg-openclaw",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = ""
)

$ErrorActionPreference = "Stop"


# --- Discover resource names from Bicep deployment outputs ---
Write-Host "`n=== Discovering resources from Bicep deployment ===" -ForegroundColor Cyan
$AcrName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$AppName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.appName.value" -o tsv 2>$null

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was main.bicep deployed to '$ResourceGroup'?"
}
Write-Host "  ACR:  $AcrName" -ForegroundColor Green
Write-Host "  App:  $AppName" -ForegroundColor Green

# --- Step 1: Update OpenClaw source ---
Write-Host "`n=== Step 1/3: Updating OpenClaw source ===" -ForegroundColor Cyan

if (-not (Test-Path $SourcePath)) {
    Write-Host "  Source not found — cloning..."
    git clone https://github.com/openclaw/openclaw.git $SourcePath
    if ($LASTEXITCODE -ne 0) { throw "Git clone failed" }
}

Push-Location $SourcePath
try {
    if ($Tag) {
        Write-Host "  Fetching tags and checking out: $Tag"
        git fetch --tags
        if ($LASTEXITCODE -ne 0) { throw "Git fetch failed" }
        git checkout $Tag
        if ($LASTEXITCODE -ne 0) { throw "Git checkout '$Tag' failed" }
    } else {
        Write-Host "  Pulling latest from main..."
        git checkout main
        if ($LASTEXITCODE -ne 0) { throw "Git checkout 'main' failed" }
        git pull origin main
        if ($LASTEXITCODE -ne 0) { throw "Git pull failed" }
    }
} finally {
    Pop-Location
}

$ref = if ($Tag) { $Tag } else { "latest (main)" }
Write-Host "  Source updated to: $ref" -ForegroundColor Green

# --- Step 2: Rebuild image in ACR ---
Write-Host "`n=== Step 2/3: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
Write-Host "This uploads source to Azure and builds remotely (~6 min)..."

$env:PYTHONIOENCODING = "utf-8"

# Two-step build: base OpenClaw image, then layer with pre-baked tools
# Patch Dockerfile for ACR Tasks compatibility: strip BuildKit --mount directives.
# ACR Tasks uses the classic Docker builder; --mount=type=cache is unsupported and
# provides no benefit on ACR's ephemeral build agents anyway.
$AcrDockerfile = Join-Path $SourcePath "Dockerfile.acr"
(Get-Content "$SourcePath/Dockerfile" -Raw) `
    -replace '--mount=type=cache,\S+\s*', '' `
    -replace '(?m)^\s+\\\r?\n', '' |
    Set-Content $AcrDockerfile -Encoding utf8
Write-Host "  Patched Dockerfile for ACR compatibility" -ForegroundColor Gray

Write-Host "  Step 2a: Building base OpenClaw image (~6 min)..." -ForegroundColor Gray
az acr build `
    --registry $AcrName `
    --image openclaw:base `
    --file $AcrDockerfile `
    $SourcePath

$buildExitCode = $LASTEXITCODE
Remove-Item $AcrDockerfile -ErrorAction SilentlyContinue
if ($buildExitCode -ne 0) { throw "Base image build failed" }
Write-Host "  Base image pushed to $AcrName.azurecr.io/openclaw:base" -ForegroundColor Green

$AcrServer = "$AcrName.azurecr.io"

Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog)..." -ForegroundColor Gray
az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --build-arg "BASE_IMAGE=$AcrServer/openclaw:base" `
    --file "images/Dockerfile.tools" `
    images

if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green

# --- Step 3/3: Update container app via YAML (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App via YAML ===" -ForegroundColor Cyan

# Discover existing environment, resources, and secrets from the running app (single API call)
$appInfo = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "{envId:properties.managedEnvironmentId, cpu:properties.template.containers[0].resources.cpu, mem:properties.template.containers[0].resources.memory}" -o json 2>$null | ConvertFrom-Json
if (-not $appInfo -or -not $appInfo.envId) { throw "Failed to query Container App '$AppName'" }
$envId = $appInfo.envId
$envName = $envId.Split("/")[-1]

# Ensure my-d4-profile workload profile exists on the environment
$existingProfiles = az containerapp env workload-profile list `
    --resource-group $ResourceGroup --name $envName `
    --query "[?name=='my-d4-profile'].name" -o tsv 2>$null
if (-not $existingProfiles) {
    Write-Host "Adding D4 workload profile to environment $envName..." -ForegroundColor Yellow
    az containerapp env workload-profile add `
        --resource-group $ResourceGroup --name $envName `
        --workload-profile-type D4 --workload-profile-name "my-d4-profile" `
        --min-nodes 1 --max-nodes 3
    if ($LASTEXITCODE -ne 0) { throw "Failed to add D4 workload profile" }
    Write-Host "D4 workload profile added" -ForegroundColor Green
}

# Redis sidecar: 0.25 CPU / 0.5Gi, Ollama sidecar: 2.25 CPU / 12Gi — cap OpenClaw within D4 profile (4 CPU / 16Gi)
$redisCpu = 0.25; $redisMem = 0.5; $ollamaCpu = 2.25; $ollamaMem = 12.0
$sidecarCpu = $redisCpu + $ollamaCpu; $sidecarMem = $redisMem + $ollamaMem
$maxCpu = 4.0
$maxMem = 16.0
$currentCpu = if ($appInfo.cpu) { [math]::Min([double]$appInfo.cpu, $maxCpu - $sidecarCpu) } else { $maxCpu - $sidecarCpu }
$currentMem = if ($appInfo.mem) {
    $memVal = [double]($appInfo.mem -replace '[^0-9.]','')
    "$([math]::Min($memVal, $maxMem - $sidecarMem))Gi"
} else { "$($maxMem - $sidecarMem)Gi" }

$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null
if (-not $StorageName) { throw "No NFS storage found on environment $envName" }

# Retrieve existing secrets so the YAML preserves them
$AcrCreds = az acr credential show --name $AcrName 2>$null | ConvertFrom-Json
if (-not $AcrCreds) { throw "Failed to get ACR credentials for $AcrName" }
$AcrUsername = $AcrCreds.username
$AcrPassword = $AcrCreds.passwords[0].value

$GatewayToken = az containerapp secret show --name $AppName --resource-group $ResourceGroup `
    --secret-name gateway-token --query "value" -o tsv 2>$null
if (-not $GatewayToken) { throw "Could not read existing gateway-token secret" }

$GroqApiKey = az containerapp secret show --name $AppName --resource-group $ResourceGroup `
    --secret-name groq-api-key --query "value" -o tsv 2>$null
if (-not $GroqApiKey) { Write-Host "  Warning: groq-api-key secret not found — will be empty" -ForegroundColor Yellow; $GroqApiKey = "" }

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

# chmod -R 700 /home/node/.openclaw && fails on NFS disk

$updateYaml = @"
properties:
  managedEnvironmentId: $envId
  workloadProfileName: my-d4-profile
  configuration:
    ingress:
      external: true
      targetPort: 18789
      transport: http
    registries:
    - server: $AcrServer
      username: $AcrUsername
      passwordSecretRef: acr-password
    secrets:
    - name: acr-password
      value: $AcrPassword
    - name: gateway-token
      value: $GatewayToken
    - name: groq-api-key
      value: $GroqApiKey
  template:
    containers:
    - name: $AppName
      image: $AcrServer/openclaw:latest
      command:
      - sh
      - -c
      - >-
        chmod -R 755 /app/extensions &&
        mkdir -p /home/node/.openclaw/workspace/memory &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) &&
        (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
      resources:
        cpu: $currentCpu
        memory: $currentMem
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: OLLAMA_HOST
        value: http://localhost:11434
      - name: GROQ_API_KEY
        secretRef: groq-api-key
      - name: NODE_ENV
        value: production
      - name: HOME
        value: /home/node
      - name: TERM
        value: xterm-256color
      - name: OPENCLAW_BUNDLED_PLUGINS_DIR
        value: /app/extensions
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/node/.openclaw
      probes:
      - type: startup
        tcpSocket:
          port: 18789
        initialDelaySeconds: 5
        periodSeconds: 10
        failureThreshold: 30
      - type: liveness
        tcpSocket:
          port: 18789
        periodSeconds: 30
    - name: redis
      image: redis:7-alpine
      command:
      - redis-server
      - --appendonly
      - "yes"
      - --dir
      - /data
      resources:
        cpu: 0.25
        memory: 0.5Gi
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /data
      probes:
      - type: liveness
        tcpSocket:
          port: 6379
        periodSeconds: 30
    - name: ollama
      image: ollama/ollama:latest
      command:
      - /bin/sh
      - -c
      - "ollama serve & sleep 10 && ollama pull qwen2.5-coder:14b && ollama pull deepseek-r1:14b && ollama pull phi4:14b; wait"
      resources:
        cpu: 2.25
        memory: 12Gi
      env:
      - name: OLLAMA_HOST
        value: 0.0.0.0:11434
      - name: OLLAMA_MODELS
        value: /home/ollama/.ollama/models
      - name: HOME
        value: /home/ollama
      probes:
      - type: liveness
        httpGet:
          path: /
          port: 11434
        periodSeconds: 30
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/ollama/.ollama
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@

$updateYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

Write-Host "Container App updated via YAML" -ForegroundColor Green

# Wait for the container to become ready
Write-Host "`nWaiting for container to become ready..."
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $latestRev = az containerapp show --name $AppName --resource-group $ResourceGroup `
        --query "properties.latestRevisionName" -o tsv 2>$null
    $running = az containerapp revision show --name $AppName --revision $latestRev --resource-group $ResourceGroup `
        --query "properties.runningState" -o tsv 2>$null
    if ($running -in "Running", "RunningAtMaxScale") {
        Write-Host "  Container is running (attempt $attempt/$maxAttempts)" -ForegroundColor Green
        break
    }
    Write-Host "  Not ready yet (state: $running) — retrying in 10s ($attempt/$maxAttempts)..."
    Start-Sleep -Seconds 10
}
if ($running -notin "Running", "RunningAtMaxScale") {
    Write-Warning "Container did not reach Running state after $maxAttempts attempts — proceeding anyway"
}

$rev = $latestRev
$img = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.template.containers[0].image" -o tsv 2>$null

# --- Post-update: Show recent container logs ---
Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Write-Host "  Current revision: $rev (image: $img)" -ForegroundColor Green
az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 60 2>$null

Write-Host "`n=== Update complete ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null


az containerapp revision list  --name $AppName --resource-group $ResourceGroup  -o table

Write-Host "  OpenClaw updated to: $ref image: $img" -ForegroundColor Green
Write-Host "  App restarted with new image, FQDN: $fqdn"
Write-Host ""
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Control UI: https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "Your gateway token, config, and data are unchanged." -ForegroundColor Green
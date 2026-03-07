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
    [Parameter(Mandatory)] [string] $ResourceGroup,
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
Write-Host "  Step 2a: Building base OpenClaw image (~6 min)..." -ForegroundColor Gray
az acr build `
    --registry $AcrName `
    --image openclaw:base `
    --file "$SourcePath/Dockerfile" `
    $SourcePath

if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
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
# Ollama sidecar uses 1.0 CPU / 2Gi; cap OpenClaw so the total stays within Consumption tier limits (4 CPU / 8Gi)
$ollamaCpu = 1.0
$ollamaMem = 2.0
$maxCpu = 4.0
$maxMem = 8.0
$currentCpu = if ($appInfo.cpu) { [math]::Min([double]$appInfo.cpu, $maxCpu - $ollamaCpu) } else { $maxCpu - $ollamaCpu }
$currentMem = if ($appInfo.mem) {
    $memVal = [double]($appInfo.mem -replace '[^0-9.]','')
    "$([math]::Min($memVal, $maxMem - $ollamaMem))Gi"
} else { "$($maxMem - $ollamaMem)Gi" }

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

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

# chmod -R 700 /home/node/.openclaw && fails on NFS disk

$updateYaml = @"
properties:
  managedEnvironmentId: $envId
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
    - name: ollama
      image: ollama/ollama:latest
      resources:
        cpu: 1.0
        memory: 2Gi
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
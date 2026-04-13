# ---------------------------------------------------------------------------
# deploy-openclaw.ps1 — Build and deploy OpenClaw to an existing ACA environment
#
# Variant: SOURCE BUILD (lightweight)
#   - Builds from the OpenClaw Git repo Dockerfile
#   - Two containers: OpenClaw gateway + Ollama sidecar
#   - Default resources: 1.5 vCPU / 2 GiB (OpenClaw) + 0.25 vCPU / 0.5 GiB (Redis)
#                        + 2.25 vCPU / 5.5 GiB (Ollama) [Consumption profile: 4 vCPU / 8 GiB]
#   - Bicep template: main.bicep (deployment name: "main")
#   - Home directory: /home/node
#   - Ollama enables local model inference
#
# See also: deploy-openclawnpm.ps1 for the npm-based variant with Redis + Ollama
#
# Prerequisites: infrastructure deployed via main.bicep (placeholder container running)
# What this does:
#   1. Auto-discovers ACR and App names from the Bicep deployment outputs
#   2. Clones OpenClaw source (if not already present)
#   3. Builds OpenClaw image from source and pushes to ACR
#   4. Generates a gateway auth token
#   5. Updates the Container App with OpenClaw image, NFS mount, and full config
#   6. Configures gateway non-interactively (onboard, model, Control UI)
#
# Usage (no names needed — auto-discovered from Bicep outputs):
#   .\deploy-openclaw.ps1 -ResourceGroup rg-openclaw
# ---------------------------------------------------------------------------

param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = "",  # Optional Git tag or branch to check out (default: latest main)
    [string] $Cpu = "1.5",
    [string] $Memory = "2Gi",
    [string] $GroqApiKey = ""  # Groq API key — passed as a secret, never hardcoded
)

$ErrorActionPreference = "Stop"

# Redis sidecar: 0.25 CPU / 0.5Gi, Ollama sidecar: 2.25 CPU / 5.5Gi — validate total <= 4 CPU / 8Gi
$redisCpu = 0.25; $redisMem = 0.5; $ollamaCpu = 2.25; $ollamaMem = 5.5
$totalCpu = [double]$Cpu + $redisCpu + $ollamaCpu
$totalMem = [double]($Memory -replace '[^0-9.]','') + $redisMem + $ollamaMem
if ($totalCpu -gt 4.0 -or $totalMem -gt 8.0) {
    throw "Total resources (CPU: $totalCpu, Memory: ${totalMem}Gi) exceed Consumption profile max (4 CPU / 8Gi). Reduce -Cpu/-Memory to account for Redis (0.25 CPU / 0.5Gi) + Ollama (2.25 CPU / 5.5Gi) sidecars."
}

# Auto-discover resource names from Bicep deployment outputs
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

Write-Host "`n=== Step 1/6: Cloning OpenClaw source ===" -ForegroundColor Cyan

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


Write-Host "`n=== Step 2/6: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
Write-Host "This uploads source to Azure and builds remotely..."

# Fix Unicode crash: az acr build streams pnpm progress output with Unicode
# characters that crash Python's charmap codec on Windows (cp1252).
$env:PYTHONIOENCODING = "utf-8"

# Export tracked files only into a clean temp context to avoid uploading untracked/modified files.
$BuildContextDir = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-acr-context-" + [System.IO.Path]::GetRandomFileName())
$ArchivePath = "$BuildContextDir.zip"
New-Item -ItemType Directory -Path $BuildContextDir | Out-Null

try {
    git -C $SourcePath archive --format=zip --output $ArchivePath HEAD
    if ($LASTEXITCODE -ne 0) { throw "Failed to export source archive for ACR build context" }

    Expand-Archive -Path $ArchivePath -DestinationPath $BuildContextDir -Force
    Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
    Write-Host "  Prepared clean ACR build context from tracked source files" -ForegroundColor Gray

    # Patch Dockerfile for ACR Tasks compatibility: strip BuildKit --mount directives
    # and suppress pnpm self-update checks that can stall headless builds.
    $AcrDockerfile = Join-Path $BuildContextDir "Dockerfile.acr"
    (Get-Content (Join-Path $BuildContextDir "Dockerfile") -Raw) `
        -replace '--mount=type=cache,\S+\s*', '' `
        -replace 'pnpm install --frozen-lockfile', 'PNPM_DISABLE_SELF_UPDATE_CHECK=1 pnpm install --frozen-lockfile' `
        -replace 'CI=true\s+pnpm prune --prod', 'CI=true PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
        -replace 'CI=true PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod', 'CI=true PNPM_DISABLE_SELF_UPDATE_CHECK=1 PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
        -replace '(?m)^\s+\\\r?\n', '' |
        Set-Content $AcrDockerfile -Encoding utf8
    Write-Host "  Patched Dockerfile for ACR compatibility" -ForegroundColor Gray

    Write-Host "  Step 2a: Building base OpenClaw image (~6 min)..." -ForegroundColor Gray
    az acr build `
        --registry $AcrName `
        --image openclaw:base `
        --file $AcrDockerfile `
        $BuildContextDir

    if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    Write-Host "  Base image pushed to $AcrName.azurecr.io/openclaw:base" -ForegroundColor Green
}
finally {
    Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
    Remove-Item $BuildContextDir -Recurse -Force -ErrorAction SilentlyContinue
}

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

Write-Host "`n=== Step 3/6: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "Token generated (save this for Control UI access):"
Write-Host "  $GatewayToken" -ForegroundColor Yellow

Write-Host "`n=== Step 4/6: Updating Container App with OpenClaw ===" -ForegroundColor Cyan

$AcrCreds = az acr credential show --name $AcrName 2>$null | ConvertFrom-Json
if (-not $AcrCreds) { throw "Failed to get ACR credentials for $AcrName" }
$AcrUsername = $AcrCreds.username
$AcrPassword = $AcrCreds.passwords[0].value

# Get environment name and storage name from the Container App
$envId = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.managedEnvironmentId" -o tsv 2>$null
if (-not $envId) { throw "Failed to get environment ID for $AppName" }
$envName = $envId.Split("/")[-1]

# Ensure Consumption workload profile exists on the environment (it should by default)
$existingProfiles = az containerapp env workload-profile list `
    --resource-group $ResourceGroup --name $envName `
    --query "[?name=='Consumption'].name" -o tsv 2>$null
if (-not $existingProfiles) {
    throw "Consumption workload profile not found on environment $envName"
}

$StorageName= az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null
if (-not $StorageName) { throw "No NFS storage found on environment $envName. Was main.bicep deployed?" }

# Volume name for the YAML — this is a local alias, not an Azure resource name
$volumeName = "openclaw-state"

# Build the updated YAML for the Container App
$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")
# chmod -R 700 /home/node/.openclaw && fails on NFS disk
$updatedYaml = @"
properties:
  managedEnvironmentId: $envId
  workloadProfileName: Consumption
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
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: REDIS_HOST
        value: localhost
      - name: REDIS_PORT
        value: "6379"
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
      - "ollama serve & sleep 10 && ollama pull qwen2.5-coder:7b && ollama pull deepseek-r1:7b && ollama pull phi4-mini; wait"
      resources:
        cpu: 2.25
        memory: 5.5Gi
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

$updatedYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

# Wait for the container to become ready (poll instead of fixed sleep)
Write-Host "`nWaiting for container to become ready..."
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $status = az containerapp show --name $AppName --resource-group $ResourceGroup `
        --query "properties.latestRevisionName" -o tsv 2>$null
    $running = az containerapp revision show --revision $status --resource-group $ResourceGroup --name $AppName `
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

Write-Host "`n=== Step 5/6: Configuring OpenClaw (non-interactive) ===" -ForegroundColor Cyan

# Retry helper — ACA exec can fail with ClusterExecFailure while the gateway
# process is still initialising inside the container.  Retry up to $MaxRetries
# times with a delay between attempts.
function Invoke-ContainerExec {
    param(
        [string] $Label,
        [string] $Command,
        [int]    $MaxRetries = 3,
        [int]    $DelaySec   = 15
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "  [$Label] attempt $i/$MaxRetries" -ForegroundColor Gray
        az containerapp exec --name $AppName --resource-group $ResourceGroup --command $Command
        if ($LASTEXITCODE -eq 0) { return }
        if ($i -lt $MaxRetries) {
            Write-Host "  [$Label] exec failed — retrying in ${DelaySec}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySec
        }
    }
    Write-Warning "[$Label] failed after $MaxRetries attempts (exit $LASTEXITCODE)"
}

# Configure gateway — use the OPENCLAW_GATEWAY_TOKEN env var already set in the container
# to avoid leaking the token in process arguments
Invoke-ContainerExec -Label "Onboard" `
    -Command "bash -c 'node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token \$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health'"

# Set model
Invoke-ContainerExec -Label "Model set" `
    -Command "node openclaw.mjs models set github-copilot/claude-opus-4.6"

# Run security check
Invoke-ContainerExec -Label "Security audit" `
    -Command "node openclaw.mjs security audit"

# GitHub Copilot auth (interactive — only 1 attempt since user must interact)
az containerapp exec --name $AppName --resource-group $ResourceGroup `
    --command "node openclaw.mjs models auth login-github-copilot"
if ($LASTEXITCODE -ne 0) { Write-Warning "GitHub Copilot auth failed (exit $LASTEXITCODE) — complete manually via 'az containerapp exec'" }





Write-Host "`n=== Step 6/6: Gateway configured ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                 │" -ForegroundColor Yellow
Write-Host "  │  $GatewayToken   │" -ForegroundColor Yellow
Write-Host "  └─────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "OpenClaw URL: https://$fqdn"
Write-Host "Control UI:   https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "=== One manual step remaining: GitHub Copilot auth ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Connect to container:" -ForegroundColor Yellow
Write-Host "   az containerapp exec --name $AppName --resource-group $ResourceGroup"
Write-Host ""
Write-Host "2. Inside the container:" -ForegroundColor Yellow
Write-Host "   node openclaw.mjs models auth login-github-copilot" -ForegroundColor White
Write-Host "   (open browser, enter code, authorize, then type: exit)"
Write-Host ""
Write-Host "3. Open Control UI:" -ForegroundColor Yellow
Write-Host "   https://$fqdn/#token=$GatewayToken"

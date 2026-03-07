# ---------------------------------------------------------------------------
# deploy-openclaw.ps1 — Build and deploy OpenClaw to an existing ACA environment
#
# Variant: SOURCE BUILD (lightweight)
#   - Builds from the OpenClaw Git repo Dockerfile
#   - Two containers: OpenClaw gateway + Ollama sidecar
#   - Default resources: 4 vCPU / 8 GiB (OpenClaw) + 1 vCPU / 2 GiB (Ollama)
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
    [string] $Cpu = "3.0",
    [string] $Memory = "6Gi"
)

$ErrorActionPreference = "Stop"

# Ollama sidecar uses 1.0 CPU / 2Gi; validate that total stays within Consumption tier limits (4 CPU / 8Gi)
$ollamaCpu = 1.0; $ollamaMem = 2.0
$totalCpu = [double]$Cpu + $ollamaCpu
$totalMem = [double]($Memory -replace '[^0-9.]','') + $ollamaMem
if ($totalCpu -gt 4.0 -or $totalMem -gt 8.0) {
    throw "Total resources (CPU: $totalCpu, Memory: ${totalMem}Gi) exceed Consumption tier max (4 CPU / 8Gi). Reduce -Cpu/-Memory to account for Ollama sidecar (1.0 CPU / 2Gi)."
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

$StorageName = az containerapp env storage list `
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
        cpu: $Cpu
        memory: $Memory
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

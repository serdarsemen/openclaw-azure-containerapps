# ---------------------------------------------------------------------------
# deploy-openclaw.ps1 — Build and deploy OpenClaw to an existing ACA environment
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
    [string] $Cpu = "2.0",
    [string] $Memory = "4Gi"
)

$ErrorActionPreference = "Stop"

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

if (Test-Path $SourcePath) {
    Write-Host "  $SourcePath already exists, skipping clone"
} else {
    git clone https://github.com/openclaw/openclaw.git $SourcePath
    if ($LASTEXITCODE -ne 0) { throw "Git clone failed" }
}

Write-Host "`n=== Step 2/6: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
Write-Host "This uploads source to Azure and builds remotely (~6 min)..."

# Fix Unicode crash: az acr build streams pnpm progress output with Unicode
# characters that crash Python's charmap codec on Windows (cp1252).
$env:PYTHONIOENCODING = "utf-8"

az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --file "$SourcePath/Dockerfile" `
    $SourcePath

if ($LASTEXITCODE -ne 0) { throw "Image build failed" }
Write-Host "Image built and pushed to $AcrName.azurecr.io/openclaw:latest" -ForegroundColor Green

Write-Host "`n=== Step 3/6: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "Token generated (save this for Control UI access):"
Write-Host "  $GatewayToken" -ForegroundColor Yellow

Write-Host "`n=== Step 4/6: Updating Container App with OpenClaw ===" -ForegroundColor Cyan

$AcrServer = "$AcrName.azurecr.io"
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
$yamlPath = [System.IO.Path]::GetTempFileName() + ".yaml"

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
        node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true &&
        node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true &&
        exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
      resources:
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: NODE_ENV
        value: production
      - name: HOME
        value: /home/node
      - name: TERM
        value: xterm-256color
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/node/.openclaw
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@

$updatedYaml | Set-Content $yamlPath -Encoding utf8

az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath

if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }

Remove-Item $yamlPath -ErrorAction SilentlyContinue

# Wait for the container to start
Write-Host "`nWaiting for container to start..."
Start-Sleep -Seconds 15

Write-Host "`n=== Step 5/6: Configuring OpenClaw (non-interactive) ===" -ForegroundColor Cyan

# Configure gateway — pass token as literal value (env var won't expand via --command)
az containerapp exec --name $AppName --resource-group $ResourceGroup `
    --command "node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token $GatewayToken --skip-channels --skip-skills --skip-daemon --skip-health"

# Set model
az containerapp exec --name $AppName --resource-group $ResourceGroup `
    --command "node openclaw.mjs models set github-copilot/claude-opus-4.6"

Write-Host "`n=== Step 6/6: Gateway configured ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                │" -ForegroundColor Yellow
Write-Host "  │  $GatewayToken  │" -ForegroundColor Yellow
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

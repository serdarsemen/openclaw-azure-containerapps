# ---------------------------------------------------------------------------
# update-openclaw.ps1 — Update the OpenClaw image without regenerating tokens or config
#
# Prerequisites: OpenClaw already deployed via deploy-openclaw.ps1
# What this does:
#   1. Pulls latest OpenClaw source (or checks out a pinned tag)
#   2. Rebuilds the container image remotely via az acr build
#   3. Updates the Container App to use the new image (creates a new revision automatically)
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
        git checkout main 2>$null
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

az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --file "$SourcePath/Dockerfile" `
    $SourcePath

if ($LASTEXITCODE -ne 0) { throw "Image build failed" }
Write-Host "Image built and pushed to $AcrName.azurecr.io/openclaw:latest" -ForegroundColor Green

# --- Step 3: Update container app (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App image ===" -ForegroundColor Cyan
az containerapp update --name $AppName --resource-group $ResourceGroup `
    --image "$AcrName.azurecr.io/openclaw:latest" `
if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }


# to avoid leaking the token in process arguments
Invoke-ContainerExec -Label "Onboard" `
    -Command "bash -c 'node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true'"
# to avoid leaking the token in process arguments
Invoke-ContainerExec -Label "Onboard" `
    -Command "bash -c 'node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true'
Invoke-ContainerExec -Label "Onboard" `
    -Command "bash -c 'node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789'"



$rev = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.latestRevisionName" -o tsv 2>$null
$img = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.template.containers[0].image" -o tsv 2>$null

# --- Post-update: Show recent container logs ---
Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Write-Host "  Current revision: $rev (image: $img)" -ForegroundColor Green
az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 60 2>$null

Write-Host "`n=== Update complete ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$GatewayToken = az containerapp secret show --name $AppName --resource-group $ResourceGroup `
    --secret-name gateway-token --query "value" -o tsv 2>$null

az containerapp revision list  --name $AppName --resource-group $ResourceGroup  -o table

Write-Host "  OpenClaw updated to: $ref image: $img" -ForegroundColor Green
Write-Host "  App restarted with new image, FQDN: $fqdn"
Write-Host ""
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded   │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Control UI: https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "Your gateway token, config, and data are unchanged." -ForegroundColor Green
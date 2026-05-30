# ---------------------------------------------------------------------------
# update-openclaw-aks.ps1 — Rebuild the OpenClaw image and roll out on AKS
#
# Mirrors update-openclaw-ACA.ps1 but targets Kubernetes. Preserves the
# existing `openclaw-secrets` Secret (gateway token), the `openclaw-state` NFS
# PVC, and the separate Ollama Deployment/PVC.
#
# Actions:
#   1. Pull/checkout OpenClaw source (source variant) or use npm tag (npm variant)
#   2. Rebuild base + tools images in the existing ACR (tagged :base-<timestamp>
#      and :latest); sweep old base tags beyond -KeepBaseImages.
#   3. Patch the openclaw Deployment to force a pull of the new :latest digest.
#   4. Optionally update the Ollama Deployment image (-OllamaImage).
#
# Prerequisites: deploy-openclaw-aks.ps1 already run against this cluster.
#
# Usage:
#   .\update-openclaw-aks.ps1                                  # source build
#   .\update-openclaw-aks.ps1 -Tag v2026.3.2                   # pinned tag
#   .\update-openclaw-aks.ps1 -Npm                             # npm variant
#   .\update-openclaw-aks.ps1 -OllamaImage ollama/ollama:0.4.0 # bump Ollama too
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $SourceResourceGroup = "rg-openclaw",
    [string] $SourceDeploymentName = "main",
    [string] $AksResourceGroup = "rg-openclaw-aks",
    [string] $AksName = "aks-openclaw",
    [string] $Namespace = "openclaw",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = "",
    [string] $OllamaImage = "",                # if set, the Ollama pod image is updated too
    [int]    $KeepBaseImages = 3,
    [int]    $RolloutTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"

function Invoke-AcrBaseImageSweep {
    param(
        [Parameter(Mandatory)][string] $Registry,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $KeepTagPrefix,
        [int] $Keep = 3
    )
    Write-Host "  Sweeping old '$KeepTagPrefix*' tags in $Registry/$Repository (keeping newest $Keep)..." -ForegroundColor Gray
    $tagsJson = az acr repository show-tags `
        --name $Registry --repository $Repository `
        --orderby time_desc --detail `
        --query "[?starts_with(name, '$KeepTagPrefix')].{name:name,created:createdTime}" `
        -o json 2>$null
    if (-not $tagsJson) { return }
    try { $tags = $tagsJson | ConvertFrom-Json } catch { return }
    if (-not $tags -or $tags.Count -le $Keep) { return }
    $toDelete = $tags | Select-Object -Skip $Keep
    foreach ($t in $toDelete) {
        Write-Host "    Deleting ${Repository}:$($t.name)" -ForegroundColor DarkGray
        az acr repository delete --name $Registry --image "${Repository}:$($t.name)" --yes 2>$null | Out-Null
    }
}

# --- Variant-specific defaults ---
if ($Npm) {
    if (-not $PSBoundParameters.ContainsKey('SourceResourceGroup'))  { $SourceResourceGroup  = "rg-openclawnpm" }
    if (-not $PSBoundParameters.ContainsKey('SourceDeploymentName')) { $SourceDeploymentName = "mainnpm" }
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $ToolsDockerfile = "images/Dockerfile.tools"
    Write-Host "`n*** Source-build variant selected ***" -ForegroundColor Magenta
}

# --- Discover ACR ---
Write-Host "`n=== Step 1/5: Discovering ACR ===" -ForegroundColor Cyan
$AcrName = az deployment group show --resource-group $SourceResourceGroup --name $SourceDeploymentName `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
if (-not $AcrName) { throw "Could not discover ACR from '$SourceDeploymentName' in '$SourceResourceGroup'" }
$AcrServer = "$AcrName.azurecr.io"
Write-Host "  ACR: $AcrServer" -ForegroundColor Green

# Ensure kubectl context is the AKS cluster
az aks get-credentials --resource-group $AksResourceGroup --name $AksName --overwrite-existing --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch AKS credentials for $AksName" }

$stamp = Get-Date -Format "yyyyMMddHHmmss"
$BaseTag = "base-$stamp"

# --- Build base image ---
Write-Host "`n=== Step 2/5: Building base image ($BaseTag) ===" -ForegroundColor Cyan
$env:PYTHONIOENCODING = "utf-8"

if ($Npm) {
    # NPM variant — inline Dockerfile
    $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-npm-build-$stamp"
    New-Item -ItemType Directory -Path $buildDir | Out-Null
    $npmTag = if ($Tag) { $Tag } else { "latest" }

    $dockerfile = @"
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash curl ca-certificates gnupg git unzip \
  chromium fonts-noto-color-emoji fonts-freefont-ttf \
  && rm -rf /var/lib/apt/lists/*
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV CHROME_BIN=/usr/bin/chromium
ENV npm_config_fund=false npm_config_audit=false
RUN npm i -g openclaw@$npmTag && npm cache clean --force
RUN groupmod -n openclaw node && usermod -l openclaw -d /home/openclaw -m -s /bin/bash node
USER openclaw
WORKDIR /home/openclaw
ENV NODE_ENV=production HOME=/home/openclaw TERM=xterm-256color
CMD ["openclaw", "gateway", "--allow-unconfigured"]
"@
    try {
        $dockerfile | Set-Content (Join-Path $buildDir "Dockerfile") -Encoding utf8
        az acr build --registry $AcrName --image "openclaw:$BaseTag" `
            --file "$buildDir/Dockerfile" $buildDir
        if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    } finally {
        Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    # Source variant — pull/checkout then export clean context
    if (-not (Test-Path $SourcePath)) {
        git clone https://github.com/openclaw/openclaw.git $SourcePath
        if ($LASTEXITCODE -ne 0) { throw "Git clone failed" }
    }
    Push-Location $SourcePath
    try {
        if ($Tag) {
            git fetch --tags; if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
            git checkout $Tag; if ($LASTEXITCODE -ne 0) { throw "git checkout '$Tag' failed" }
        } else {
            git checkout main; if ($LASTEXITCODE -ne 0) { throw "git checkout main failed" }
            git pull origin main; if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
        }
    } finally { Pop-Location }

    $ctx = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-acr-ctx-$stamp")
    $zip = "$ctx.zip"
    New-Item -ItemType Directory -Path $ctx | Out-Null
    try {
        git -C $SourcePath archive --format=zip --output $zip HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed" }
        Expand-Archive -Path $zip -DestinationPath $ctx -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        $acrDf = Join-Path $ctx "Dockerfile.acr"
        (Get-Content (Join-Path $ctx "Dockerfile") -Raw) `
            -replace '--mount=type=cache,\S+\s*', '' `
            -replace 'pnpm install --frozen-lockfile', 'PNPM_DISABLE_SELF_UPDATE_CHECK=1 pnpm install --frozen-lockfile' `
            -replace 'CI=true\s+pnpm prune --prod', 'CI=true PNPM_DISABLE_SELF_UPDATE_CHECK=1 PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
            -replace '(?m)^\s+\\\r?\n', '' |
            Set-Content $acrDf -Encoding utf8

        az acr build --registry $AcrName --image "openclaw:$BaseTag" --file $acrDf $ctx
        if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $ctx -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Tools layer → :latest ---
Write-Host "`n=== Step 3/5: Building tools layer (:latest) ===" -ForegroundColor Cyan
az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --build-arg "BASE_IMAGE=$AcrServer/openclaw:$BaseTag" `
    --file $ToolsDockerfile `
    images
if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }

# Resolve the new digest for a pin-perfect rollout
$NewDigest = az acr repository show --name $AcrName --image "openclaw:latest" `
    --query "digest" -o tsv 2>$null
if (-not $NewDigest) { throw "Could not resolve digest for $AcrServer/openclaw:latest" }
$PinnedImage = "$AcrServer/openclaw@$NewDigest"
Write-Host "  New image: $PinnedImage" -ForegroundColor Green

Invoke-AcrBaseImageSweep -Registry $AcrName -Repository "openclaw" -KeepTagPrefix "base-" -Keep $KeepBaseImages

# --- Patch OpenClaw Deployment ---
Write-Host "`n=== Step 4/5: Rolling out OpenClaw ===" -ForegroundColor Cyan
kubectl -n $Namespace get deploy/openclaw -o name | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Deployment 'openclaw' not found in namespace '$Namespace' — run deploy-openclaw-aks.ps1 first" }

kubectl -n $Namespace set image deploy/openclaw openclaw=$PinnedImage | Out-Host
if ($LASTEXITCODE -ne 0) { throw "kubectl set image failed" }

kubectl -n $Namespace rollout status deploy/openclaw --timeout=${RolloutTimeoutSeconds}s | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Warning "openclaw rollout did not complete within timeout" }

# --- Optional: update Ollama image ---
if ($OllamaImage) {
    Write-Host "`n=== Step 5/5: Updating Ollama image → $OllamaImage ===" -ForegroundColor Cyan
    kubectl -n $Namespace set image deploy/ollama ollama=$OllamaImage | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "kubectl set image (ollama) failed" }
    kubectl -n $Namespace rollout status deploy/ollama --timeout=300s | Out-Host
} else {
    Write-Host "`n=== Step 5/5: Ollama untouched (pass -OllamaImage to bump) ===" -ForegroundColor Gray
}

# --- Summary ---
$GatewayIp = kubectl -n $Namespace get svc openclaw -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
$GatewayToken = kubectl -n $Namespace get secret openclaw-secrets `
    -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' 2>$null
if ($GatewayToken) {
    $GatewayToken = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($GatewayToken))
}

Write-Host "`n=== Update complete ===" -ForegroundColor Green
Write-Host "Image:       $PinnedImage"
if ($GatewayIp) { Write-Host "OpenClaw:    http://${GatewayIp}:18789" }
if ($GatewayToken) { Write-Host "Control UI:  http://${GatewayIp}:18789/#token=$GatewayToken" }
Write-Host ""
Write-Host "Tail logs:   kubectl -n $Namespace logs -f deploy/openclaw -c openclaw"
Write-Host ""
Write-Host "=== Last step: save gateway token and URL ===" -ForegroundColor Cyan
if ($GatewayToken) {
    Write-Host ""
    $boxLabelLast  = "GATEWAY TOKEN: $GatewayToken"
    $boxBorderLast = "─" * ($boxLabelLast.Length + 2)
    Write-Host "  ┌$boxBorderLast┐" -ForegroundColor Yellow
    Write-Host "  │ $boxLabelLast │" -ForegroundColor Yellow
    Write-Host "  └$boxBorderLast┘" -ForegroundColor Yellow
    if ($GatewayIp) {
        Write-Host ""
        Write-Host "  Control UI: http://${GatewayIp}:18789/#token=$GatewayToken" -ForegroundColor White
    }
} else {
    Write-Warning "Gateway token not found in secret 'openclaw-secrets'"
}


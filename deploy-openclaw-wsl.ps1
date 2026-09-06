# ---------------------------------------------------------------------------
# deploy-openclaw-wsl.ps1 — Build and run OpenClaw as a Docker image in WSL
#
# Combines source-build and npm-install variants (controlled by -Npm switch)
# into Docker containers running locally inside WSL with Docker Engine.
#
# Without -Npm: source-build variant
#   - Builds from the OpenClaw Git repo Dockerfile
#   - Containers: OpenClaw + Redis + Ollama (optional) via docker-compose
#   - Home directory: /home/node
#
# With -Npm: npm-install variant
#   - Builds a custom Dockerfile (node:22-slim + npm i -g openclaw)
#   - Containers: OpenClaw + Redis + Ollama (optional) via docker-compose
#   - Home directory: /home/openclaw
#   - Includes Bun, Playwright/Chromium, QMD
#
# Ollama modes:
#   - Default: no Ollama sidecar (OpenClaw only + Redis)
#   - -Ollama: add Ollama sidecar container in Docker and pull models
#   - -OllamaWindows: use Ollama running natively on the Windows host (auto-detects IP)
#     * Script will attempt to auto-start Ollama on Windows
#     * Older Ollama versions are upgraded automatically before startup
#   - -OllamaWsl: use Ollama running natively in WSL (auto-detects IP)
#     * Script will attempt to auto-start Ollama in WSL
#     * Older Ollama versions are upgraded automatically before startup
#   - -OllamaHost <url>: use an external Ollama instance at a custom URL
#   - -OllamaModel <name>: pull only this model instead of the default set
#
# Note: Script auto-starts Ollama for native modes (-OllamaWindows, -OllamaWsl).
#   If auto-start fails, ensure Ollama is installed and manually start it.
#   For -OllamaWindows: Ollama must listen on 0.0.0.0 (not 127.0.0.1).
#   Set OLLAMA_HOST=0.0.0.0:11434 in Windows environment variables.
#
# Prerequisites:
#   - WSL 2 with a Linux distro installed
#   - Docker Engine running inside WSL (or Docker Desktop with WSL 2 backend)
#
# Parameters:
#   -ContainerName <name>: container/compose name (default: openclaw)
#   -SourcePath <path>:    OpenClaw source checkout (default: openclaw-repo)
#   -Tag <tag>:            npm package version only; source builds always use origin/main
#   -GatewayPort <port>:   host port for the gateway (default: 18789)
#   -BridgePort <port>:    host port for the bridge (default: 18790)
#   -DataDir <path>:       persistent data dir (default: ~/.openclaw-data in WSL)
#   -CompactState:         compact SQLite while stopped (optional maintenance)
#   -ForceRefresh:         bypass image fingerprints and refresh base/app/tools builds
#   -GroqApiKey <key>:     set GROQ_API_KEY in the OpenClaw container
#
# Usage:
#   .\deploy-openclaw-wsl.ps1                                  # source build, no Ollama
#   .\deploy-openclaw-wsl.ps1 -Npm -Tag v2026.2.15             # npm build, pinned package version
#   .\deploy-openclaw-wsl.ps1 -Npm                             # npm install
#   .\deploy-openclaw-wsl.ps1 -Ollama                          # add Ollama sidecar in Docker
#   .\deploy-openclaw-wsl.ps1 -Ollama -OllamaModel qwen2.5:7b  # sidecar + specific model
#   .\deploy-openclaw-wsl.ps1 -OllamaWindows                   # auto-start Ollama on Windows host
#   .\deploy-openclaw-wsl.ps1 -OllamaWindows -UpgradeOllama    # force reinstall/upgrade + auto-start Ollama on Windows host
#   .\deploy-openclaw-wsl.ps1 -OllamaWsl                       # auto-start Ollama in WSL
#   .\deploy-openclaw-wsl.ps1 -OllamaWsl -UpgradeOllama        # force reinstall/upgrade + auto-start Ollama in WSL
#   .\deploy-openclaw-wsl.ps1 -OllamaHost http://host.docker.internal:11434  # external Ollama
#   .\deploy-openclaw-wsl.ps1 -Npm -Ollama -LanAccess          # all features: npm + sidecar + LAN access
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [switch] $RebuildTools,
    [switch] $ForceRefresh,
    [switch] $CompactState,
    [switch] $Ollama,
    [switch] $OllamaWindows,
    [switch] $OllamaWsl,
    [switch] $UpgradeOllama,
    [string] $ContainerName = "openclaw",
    [string] $SourcePath    = "openclaw-repo",
    [string] $Tag           = "",
    [int]    $GatewayPort   = 18789,
    [int]    $BridgePort    = 18790,
    [string] $DataDir       = "",
    [string] $OllamaHost    = "",
    [string] $OllamaModel   = "",
    [string] $GroqApiKey    = "",
    [string] $GatewayToken  = "",
    [switch] $LanAccess
)

$ErrorActionPreference = "Stop"

# Validate Ollama mode — only one allowed at a time
$ollamaModeCount = @($Ollama, $OllamaWindows, $OllamaWsl, [bool]$OllamaHost).Where({ $_ }).Count
if ($ollamaModeCount -gt 1) {
    throw "Only one Ollama mode allowed at a time: -Ollama (Docker sidecar), -OllamaWindows, -OllamaWsl, or -OllamaHost <url>"
}

# Load shared WSL helpers (Invoke-Wsl, Invoke-WslRetry, Invoke-WslData, Test-WslDocker,
# Start-WslDocker, Repair-WslDns, New/Expand-WslTransferArchive,
# Get-LatestOllamaVersion, Start-OllamaWindows, Start-OllamaWsl,
# Resolve-OllamaHost, New-OpenClawComposeYaml).
. "$PSScriptRoot/wsl-helpers.ps1"
. "$PSScriptRoot/wsl-deploy-helpers.ps1"
. "$PSScriptRoot/source-helpers.ps1"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

# Check WSL is available
wsl --status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "WSL is not available. Install WSL 2: wsl --install"
}
Write-Host "  WSL: OK" -ForegroundColor Green

# Check Docker inside WSL — auto-start if not running
if (-not (Test-WslDocker)) {
    if (-not (Start-WslDocker)) {
        $wslUser = (wsl whoami 2>$null).Trim()
        throw @"
Docker is not running inside WSL and could not be auto-started.
Fix: run this once in WSL to enable passwordless Docker start:
  wsl bash -c "echo '$wslUser ALL=(ALL) NOPASSWD: /usr/sbin/service docker *' | sudo tee /etc/sudoers.d/docker-service"
Or start Docker manually before running this script:
  wsl sudo service docker start
"@
    }
    Write-Host "  Docker (WSL): started" -ForegroundColor Green
} else {
    Write-Host "  Docker (WSL): OK" -ForegroundColor Green
}

# Check DNS resolution inside WSL — WSL2's NAT DNS forwarder is notoriously flaky
Write-Host "  Checking DNS resolution..." -ForegroundColor Gray
$null = Repair-WslDns

# ---------------------------------------------------------------------------
# Resolve native/external Ollama usage to a concrete URL, or emit a skip note
# when Ollama is not in use for this deployment.
# ---------------------------------------------------------------------------
$resolved = Resolve-OllamaHost -OllamaWindows:$OllamaWindows -OllamaWsl:$OllamaWsl -OllamaHost $OllamaHost -UpgradeOllama:$UpgradeOllama
$OllamaHost = $resolved.OllamaHost

# ---------------------------------------------------------------------------
# Set variant-specific defaults
# ---------------------------------------------------------------------------
if ($Npm) {
    $HomeDir         = "/home/openclaw"
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    $ImageName       = "openclaw-npm"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $HomeDir         = "/home/node"
    $ToolsDockerfile = "images/Dockerfile.tools"
    $ImageName       = "openclaw-source"
    Write-Host "`n*** Source-build variant selected ***" -ForegroundColor Magenta
}

# Data directory — persists config, workspace, and SQLite across restarts.
# Default to WSL home (ext4) to avoid DrvFS permission issues (0777 on /mnt/c mounts).
if (-not $DataDir) {
    # Use single-quoted string so PowerShell doesn't expand $HOME; bash resolves it at runtime.
    $WslDataDir = (wsl -- bash -c 'echo "$HOME/.openclaw-data"').Trim()
    Invoke-Wsl "mkdir -p '$WslDataDir'"
    $DataDir = (wsl -- bash -c "wslpath -w '$WslDataDir'").Trim()
    Write-Host "  Using default WSL data directory: $WslDataDir" -ForegroundColor Gray
} else {
    $DataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DataDir)
    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir | Out-Null
        Write-Host "  Created data directory: $DataDir" -ForegroundColor Gray
    }
    $WslDataDir = (Invoke-WslData "wslpath -u '$($DataDir -replace '\\','/')'").Trim()
}
Write-Host "  Data dir (WSL): $WslDataDir" -ForegroundColor Green

# Convert script root and source path to WSL paths
$WslScriptRoot = (Invoke-WslData "wslpath -u '$($PSScriptRoot -replace '\\','/')'")
$WslScriptRoot = $WslScriptRoot.Trim()
$WslMaintenanceScript = "$WslScriptRoot/scripts/openclaw-state-maintenance.py"
$WslMonitorScript = "$WslScriptRoot/scripts/openclaw-restart-monitor.sh"
$WslOverlayDockerfile = "$WslScriptRoot/images/Dockerfile.app-overlay"
$CandidateImage = "${ImageName}:candidate"
$null = Save-OpenClawKnownGoodImage -ContainerName $ContainerName -ImageName $ImageName

# ---------------------------------------------------------------------------
# Step 1: Build image
# ---------------------------------------------------------------------------
$buildPlatform = ((Invoke-WslData "docker version --format '{{.Server.Os}}/{{.Server.Arch}}'") -join '').Trim()
$toolsInputs = @($ToolsDockerfile, $buildPlatform, (Get-FileHash (Join-Path $PSScriptRoot 'wsl-helpers.ps1') -Algorithm SHA256).Hash)
$imagesPath = Join-Path $PSScriptRoot 'images'
$toolsInputs += @(Get-ChildItem -LiteralPath $imagesPath -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    $_.FullName.Substring($imagesPath.Length).Replace('\', '/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
})
$buildInputs = @((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash) + $toolsInputs
$totalSteps = if ($Ollama -and (-not $OllamaHost)) { 6 } else { 5 }
if ($Npm) {
    # ===== NPM variant: create inline Dockerfile and build locally =====
    Write-Host "`n=== Step 1/${totalSteps}: Creating Dockerfile (Debian Slim + npm) ===" -ForegroundColor Cyan

    $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-wsl-npm-build"
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Path $buildDir | Out-Null

    $npmTag = if ($Tag) { $Tag.TrimStart('v') } else { "2026.6.8" }

    $dockerfile = @"
FROM node:22-slim

# Install system dependencies, git, and system Chromium in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash curl ca-certificates gnupg \
  git unzip \
  chromium fonts-noto-color-emoji fonts-freefont-ttf \
  && rm -rf /var/lib/apt/lists/*

# Use system Chromium instead of Playwright-bundled binary
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV CHROME_BIN=/usr/bin/chromium

# Make npm installs slightly quieter & consistent
ENV npm_config_fund=false npm_config_audit=false

# Install OpenClaw globally via npm and clean cache
RUN npm i -g openclaw@$npmTag && npm cache clean --force

RUN node -v && npm -v

# Rename existing node user/group (UID/GID 1000) to openclaw
RUN groupmod -n openclaw node \
 && usermod -l openclaw -d /home/openclaw -m -s /bin/bash node

# Switch to non-root user
USER openclaw
WORKDIR /home/openclaw

ENV NODE_ENV=production
ENV HOME=/home/openclaw
ENV TERM=xterm-256color

CMD ["openclaw", "gateway", "--allow-unconfigured"]
"@

    $dockerfile | Set-Content (Join-Path $buildDir "Dockerfile") -Encoding utf8
    Write-Host "  Dockerfile created at $buildDir" -ForegroundColor Green

    $WslBuildDir = (Invoke-WslData "wslpath -u '$($buildDir -replace '\\','/')'")
    $WslBuildDir = $WslBuildDir.Trim()

    Write-Host "`n=== Step 2/${totalSteps}: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    try {
        $buildFingerprint = Get-OpenClawBuildFingerprint -Inputs (@('npm', $npmTag, $dockerfile) + $buildInputs)
        $refreshNpm = $ForceRefresh -or $npmTag -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$'
        $imageFresh = Test-OpenClawImageFresh -ImageName $ImageName -Fingerprint $buildFingerprint -ForceRefresh:($refreshNpm -or $RebuildTools)
        if ($imageFresh) {
            $CandidateImage = "${ImageName}:latest"
            Write-Host "  Build inputs unchanged; reusing $CandidateImage" -ForegroundColor Green
        } else {
            Write-Host "  Step 2a: Building candidate image..." -ForegroundColor Gray
            $CandidateImage = Build-OpenClawNpmCandidate -WslBuildContext $WslBuildDir -ImageName $ImageName -WslToolsDockerfile "$WslScriptRoot/$ToolsDockerfile" -WslToolsContext "$WslScriptRoot/images" -RebuildTools:$RebuildTools -Fingerprint $buildFingerprint -ForceRefresh:$refreshNpm
            Write-Host "  Candidate image built: $CandidateImage" -ForegroundColor Green
        }
    } finally {
        Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    }

} else {
    # ===== Source-build variant: pull/checkout source and build locally =====
    Write-Host "`n=== Step 1/${totalSteps}: Updating OpenClaw source from origin/main ===" -ForegroundColor Cyan

    $ResolvedSourcePath = if ([System.IO.Path]::IsPathRooted($SourcePath)) { $SourcePath } else { Join-Path $PSScriptRoot $SourcePath }
    if ($Tag) { Write-Warning '-Tag applies only to -Npm; source builds always use the latest origin/main.' }
    $sourceSync = Sync-OpenClawSource -SourcePath $ResolvedSourcePath
    $ResolvedSourcePath = $sourceSync.SourcePath
    $sourceCommit = $sourceSync.Commit

    $ref = "latest (origin/main @ $sourceCommit)"
    Write-Host "  Build source and VS Code checkout: $ref" -ForegroundColor Green

    Write-Host "`n=== Step 2/${totalSteps}: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    $buildFingerprint = Get-OpenClawBuildFingerprint -Inputs (@('source', $sourceCommit) + $buildInputs)
    $sourceDockerfileHash = (Get-FileHash (Join-Path $ResolvedSourcePath 'Dockerfile') -Algorithm SHA256).Hash
    $toolsFingerprint = Get-OpenClawBuildFingerprint -Inputs (@('source-tools', $sourceDockerfileHash) + $toolsInputs)
    $imageFresh = Test-OpenClawImageFresh -ImageName $ImageName -Fingerprint $buildFingerprint -ForceRefresh:($ForceRefresh -or $RebuildTools)
    if ($imageFresh) {
        $CandidateImage = "${ImageName}:latest"
        Write-Host "  Build inputs unchanged; reusing $CandidateImage" -ForegroundColor Green
    } else {
    $WslSourcePath = (Invoke-WslData "wslpath -u '$($ResolvedSourcePath -replace '\\','/')'")
    # Handle relative paths — prepend script root if not already absolute
    if ($WslSourcePath -notmatch '^/') {
        $WslSourcePath = "$WslScriptRoot/$SourcePath"
    }
    $WslSourcePath = $WslSourcePath.Trim()

    Write-Host "  Step 2a: Packaging source as WSL transfer archive..." -ForegroundColor Gray
    $SourceArchive = New-WslTransferArchive -SourcePath $WslSourcePath -ArchiveName "$ImageName-source" -Revision $sourceCommit
    Write-Host "  Source archive (WSL): $($SourceArchive.WslArchivePath)" -ForegroundColor Green

    Write-Host "  Step 2b: Expanding source archive in WSL..." -ForegroundColor Gray
    $WslBuildContext = Expand-WslTransferArchive -ArchivePath $SourceArchive.WslArchivePath -ContextName "$ImageName-source"
    Write-Host "  Build context (WSL): $($WslBuildContext.WslContextPath)" -ForegroundColor Green

    Write-Host "  Applying cron concurrency limit (2)..." -ForegroundColor Gray
    Set-OpenClawCronConcurrencyLimit -WslSourceRoot $WslBuildContext.WslContextPath -MaxConcurrent 2
    Write-Host "  Applying restart drain timeout (60 seconds)..." -ForegroundColor Gray
    Set-OpenClawRestartDrainTimeout -WslSourceRoot $WslBuildContext.WslContextPath -DrainTimeoutMs 60000

    # Patch Dockerfile for local Docker compatibility:
    # - Strip '# syntax=docker/dockerfile:...' (avoids pulling BuildKit frontend image — fails when WSL DNS is flaky)
    # - Keep --mount=type=cache directives — BuildKit is the default builder in Docker 23.0+ (WSL)
    #   and cache mounts dramatically speed up rebuilds (pnpm store, apt cache).
    Write-Host "  Step 2c: Patching Dockerfile for local Docker compatibility..." -ForegroundColor Gray
    Update-LocalBuildDockerfile -WslDockerfilePath "$($WslBuildContext.WslContextPath)/Dockerfile"
    Write-Host "  Stripped syntax directive (keeping BuildKit cache mounts for faster rebuilds)" -ForegroundColor Green

    try {
        $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
        $WslToolsContext    = "$WslScriptRoot/images"

        Write-Host "  Step 2d: Building candidate app and reusable tools overlay..." -ForegroundColor Gray
        $CandidateImage = Build-OpenClawSourceCandidate `
            -WslBuildContext $WslBuildContext.WslContextPath `
            -ImageName $ImageName `
            -WslToolsDockerfile $WslToolsDockerfile `
            -WslToolsContext $WslToolsContext `
            -WslOverlayDockerfile $WslOverlayDockerfile `
            -RebuildTools:$RebuildTools `
            -Fingerprint $buildFingerprint `
            -ToolsFingerprint $toolsFingerprint `
            -ForceRefresh:$ForceRefresh
        Write-Host "  Candidate image built: $CandidateImage" -ForegroundColor Green
    } finally {
        try { Invoke-Wsl "rm -rf '$($SourceArchive.WslArchivePath)' '$($WslBuildContext.WslContextPath)'" } catch {}
    }
    }
}

# ---------------------------------------------------------------------------
# Step 3: Resolve gateway token (reuse existing or generate new)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/${totalSteps}: Resolving gateway token ===" -ForegroundColor Cyan
$existingConfigPath = Join-Path $DataDir "openclaw.json"
if (-not $GatewayToken) {
    # No token passed via -GatewayToken; try to reuse the one in openclaw.json
    if (Test-Path $existingConfigPath) {
        try {
            $existingConfig = Get-Content $existingConfigPath -Raw | ConvertFrom-Json
            if ($existingConfig.gateway.auth.token) {
                $GatewayToken = $existingConfig.gateway.auth.token
                Write-Host "  Reusing existing gateway token from openclaw.json" -ForegroundColor Green
            }
        } catch {
            Write-Host "  Could not read existing token, generating new one" -ForegroundColor Gray
        }
    }
}
if (-not $GatewayToken) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
    Write-Host "  New token generated (save this for Control UI access):" -ForegroundColor Gray
} else {
    Write-Host "  Using token:" -ForegroundColor Gray
}
Write-Host "  $GatewayToken" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Step 4/5: Create docker-compose and start containers
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4/${totalSteps}: Starting containers via docker-compose ===" -ForegroundColor Cyan

$ollamaEnabled = $Ollama -and (-not $OllamaHost)
$firecrawlHttpEnabled = ((Invoke-WslData "test -f '$WslDataDir/firecrawl-mcp.env' && echo true || echo false") -join "").Trim() -eq "true"
if ($ollamaEnabled) {
    Write-Host "  Ollama sidecar: enabled" -ForegroundColor Green
} else {
    Write-Host "  Ollama: $(if ($OllamaHost) { $OllamaHost } else { 'not enabled (use -Ollama to add sidecar)' })" -ForegroundColor Gray
}

$composeYaml = New-OpenClawComposeYaml `
    -ContainerName $ContainerName `
    -ImageName $ImageName `
    -HomeDir $HomeDir `
    -WslDataDir $WslDataDir `
    -GatewayPort $GatewayPort `
    -BridgePort $BridgePort `
    -GatewayToken $GatewayToken `
    -OllamaHost $OllamaHost `
    -OllamaSidecar:$ollamaEnabled `
    -GroqApiKey $GroqApiKey `
    -FirecrawlHttp:$firecrawlHttpEnabled `
    -Npm:$Npm `
    -LanAccess:$LanAccess

$composePath = Join-Path $PSScriptRoot "docker-compose-wsl.yaml"
$WslComposePath = "$WslScriptRoot/docker-compose-wsl.yaml"
$configPath = Join-Path $DataDir "openclaw.json"
$expectedConfigHash = if (Test-Path $configPath) { (Get-FileHash $configPath).Hash } else { '' }
$deploymentId = [guid]::NewGuid().ToString('N')
$stagePath = Join-Path $DataDir ".deploy-$deploymentId"
$WslStagePath = "$WslDataDir/.deploy-$deploymentId"
$candidateConfigPath = Join-Path $stagePath 'openclaw.json'
$candidateComposePath = Join-Path $stagePath 'compose.yaml'
$previousImage = ((Invoke-WslData "docker inspect -f '{{.Image}}' '$ContainerName' 2>/dev/null || true") -join '').Trim()
$previousRunning = ((Invoke-WslData "docker inspect -f '{{.State.Running}}' '$ContainerName' 2>/dev/null || true") -join '').Trim() -eq 'true'
$previousLatestImage = ((Invoke-WslData "docker image inspect '${ImageName}:latest' -f '{{.Id}}' 2>/dev/null || true") -join '').Trim()
if ($previousImage -and -not (Test-Path $composePath)) {
    throw 'An existing container has no saved Compose file. Restore its Compose file before redeploying so rollback is possible.'
}
Invoke-Wsl "mkdir -p '$WslStagePath/state' '$WslStagePath/logs'; chmod 700 '$WslStagePath'"
$deploymentSucceeded = $false
try {
$composeYaml | Set-Content $candidateComposePath -Encoding utf8

if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
} else {
    $config = [pscustomobject]@{}
}

# Ensure nested structure exists
if (-not $config.gateway) { $config | Add-Member -NotePropertyName gateway -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.gateway.auth) { $config.gateway | Add-Member -NotePropertyName auth -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.gateway.controlUi) { $config.gateway | Add-Member -NotePropertyName controlUi -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.gateway.auth.rateLimit) { $config.gateway.auth | Add-Member -NotePropertyName rateLimit -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.agents) { $config | Add-Member -NotePropertyName agents -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.agents.defaults) { $config.agents | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) }
if (-not $config.agents.defaults.model) {
    $config.agents.defaults | Add-Member -NotePropertyName model -NotePropertyValue ([pscustomobject]@{ primary = 'github-copilot/claude-opus-4.6' }) -Force
}

# Gateway settings — use Add-Member -Force so properties are created or updated
# regardless of whether they pre-exist on the deserialized PSCustomObject
$config.gateway.auth | Add-Member -NotePropertyName mode          -NotePropertyValue "token"        -Force
$config.gateway.auth | Add-Member -NotePropertyName token         -NotePropertyValue $GatewayToken  -Force
$config.gateway.auth.rateLimit | Add-Member -NotePropertyName maxAttempts -NotePropertyValue 10     -Force
$config.gateway.auth.rateLimit | Add-Member -NotePropertyName windowMs    -NotePropertyValue 60000  -Force
$config.gateway.auth.rateLimit | Add-Member -NotePropertyName lockoutMs   -NotePropertyValue 300000 -Force
$config.gateway | Add-Member -NotePropertyName port -NotePropertyValue 18789  -Force
$config.gateway | Add-Member -NotePropertyName bind -NotePropertyValue "lan"  -Force
$config.gateway | Add-Member -NotePropertyName mode -NotePropertyValue "local" -Force
$config.gateway.controlUi | Add-Member -NotePropertyName allowInsecureAuth                           -NotePropertyValue $true -Force
$config.gateway.controlUi | Add-Member -NotePropertyName dangerouslyAllowHostHeaderOriginFallback    -NotePropertyValue $true -Force

# Model
if ($null -eq $config.agents.defaults.maxConcurrent) {
    $config.agents.defaults | Add-Member -NotePropertyName maxConcurrent -NotePropertyValue 2 -Force
}

# Write back
$config | ConvertTo-Json -Depth 100 | Set-Content $candidateConfigPath -Encoding utf8
Invoke-Wsl "chmod 600 '$WslStagePath/openclaw.json' '$WslStagePath/compose.yaml'"
Write-Host "  Candidate configuration staged; live configuration is unchanged" -ForegroundColor Green

# Always refresh auxiliary service images to their latest tags before startup.
Write-Host "  Pulling latest redis, searxng, and crw images..." -ForegroundColor Gray
Invoke-WslImageRefresh -Images @('redis:7-alpine', 'searxng/searxng:latest', 'ghcr.io/us/crw:latest')

# Fetch latest Ollama version if native Ollama mode is selected
if ($OllamaWindows -or $OllamaWsl) {
    Write-Host "  Fetching latest Ollama version..." -ForegroundColor Gray
    try {
        $latestOllamaVersion = Get-LatestOllamaVersion
        if ($latestOllamaVersion) {
            Write-Host "  Latest Ollama version available: $latestOllamaVersion" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Could not fetch latest Ollama version (network issue)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Step 5/5: Configure OpenClaw (non-interactive)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 5/${totalSteps}: Configuring OpenClaw ===" -ForegroundColor Cyan

function Test-IgnorableUpdateNoiseLine {
    param([string] $Line)
    if (-not $Line) { return $false }
    return ($Line -match 'Failed to update:\s*github/awesome-copilot')
}

function Wait-ContainerRunning {
    param([int] $TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $state = (Invoke-WslData "docker inspect -f '{{.State.Status}}' $ContainerName 2>/dev/null").Trim()
        if ($state -eq 'running') { return $true }
        Write-Host "  Container state: $state — waiting..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
    return $false
}

function Wait-OpenClawReady {
    # Wait until the OpenClaw gateway port (18789) is open inside the container.
    # On first run, the container installs bundled runtime deps before serving,
    # which can take several minutes. Any docker exec before this completes will
    # fail with a runtime-deps lock timeout.
    param([int] $TimeoutSec = 600)
    Write-Host "  Waiting for OpenClaw gateway to become ready (first-run deps may take a few minutes)..." -ForegroundColor Gray
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastMsg   = ""
    $noiseNoticePrinted = $false
    while ((Get-Date) -lt $deadline) {
        $check = wsl bash -c "timeout -k 1 5 docker exec $ContainerName bash -c 'timeout 3 bash -c ""</dev/tcp/localhost/18789"" 2>/dev/null && echo READY || echo NOT_READY'" 2>$null
        if ($LASTEXITCODE -eq 0 -and (($check -join "").Trim() -eq "READY")) {
            Write-Host "  OpenClaw gateway: ready" -ForegroundColor Green
            return $true
        }
        # Surface latest log line so user can see progress
        $logLine = (wsl bash -c "timeout -k 1 5 docker logs --tail 1 $ContainerName 2>&1") -join ""
        if ($logLine -and $logLine -ne $lastMsg) {
            if (Test-IgnorableUpdateNoiseLine -Line $logLine) {
                if (-not $noiseNoticePrinted) {
                    Write-Host "  [container] Ignoring known non-fatal update warning for github/awesome-copilot" -ForegroundColor Yellow
                    $noiseNoticePrinted = $true
                }
            } else {
                Write-Host "  [container] $logLine" -ForegroundColor DarkGray
            }
            $lastMsg = $logLine
        }
        Start-Sleep -Seconds 5
    }
    Write-Warning "OpenClaw gateway did not become ready within ${TimeoutSec}s — check logs: wsl docker logs $ContainerName"
    return $false
}

function Invoke-DockerExec {
    param(
        [string] $Label,
        [string] $Command,
        [int]    $MaxRetries = 5,
        [int]    $DelaySec   = 10,
        [int]    $ExecTimeoutSec = 120,
        [switch] $ContinueOnFailure
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        if (-not (Wait-ContainerRunning -TimeoutSec 60)) {
            Write-Warning "[$Label] container did not reach running state — check logs with: wsl docker logs $ContainerName"
            if ($ContinueOnFailure) { return $false }
            throw "[$Label] container not running"
        }
        Write-Host "  [$Label] attempt $i/$MaxRetries" -ForegroundColor Gray
        $output = wsl bash -c "docker exec $ContainerName bash -c 'timeout $ExecTimeoutSec $Command </dev/null'" 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($output) { Write-Host "    $output" -ForegroundColor DarkGray }
            return $true
        }
        if ($LASTEXITCODE -eq 124) {
            Write-Warning "[$Label] timed out after ${ExecTimeoutSec}s"
        }
        if ($output) { Write-Host "    $output" -ForegroundColor DarkGray }
        if ($i -lt $MaxRetries) {
            Write-Host "  [$Label] exec failed — retrying in ${DelaySec}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySec
        }
    }
    Write-Warning "[$Label] failed after $MaxRetries attempts"
    if ($ContinueOnFailure) { return $false }
    throw "[$Label] failed after $MaxRetries attempts"
}

Invoke-OpenClawDeploymentTransaction `
    -ConfigPath $configPath -ComposePath $composePath `
    -CandidateConfigPath $candidateConfigPath -CandidateComposePath $candidateComposePath `
    -ExpectedConfigHash $expectedConfigHash `
    -Validate {
        $validationSnapshot = (Invoke-OpenClawStateBackup -WslDataDir $WslDataDir -WslMaintenanceScript $WslMaintenanceScript -KeepBackups 5 | Out-String | ConvertFrom-Json).backup
        if (-not $validationSnapshot) { throw 'Could not resolve validation snapshot' }
        Invoke-Wsl "if [ -f '$validationSnapshot/openclaw.sqlite' ]; then cp '$validationSnapshot/openclaw.sqlite' '$WslStagePath/state/openclaw.sqlite'; fi"
        Test-OpenClawCandidateConfig -CandidateImage $CandidateImage -WslDataDir $WslStagePath -HomeDir $HomeDir -MatchHostUser
        Invoke-Wsl "OPENCLAW_DATA_DIR='$WslDataDir' docker compose --project-directory '$WslScriptRoot' -f '$WslStagePath/compose.yaml' config --quiet"
    } `
    -Stop {
        $containerExists = ((Invoke-WslData "docker ps -a --filter 'name=^${ContainerName}$' --format '{{.Names}}'") -join '').Trim()
        if ($containerExists) { $null = Invoke-Wsl "docker stop -t 90 '$ContainerName'" -ServiceRetries 1 }
    } `
    -BackupState {
        $snapshot = (Invoke-OpenClawStateBackup -WslDataDir $WslDataDir -WslMaintenanceScript $WslMaintenanceScript -KeepBackups 5 | Out-String | ConvertFrom-Json).backup
        if (-not $snapshot) { throw 'Could not resolve rollback snapshot' }
        return $snapshot
    } `
    -RestoreState {
        param($snapshot)
        Invoke-Wsl "set -e; test -f '$snapshot/manifest.json'; if [ -f '$snapshot/openclaw.sqlite' ]; then mkdir -p '$WslDataDir/state'; cp -p '$snapshot/openclaw.sqlite' '$WslDataDir/state/openclaw.sqlite.restore'; cmp '$snapshot/openclaw.sqlite' '$WslDataDir/state/openclaw.sqlite.restore'; mv -f '$WslDataDir/state/openclaw.sqlite.restore' '$WslDataDir/state/openclaw.sqlite'; else rm -f '$WslDataDir/state/openclaw.sqlite'; fi; rm -f '$WslDataDir/state/openclaw.sqlite-wal' '$WslDataDir/state/openclaw.sqlite-shm'"
    } `
    -Start {
        Invoke-Wsl "docker tag '$CandidateImage' '${ImageName}:latest'"
        Remove-UnmanagedDockerContainer -ContainerName 'searxng'
        Invoke-Wsl "find '$WslDataDir/plugin-runtime-deps' -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true"
        Invoke-OpenClawStateMaintenance -WslDataDir $WslDataDir -WslMaintenanceScript $WslMaintenanceScript -RetentionDays 30 -Compact:$CompactState
        Invoke-WslWithNetworkPoolRecovery -Context 'docker compose up' -Command "OPENCLAW_DATA_DIR='$WslDataDir' docker compose -f '$WslComposePath' up -d --remove-orphans"
        if (-not (Wait-OpenClawReady -TimeoutSec 600)) { throw 'Candidate failed readiness checks' }
        if (-not (Wait-OpenClawContainerHealthy -ContainerName $ContainerName -MaxAttempts 30 -DelaySeconds 5)) { throw 'Candidate failed state-backed health checks' }
    } `
    -Rollback {
        if ($previousImage) {
            Invoke-Wsl "docker tag '$previousImage' '${ImageName}:latest'"
            if (Test-Path $composePath) {
                Invoke-WslWithNetworkPoolRecovery -Context 'deployment rollback' -Command "OPENCLAW_DATA_DIR='$WslDataDir' docker compose -f '$WslComposePath' up -d --remove-orphans"
                if (-not $previousRunning) { $null = Invoke-Wsl "docker stop -t 90 '$ContainerName'" }
            } elseif ($previousRunning) {
                $null = Invoke-Wsl "docker start '$ContainerName'"
            }
            if ($previousRunning -and -not (Wait-OpenClawContainerHealthy -ContainerName $ContainerName)) { throw 'Previous deployment did not recover' }
        } else {
            Invoke-Wsl "OPENCLAW_DATA_DIR='$WslDataDir' docker compose --project-directory '$WslScriptRoot' -f '$WslStagePath/compose.yaml' down"
            if ($previousLatestImage) { Invoke-Wsl "docker tag '$previousLatestImage' '${ImageName}:latest'" }
        }
    }
$deploymentSucceeded = $true
} finally {
    if ($deploymentSucceeded -or -not (Test-Path (Join-Path $stagePath 'recovery'))) {
        if (Test-Path $stagePath) { Remove-Item -LiteralPath $stagePath -Recurse -Force }
    } else {
        Write-Warning "Deployment recovery files retained at $stagePath"
    }
}

Invoke-Wsl "docker tag '${ImageName}:latest' '${ImageName}:known-good'"
Start-OpenClawRestartMonitor -ContainerName $ContainerName -WslDataDir $WslDataDir -WslMonitorScript $WslMonitorScript
Install-OpenClawStateMaintenanceSchedule -WslDataDir $WslDataDir -WslMaintenanceScript $WslMaintenanceScript
Write-Host "  Configuration: applied from openclaw.json (written before container start)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 6/6: Pull Ollama models (if Ollama sidecar is running)
# ---------------------------------------------------------------------------
if ($ollamaEnabled) {
    Write-Host "`n=== Step 6/${totalSteps}: Pulling Ollama models ===" -ForegroundColor Cyan

    # Wait for Ollama to become ready
    Write-Host "  Waiting for Ollama to become ready..."
    $ollamaReady = $false
    for ($i = 1; $i -le 20; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:11434/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200) {
                Write-Host "  Ollama is ready" -ForegroundColor Green
                $ollamaReady = $true
                break
            }
        } catch {}
        if ($i -lt 20) {
            Write-Host "  Not ready yet — retrying ($i/20)..." -ForegroundColor Gray
            Start-Sleep -Seconds 3
        }
    }

    if ($ollamaReady) {
        # Default models to pull — same set as the ACA deploy-ollama.ps1
        $models = @(
            @{ name = "qwen2.5-coder:7b"; desc = "Best coding model at 7B — code generation, completion, refactoring" },
            @{ name = "deepseek-r1:8b";   desc = "Strong chain-of-thought reasoning" },
            @{ name = "qwen2.5:7b";       desc = "General-purpose — writing, analysis, summarisation" }
        )

        # If user specified a specific model, pull only that
        if ($OllamaModel) {
            $models = @( @{ name = $OllamaModel; desc = "User-specified model" } )
        }

        foreach ($model in $models) {
            Write-Host "  Pulling $($model.name) ($($model.desc))..." -ForegroundColor Gray
            try {
                Invoke-Wsl "docker exec ${ContainerName}-ollama ollama pull $($model.name)"
                Write-Host "  $($model.name) ready" -ForegroundColor Green
            } catch {
                Write-Warning "  Failed to pull $($model.name) — pull later: wsl docker exec ${ContainerName}-ollama ollama pull $($model.name)"
            }
        }

        # Pre-load default model
        $defaultModel = if ($OllamaModel) { $OllamaModel } else { "deepseek-r1:8b" }
        Write-Host "  Loading $defaultModel as default model (keepalive 1h)..." -ForegroundColor Gray
        try {
            Invoke-Wsl "docker exec ${ContainerName}-ollama ollama run $defaultModel --keepalive 1h ''"
            Write-Host "  $defaultModel loaded and kept alive" -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to pre-load $defaultModel — load manually: wsl docker exec ${ContainerName}-ollama ollama run $defaultModel"
        }
    } else {
        Write-Warning "Ollama did not become ready — pull models manually after it starts"
        Write-Host "  wsl docker exec ${ContainerName}-ollama ollama pull deepseek-r1:8b" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Done — print summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Deployment complete ===" -ForegroundColor Green

$variantLabel = if ($Npm) { "npm" } else { "source" }
Write-Host "  OpenClaw ($variantLabel) running in Docker via WSL" -ForegroundColor Green
Write-Host "  Gateway:    http://localhost:${GatewayPort}" -ForegroundColor White
Write-Host "  Control UI: http://localhost:${GatewayPort}/#token=$GatewayToken" -ForegroundColor White
Write-Host "  Data dir:   $DataDir" -ForegroundColor White
Write-Host ""
Get-OllamaSummaryLines `
    -OllamaSidecar:$ollamaEnabled `
    -OllamaWindows:$OllamaWindows `
    -OllamaWsl:$OllamaWsl `
    -OllamaHost $OllamaHost | ForEach-Object {
    Write-Host $_ -ForegroundColor White
}
if ($ollamaEnabled) {
    Write-Host "  Models:     $(if ($OllamaModel) { $OllamaModel } else { 'qwen2.5-coder:7b, deepseek-r1:8b, qwen2.5:7b' })" -ForegroundColor White
}
Write-Host ""
Write-Host "=== Useful commands ===" -ForegroundColor Cyan
Write-Host "  View logs:       wsl docker logs -f $ContainerName" -ForegroundColor Gray
Write-Host "  Shell into:      wsl docker exec -it $ContainerName bash" -ForegroundColor Gray
Write-Host "  Stop:            wsl docker compose -f docker-compose-wsl.yaml down" -ForegroundColor Gray
Write-Host "  Restart:         wsl docker compose -f docker-compose-wsl.yaml restart" -ForegroundColor Gray
if ($ollamaEnabled) {
    Write-Host "" -ForegroundColor Gray
    Write-Host "=== Ollama commands ===" -ForegroundColor Cyan
    Write-Host "  Pull model:      wsl docker exec ${ContainerName}-ollama ollama pull <model>" -ForegroundColor Gray
    Write-Host "  List models:     wsl docker exec ${ContainerName}-ollama ollama list" -ForegroundColor Gray
    Write-Host "  Run model:       wsl docker exec -it ${ContainerName}-ollama ollama run <model>" -ForegroundColor Gray
    Write-Host "  Ollama logs:     wsl docker logs -f ${ContainerName}-ollama" -ForegroundColor Gray
}
Write-Host ""
Write-Host "=== Working with books (book-to-skill) ===" -ForegroundColor Cyan
Write-Host "  Copy PDF or EPUB files to OpenClaw for processing into skills:" -ForegroundColor Gray
Write-Host "  wsl docker cp `"C:\Users\YourUsername\Downloads\BookTitle.pdf`" `"$ContainerName`:/home/node/.openclaw/book-to-skill/books/`"" -ForegroundColor White
Write-Host ""
Write-Host "  Or for EPUB files with spaces in the name:" -ForegroundColor Gray
Write-Host "  wsl docker cp `"C:\Users\YourUsername\Downloads\Book Title With Spaces.epub`" `"$ContainerName`:/home/node/.openclaw/book-to-skill/books/`"" -ForegroundColor White
Write-Host ""
Write-Host "  Files persist at: /home/node/.openclaw/book-to-skill/books/" -ForegroundColor Gray
Write-Host ""
Write-Host "=== One manual step remaining: GitHub Copilot auth ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Connect to container:" -ForegroundColor Yellow
Write-Host "   wsl docker exec -it $ContainerName bash" -ForegroundColor White
Write-Host ""
Write-Host "2. Inside the container:" -ForegroundColor Yellow
$authCmd = if ($Npm) { "openclaw models auth login-github-copilot" } else { "node openclaw.mjs models auth login-github-copilot" }
Write-Host "   $authCmd" -ForegroundColor White
Write-Host "   (open browser, enter code, authorize, then type: exit)"
Write-Host ""
Write-Host "3. Open Control UI:" -ForegroundColor Yellow
Write-Host "   http://localhost:${GatewayPort}/#token=$GatewayToken" -ForegroundColor White
Write-Host ""
Write-Host "=== Last step: save gateway token ===" -ForegroundColor Cyan
Write-Host ""
$boxLabel  = "GATEWAY TOKEN: $GatewayToken"
$boxBorder = "─" * ($boxLabel.Length + 2)
Write-Host "  ┌$boxBorder┐" -ForegroundColor Yellow
Write-Host "  │ $boxLabel │" -ForegroundColor Yellow
Write-Host "  └$boxBorder┘" -ForegroundColor Yellow

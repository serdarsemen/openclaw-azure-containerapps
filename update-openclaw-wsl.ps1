# ---------------------------------------------------------------------------
# update-openclaw-wsl.ps1 — Rebuild and update OpenClaw Docker image in WSL
#
# Preserves existing gateway token, config, data, and volumes.
# Combines source-build and npm-install variants (controlled by -Npm switch).
#
# Without -Npm: source-build variant
# With    -Npm: npm-install variant
#
# Prerequisites: OpenClaw already deployed via deploy-openclaw-wsl.ps1
#
# Usage:
#   .\update-openclaw-wsl.ps1                                  # source build
#   .\update-openclaw-wsl.ps1 -Tag v2026.3.2                  # source build, pinned tag
#   .\update-openclaw-wsl.ps1 -Npm                             # npm install
#   .\update-openclaw-wsl.ps1 -PullOnly                        # skip rebuild, just restart
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [switch] $PullOnly,
    [string] $ContainerName = "openclaw",
    [string] $SourcePath    = "openclaw-repo",
    [string] $Tag           = "",
    [int]    $KeepImages    = 3    # retain N newest dangling images after rebuild
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Invoke-Wsl {
    param([string] $Command)
    $result = wsl bash -c $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command`n$result"
    }
    return $result
}

function Test-WslDocker {
    try {
        $null = Invoke-Wsl "docker info > /dev/null 2>&1"
        return $true
    } catch {
        return $false
    }
}

function New-WslTransferArchive {
    param(
        [string] $SourcePath,
        [string] $ArchiveName
    )

    $archiveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-wsl-transfer"
    if (-not (Test-Path $archiveRoot)) {
        New-Item -ItemType Directory -Path $archiveRoot | Out-Null
    }

    $windowsArchivePath = Join-Path $archiveRoot "$ArchiveName.tar"
    if (Test-Path $windowsArchivePath) {
        Remove-Item $windowsArchivePath -Force
    }

    $wslWindowsArchivePath = (Invoke-Wsl "wslpath -u '$($windowsArchivePath -replace '\\','/')'") -join ""
    $wslWindowsArchivePath = $wslWindowsArchivePath.Trim()

    Invoke-Wsl "set -e; rm -f '$wslWindowsArchivePath'; cd '$SourcePath' && tar --exclude=.git -cf '$wslWindowsArchivePath' ."

    return [pscustomobject]@{
        WindowsArchivePath = $windowsArchivePath
        WslWindowsArchivePath = $wslWindowsArchivePath
    }
}

function Expand-WslTransferArchive {
    param(
        [string] $ArchivePath,
        [string] $ContextName
    )

    $wslTransferRoot = "/tmp/openclaw-transfer"
    $wslContextRoot = "/tmp/openclaw-docker-context"
    $wslArchivePath = "$wslTransferRoot/$ContextName.tar"
    $wslContextPath = "$wslContextRoot/$ContextName"

    Invoke-Wsl "set -e; mkdir -p '$wslTransferRoot' '$wslContextRoot'; rm -f '$wslArchivePath'; rm -rf '$wslContextPath'; cp '$ArchivePath' '$wslArchivePath'; mkdir -p '$wslContextPath'; tar -xf '$wslArchivePath' -C '$wslContextPath'"

    return [pscustomobject]@{
        WslArchivePath = $wslArchivePath
        WslContextPath = $wslContextPath
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

if (-not (Test-WslDocker)) {
    Write-Host "  Docker not running — attempting to start..." -ForegroundColor Yellow
    # Use timeout to avoid hanging on sudo password prompt
    $startJob = Start-Job { wsl bash -c "sudo -n service docker start 2>/dev/null || service docker start 2>/dev/null" }
    $null = $startJob | Wait-Job -Timeout 10
    if ($startJob.State -eq 'Running') { $startJob | Stop-Job }
    $startJob | Remove-Job -Force
    Start-Sleep -Seconds 3
    if (-not (Test-WslDocker)) {
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

# Verify the container exists (was previously deployed)
$containerExists = Invoke-Wsl "docker ps -a --filter name=^${ContainerName}$ --format '{{.Names}}' 2>/dev/null"
if (-not ($containerExists -match $ContainerName)) {
    throw "Container '$ContainerName' not found. Run deploy-openclaw-wsl.ps1 first."
}
Write-Host "  Container '$ContainerName': found" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Discover existing configuration from running container
# ---------------------------------------------------------------------------
Write-Host "`n=== Discovering existing configuration ===" -ForegroundColor Cyan

# Read existing gateway token from the container environment
$existingToken = (Invoke-Wsl "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $ContainerName 2>/dev/null" |
    Where-Object { $_ -match '^OPENCLAW_GATEWAY_TOKEN=' }) -replace 'OPENCLAW_GATEWAY_TOKEN=', ''
$existingToken = ($existingToken -join "").Trim()

if (-not $existingToken) {
    Write-Warning "Could not read existing gateway token — generating a new one"
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $existingToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
}
Write-Host "  Gateway token: preserved" -ForegroundColor Green

# Read existing environment variables to preserve
$existingEnvLines = Invoke-Wsl "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $ContainerName 2>/dev/null"
$existingEnv = @{}
foreach ($line in $existingEnvLines) {
    $trimmed = "$line".Trim()
    if ($trimmed -match '^([^=]+)=(.*)$') {
        $existingEnv[$Matches[1]] = $Matches[2]
    }
}

$GroqApiKey  = $existingEnv['GROQ_API_KEY']
$OllamaHost  = $existingEnv['OLLAMA_HOST']
$GatewayPort = 18789
$BridgePort  = 18790

# Check if Ollama sidecar is part of this deployment
$ollamaContainerExists = $false
try {
    $ollamaCheck = Invoke-Wsl "docker ps -a --filter name=^${ContainerName}-ollama$ --format '{{.Names}}' 2>/dev/null"
    if ($ollamaCheck -match "${ContainerName}-ollama") {
        $ollamaContainerExists = $true
        Write-Host "  Ollama sidecar: found" -ForegroundColor Green
    }
} catch {}

# Discover the port mapping from the running container
$portMapping = (Invoke-Wsl "docker port $ContainerName 18789/tcp 2>/dev/null") -join ""
if ($portMapping -match ':(\d+)$') {
    $GatewayPort = [int]$Matches[1]
}
Write-Host "  Gateway port: $GatewayPort" -ForegroundColor Green

# Discover compose file path
$WslScriptRoot = (Invoke-Wsl "wslpath -u '$($PSScriptRoot -replace '\\','/')'") -join ""
$WslScriptRoot = $WslScriptRoot.Trim()
$WslComposePath = "$WslScriptRoot/docker-compose-wsl.yaml"
$composePath = Join-Path $PSScriptRoot "docker-compose-wsl.yaml"

if (-not (Test-Path $composePath)) {
    throw "docker-compose-wsl.yaml not found at $composePath. Was deploy-openclaw-wsl.ps1 run from this directory?"
}
Write-Host "  Compose file: found" -ForegroundColor Green

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

# ---------------------------------------------------------------------------
# Step 1/3: Rebuild image (unless -PullOnly)
# ---------------------------------------------------------------------------
if ($PullOnly) {
    Write-Host "`n=== Step 1/3: Skipping rebuild (-PullOnly) ===" -ForegroundColor Yellow
} else {
    if ($Npm) {
        # ===== NPM variant: create inline Dockerfile and rebuild =====
        Write-Host "`n=== Step 1/3: Rebuilding NPM image ===" -ForegroundColor Cyan

        $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-wsl-npm-build"
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
        New-Item -ItemType Directory -Path $buildDir | Out-Null

        $npmTag = if ($Tag) { $Tag } else { "latest" }

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

        $WslBuildDir = (Invoke-Wsl "wslpath -u '$($buildDir -replace '\\','/')'") -join ""
        $WslBuildDir = $WslBuildDir.Trim()

        Write-Host "  Step 1a: Rebuilding base image..." -ForegroundColor Gray
        Invoke-Wsl "docker build --no-cache -t ${ImageName}:base -f '$WslBuildDir/Dockerfile' '$WslBuildDir'"
        Write-Host "  Base image rebuilt: ${ImageName}:base" -ForegroundColor Green

        $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
        $WslToolsContext    = "$WslScriptRoot/images"

        Write-Host "  Step 1b: Rebuilding tools layer..." -ForegroundColor Gray
        Invoke-Wsl "docker build --no-cache -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
        Write-Host "  Tools image rebuilt: ${ImageName}:latest" -ForegroundColor Green

        Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

    } else {
        # ===== Source-build variant: pull/checkout and rebuild =====
        Write-Host "`n=== Step 1/3: Updating source and rebuilding image ===" -ForegroundColor Cyan

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

        $WslSourcePath = (Invoke-Wsl "wslpath -u '$($SourcePath -replace '\\','/')'") -join ""
        if ($WslSourcePath -notmatch '^/') {
            $WslSourcePath = "$WslScriptRoot/$SourcePath"
        }
        $WslSourcePath = $WslSourcePath.Trim()

        Write-Host "  Step 1a: Creating source archive..." -ForegroundColor Gray
        $SourceArchive = New-WslTransferArchive -SourcePath $WslSourcePath -ArchiveName "$ImageName-source"
        Write-Host "  Source archive created: $($SourceArchive.WindowsArchivePath)" -ForegroundColor Green

        Write-Host "  Step 1b: Transferring source archive to WSL..." -ForegroundColor Gray
        $WslBuildContext = Expand-WslTransferArchive -ArchivePath $SourceArchive.WslWindowsArchivePath -ContextName "$ImageName-source"
        Write-Host "  Build context (WSL): $($WslBuildContext.WslContextPath)" -ForegroundColor Green

        Write-Host "  Step 1c: Rebuilding base image from source..." -ForegroundColor Gray
        Invoke-Wsl "docker build --no-cache -t ${ImageName}:base -f '$($WslBuildContext.WslContextPath)/Dockerfile' '$($WslBuildContext.WslContextPath)'"
        Write-Host "  Base image rebuilt: ${ImageName}:base" -ForegroundColor Green

        $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
        $WslToolsContext    = "$WslScriptRoot/images"

        Write-Host "  Step 1d: Rebuilding tools layer..." -ForegroundColor Gray
        Invoke-Wsl "docker build --no-cache -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
        Write-Host "  Tools image rebuilt: ${ImageName}:latest" -ForegroundColor Green

        Remove-Item $SourceArchive.WindowsArchivePath -Force -ErrorAction SilentlyContinue
        try {
            Invoke-Wsl "rm -f '$($WslBuildContext.WslArchivePath)'"
        } catch {}
    }

    # Prune old dangling images to save disk space
    Write-Host "  Pruning dangling images..." -ForegroundColor Gray
    try { Invoke-Wsl "docker image prune -f 2>/dev/null" } catch {}
}

# ---------------------------------------------------------------------------
# Step 2/3: Restart containers with the new image
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 2/3: Restarting containers ===" -ForegroundColor Cyan

Write-Host "  Stopping existing containers..." -ForegroundColor Gray
Invoke-Wsl "docker compose -f '$WslComposePath' down"

# Pull latest Ollama image if sidecar is in use
if ($ollamaContainerExists) {
    Write-Host "  Pulling latest Ollama image..." -ForegroundColor Gray
    try {
        Invoke-Wsl "docker pull ollama/ollama:latest"
        Write-Host "  Ollama image updated" -ForegroundColor Green
    } catch {
        Write-Warning "  Failed to pull latest Ollama image — will use cached version"
    }
}

Write-Host "  Starting containers with updated image..." -ForegroundColor Gray
Invoke-Wsl "docker compose -f '$WslComposePath' up -d"
Write-Host "  Containers restarted" -ForegroundColor Green

# Wait for the gateway to become healthy
Write-Host "`n  Waiting for gateway to become healthy..."
$maxAttempts = 30
$attempt = 0
$healthy = $false
while ($attempt -lt $maxAttempts) {
    $attempt++
    Start-Sleep -Seconds 5
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:${GatewayPort}/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host "  Gateway is healthy (attempt $attempt/$maxAttempts)" -ForegroundColor Green
            $healthy = $true
            break
        }
    } catch {}
    Write-Host "  Not ready yet — retrying in 5s ($attempt/$maxAttempts)..." -ForegroundColor Gray
}
if (-not $healthy) {
    Write-Warning "Gateway did not become healthy after $maxAttempts attempts — check logs: wsl docker logs $ContainerName"
}

# ---------------------------------------------------------------------------
# Step 3/3: Show status and recent logs
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/3: Post-update status ===" -ForegroundColor Cyan

$containerImage = (Invoke-Wsl "docker inspect --format '{{.Config.Image}}' $ContainerName 2>/dev/null") -join ""
$containerImage = $containerImage.Trim()

Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Invoke-Wsl "docker logs --tail 30 $ContainerName 2>&1" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host "`n=== Update complete ===" -ForegroundColor Green

$variantLabel = if ($Npm) { "npm" } else { "source" }
$refLabel = if (-not $Npm -and $ref) { " to: $ref" } else { "" }
Write-Host "  OpenClaw ($variantLabel) updated$refLabel — image: $containerImage" -ForegroundColor Green
Write-Host ""
$tokenPadded = $existingToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Gateway:    http://localhost:${GatewayPort}" -ForegroundColor White
Write-Host "  Control UI: http://localhost:${GatewayPort}/#token=$existingToken" -ForegroundColor White
if ($ollamaContainerExists) {
    Write-Host "  Ollama:     http://localhost:11434" -ForegroundColor White
} elseif ($OllamaHost) {
    Write-Host "  Ollama:     $OllamaHost (external)" -ForegroundColor White
}
Write-Host ""
if ($ollamaContainerExists) {
    Write-Host "=== Ollama commands ===" -ForegroundColor Cyan
    Write-Host "  Pull model:      wsl docker exec ${ContainerName}-ollama ollama pull <model>" -ForegroundColor Gray
    Write-Host "  List models:     wsl docker exec ${ContainerName}-ollama ollama list" -ForegroundColor Gray
    Write-Host "  Run model:       wsl docker exec -it ${ContainerName}-ollama ollama run <model>" -ForegroundColor Gray
    Write-Host "  Ollama logs:     wsl docker logs -f ${ContainerName}-ollama" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "  Your gateway token, config, and data are unchanged." -ForegroundColor Green
Write-Host ""
Write-Host "=== Useful commands ===" -ForegroundColor Cyan
Write-Host "  View logs:       wsl docker logs -f $ContainerName" -ForegroundColor Gray
Write-Host "  Shell into:      wsl docker exec -it $ContainerName bash" -ForegroundColor Gray
Write-Host "  Stop:            wsl docker compose -f docker-compose-wsl.yaml down" -ForegroundColor Gray
Write-Host "  Restart:         wsl docker compose -f docker-compose-wsl.yaml restart" -ForegroundColor Gray

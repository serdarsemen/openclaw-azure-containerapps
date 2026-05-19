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
#   - -OllamaWsl: use Ollama running natively in WSL (auto-detects IP)
#   - -OllamaHost <url>: use an external Ollama instance at a custom URL
#   - -OllamaModel <name>: pull only this model instead of the default set
#
# Important: For -OllamaWindows, Ollama on Windows must listen on 0.0.0.0
#   (not 127.0.0.1). Set OLLAMA_HOST=0.0.0.0:11434 in Windows environment
#   variables and restart the Ollama service.
#
# Prerequisites:
#   - WSL 2 with a Linux distro installed
#   - Docker Engine running inside WSL (or Docker Desktop with WSL 2 backend)
#
# Usage:
#   .\deploy-openclaw-wsl.ps1                                  # source build
#   .\deploy-openclaw-wsl.ps1 -Tag v2026.2.15                  # source build, pinned tag
#   .\deploy-openclaw-wsl.ps1 -Npm                             # npm install
#   .\deploy-openclaw-wsl.ps1 -Ollama                          # add Ollama sidecar in Docker
#   .\deploy-openclaw-wsl.ps1 -Ollama -OllamaModel llama3.1:8b # sidecar + specific model
#   .\deploy-openclaw-wsl.ps1 -OllamaWindows                   # use Ollama on Windows host
#   .\deploy-openclaw-wsl.ps1 -OllamaWsl                       # use Ollama running in WSL
#   .\deploy-openclaw-wsl.ps1 -OllamaHost http://host.docker.internal:11434
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [switch] $Ollama,
    [bool]   $OllamaWindows = $true,
    [switch] $OllamaWsl,
    [string] $ContainerName = "openclaw",
    [string] $SourcePath    = "openclaw-repo",
    [string] $Tag           = "",
    [int]    $GatewayPort   = 18789,
    [int]    $BridgePort    = 18790,
    [string] $DataDir       = "",
    [string] $OllamaHost    = "",
    [string] $OllamaModel   = "",
    [string] $GroqApiKey    = ""
)

$ErrorActionPreference = "Stop"

# If another Ollama mode is explicitly specified, disable the OllamaWindows default
if ($Ollama -or $OllamaWsl -or $OllamaHost) {
    if (-not $PSBoundParameters.ContainsKey('OllamaWindows')) {
        $OllamaWindows = $false
    }
}

# Validate Ollama mode — only one allowed at a time
$ollamaModeCount = @($Ollama, $OllamaWindows, $OllamaWsl, [bool]$OllamaHost).Where({ $_ }).Count
if ($ollamaModeCount -gt 1) {
    throw "Only one Ollama mode allowed at a time: -Ollama (Docker sidecar), -OllamaWindows, -OllamaWsl, or -OllamaHost <url>"
}

# Load shared WSL helpers (Invoke-Wsl, Invoke-WslData, Test-WslDocker,
# Start-WslDocker, Repair-WslDns, New/Expand-WslTransferArchive,
# Resolve-OllamaHost, New-OpenClawComposeYaml).
. "$PSScriptRoot/wsl-helpers.ps1"

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
# Resolve -OllamaWindows / -OllamaWsl / -OllamaHost to a concrete URL
# ---------------------------------------------------------------------------
if ($OllamaWindows -or $OllamaWsl) {
    $resolved = Resolve-OllamaHost -OllamaWindows:$OllamaWindows -OllamaWsl:$OllamaWsl -OllamaHost $OllamaHost
    $OllamaHost = $resolved.OllamaHost
}

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

# Data directory — persists config, workspace, and SQLite across restarts
if (-not $DataDir) {
    $DataDir = Join-Path $PSScriptRoot "openclaw-data"
}
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
    Write-Host "  Created data directory: $DataDir" -ForegroundColor Gray
}
$WslDataDir = Invoke-WslData "wslpath -u '$($DataDir -replace '\\','/')'"
$WslDataDir = ($WslDataDir -join "").Trim()
Write-Host "  Data dir (WSL): $WslDataDir" -ForegroundColor Green

# Convert script root and source path to WSL paths
$WslScriptRoot = (Invoke-WslData "wslpath -u '$($PSScriptRoot -replace '\\','/')'")
$WslScriptRoot = $WslScriptRoot.Trim()

# ---------------------------------------------------------------------------
# Step 1: Build image
# ---------------------------------------------------------------------------
$totalSteps = if ($Ollama -and (-not $OllamaHost)) { 6 } else { 5 }
if ($Npm) {
    # ===== NPM variant: create inline Dockerfile and build locally =====
    Write-Host "`n=== Step 1/${totalSteps}: Creating Dockerfile (Debian Slim + npm) ===" -ForegroundColor Cyan

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
    Write-Host "  Dockerfile created at $buildDir" -ForegroundColor Green

    $WslBuildDir = (Invoke-WslData "wslpath -u '$($buildDir -replace '\\','/')'")
    $WslBuildDir = $WslBuildDir.Trim()

    Write-Host "`n=== Step 2/${totalSteps}: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    try {
        Write-Host "  Step 2a: Building base image..." -ForegroundColor Gray
        Invoke-Wsl "DOCKER_BUILDKIT=1 docker build --network=host -t ${ImageName}:base -f '$WslBuildDir/Dockerfile' '$WslBuildDir'"
        Write-Host "  Base image built: ${ImageName}:base" -ForegroundColor Green

        # Copy tools Dockerfile to WSL-accessible path
        $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
        $WslToolsContext    = "$WslScriptRoot/images"

        Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
        Invoke-Wsl "DOCKER_BUILDKIT=1 docker build --network=host -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
        Write-Host "  Tools image built: ${ImageName}:latest" -ForegroundColor Green

        # Remove intermediate base image — only the final :latest image should remain
        Write-Host "  Removing intermediate base image..." -ForegroundColor Gray
        Invoke-Wsl "docker rmi ${ImageName}:base 2>/dev/null || true"
        Write-Host "  Intermediate image removed" -ForegroundColor Green
    } finally {
        Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    }

} else {
    # ===== Source-build variant: pull/checkout source and build locally =====
    Write-Host "`n=== Step 1/${totalSteps}: Cloning/updating OpenClaw source ===" -ForegroundColor Cyan

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
            Write-Host "  Fetching latest main (single-branch, pruning stale refs)..."
            git fetch --prune origin +refs/heads/main:refs/remotes/origin/main
            if ($LASTEXITCODE -ne 0) { throw "Git fetch failed" }
            git checkout main
            if ($LASTEXITCODE -ne 0) { throw "Git checkout 'main' failed" }
            git reset --hard origin/main
            if ($LASTEXITCODE -ne 0) { throw "Git reset failed" }
        }
    } finally {
        Pop-Location
    }

    $ref = if ($Tag) { $Tag } else { "latest (main)" }
    Write-Host "  Source updated to: $ref" -ForegroundColor Green

    Write-Host "`n=== Step 2/${totalSteps}: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    $WslSourcePath = (Invoke-WslData "wslpath -u '$($SourcePath -replace '\\','/')'")
    # Handle relative paths — prepend script root if not already absolute
    if ($WslSourcePath -notmatch '^/') {
        $WslSourcePath = "$WslScriptRoot/$SourcePath"
    }
    $WslSourcePath = $WslSourcePath.Trim()

    Write-Host "  Step 2a: Packaging source as WSL transfer archive..." -ForegroundColor Gray
    $SourceArchive = New-WslTransferArchive -SourcePath $WslSourcePath -ArchiveName "$ImageName-source"
    Write-Host "  Source archive (WSL): $($SourceArchive.WslArchivePath)" -ForegroundColor Green

    Write-Host "  Step 2b: Expanding source archive in WSL..." -ForegroundColor Gray
    $WslBuildContext = Expand-WslTransferArchive -ArchivePath $SourceArchive.WslArchivePath -ContextName "$ImageName-source"
    Write-Host "  Build context (WSL): $($WslBuildContext.WslContextPath)" -ForegroundColor Green

    # Patch Dockerfile for local Docker compatibility:
    # - Strip '# syntax=docker/dockerfile:...' (avoids pulling BuildKit frontend image — fails when WSL DNS is flaky)
    # - Keep --mount=type=cache directives — BuildKit is the default builder in Docker 23.0+ (WSL)
    #   and cache mounts dramatically speed up rebuilds (pnpm store, apt cache).
    Write-Host "  Step 2c: Patching Dockerfile for local Docker compatibility..." -ForegroundColor Gray
    Invoke-Wsl "sed -i '1s|^# syntax=docker/dockerfile:.*||' '$($WslBuildContext.WslContextPath)/Dockerfile'"
    Write-Host "  Stripped syntax directive (keeping BuildKit cache mounts for faster rebuilds)" -ForegroundColor Green

    try {
        Write-Host "  Step 2d: Building base OpenClaw image from source..." -ForegroundColor Gray
        Invoke-Wsl "DOCKER_BUILDKIT=1 docker build --network=host -t ${ImageName}:base -f '$($WslBuildContext.WslContextPath)/Dockerfile' '$($WslBuildContext.WslContextPath)'"
        Write-Host "  Base image built: ${ImageName}:base" -ForegroundColor Green

        $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
        $WslToolsContext    = "$WslScriptRoot/images"

        Write-Host "  Step 2e: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
        Invoke-Wsl "DOCKER_BUILDKIT=1 docker build --network=host -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
        Write-Host "  Tools image built: ${ImageName}:latest" -ForegroundColor Green

        # Remove intermediate base image — only the final :latest image should remain
        Write-Host "  Removing intermediate base image..." -ForegroundColor Gray
        Invoke-Wsl "docker rmi ${ImageName}:base 2>/dev/null || true"
        Write-Host "  Intermediate image removed" -ForegroundColor Green
    } finally {
        try { Invoke-Wsl "rm -rf '$($SourceArchive.WslArchivePath)' '$($WslBuildContext.WslContextPath)'" } catch {}
    }
}

# ---------------------------------------------------------------------------
# Step 3: Resolve gateway token (reuse existing or generate new)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/${totalSteps}: Resolving gateway token ===" -ForegroundColor Cyan
$GatewayToken = $null
$existingConfigPath = Join-Path $DataDir "openclaw.json"
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
if (-not $GatewayToken) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
    Write-Host "  New token generated (save this for Control UI access):" -ForegroundColor Gray
}
Write-Host "  $GatewayToken" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Step 4/5: Create docker-compose and start containers
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4/${totalSteps}: Starting containers via docker-compose ===" -ForegroundColor Cyan

$ollamaEnabled = $Ollama -and (-not $OllamaHost)
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
    -Npm:$Npm

# Write compose file
$composePath = Join-Path $PSScriptRoot "docker-compose-wsl.yaml"
$composeYaml | Set-Content $composePath -Encoding utf8
Write-Host "  docker-compose file written to: $composePath" -ForegroundColor Gray

$WslComposePath = "$WslScriptRoot/docker-compose-wsl.yaml"

# Stop any existing containers with the same name
Write-Host "  Stopping any existing containers..." -ForegroundColor Gray
try { Invoke-Wsl "docker compose -f '$WslComposePath' down 2>/dev/null" } catch {}

# Clean up stale plugin-runtime-deps locks from previous failed deployments
Write-Host "  Cleaning up stale plugin-runtime-deps locks..." -ForegroundColor Gray
try {
    # The lock is a directory; remove any version-named lock dirs entirely
    Invoke-Wsl "find '$WslDataDir/plugin-runtime-deps' -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true"
} catch {}

# Write config directly to openclaw.json BEFORE starting containers.
# This ensures the gateway reads correct auth/model settings on boot.
# Writing via docker exec is impossible because the running gateway holds the
# runtime-deps lock exclusively, causing any CLI command to deadlock.
$configPath = Join-Path $DataDir "openclaw.json"

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
if (-not $config.agents.defaults.model) { $config.agents.defaults | Add-Member -NotePropertyName model -NotePropertyValue ([pscustomobject]@{}) }

# Gateway settings
$config.gateway.auth.mode  = "token"
$config.gateway.auth.token = $GatewayToken
$config.gateway.auth.rateLimit.maxAttempts = 10
$config.gateway.auth.rateLimit.windowMs    = 60000
$config.gateway.auth.rateLimit.lockoutMs   = 300000
$config.gateway.port = 18789
$config.gateway.bind = "lan"
$config.gateway.mode = "local"
$config.gateway.controlUi.allowInsecureAuth = $true
$config.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = $true

# Model
$config.agents.defaults.model.primary = "github-copilot/claude-opus-4.6"

# Write back
$config | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding utf8
Write-Host "  Config written to openclaw.json (token + model + gateway settings)" -ForegroundColor Green

Write-Host "  Starting containers..." -ForegroundColor Gray
Invoke-Wsl "docker compose -f '$WslComposePath' up -d"
Write-Host "  Containers started" -ForegroundColor Green

# Docker Compose healthcheck handles readiness; no need to poll from Windows/WSL.
Write-Host "  Containers are starting — Docker healthcheck will verify readiness." -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Step 5/5: Configure OpenClaw (non-interactive)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 5/${totalSteps}: Configuring OpenClaw ===" -ForegroundColor Cyan

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
    while ((Get-Date) -lt $deadline) {
        $check = wsl bash -c "docker exec $ContainerName bash -c 'timeout 3 bash -c ""</dev/tcp/localhost/18789"" 2>/dev/null && echo READY || echo NOT_READY'" 2>$null
        if ($check -match "READY") {
            Write-Host "  OpenClaw gateway: ready" -ForegroundColor Green
            return $true
        }
        # Surface latest log line so user can see progress
        $logLine = (wsl bash -c "docker logs --tail 1 $ContainerName 2>&1") -join ""
        if ($logLine -and $logLine -ne $lastMsg) {
            Write-Host "  [container] $logLine" -ForegroundColor DarkGray
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

if (-not (Wait-OpenClawReady -TimeoutSec 600)) {
    throw "OpenClaw did not become ready — check logs: wsl docker logs $ContainerName"
}

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
if ($ollamaEnabled) {
    Write-Host "  Ollama:     http://localhost:11434 (Docker sidecar)" -ForegroundColor White
    Write-Host "  Models:     $(if ($OllamaModel) { $OllamaModel } else { 'qwen2.5-coder:7b, deepseek-r1:8b, qwen2.5:7b' })" -ForegroundColor White
} elseif ($OllamaHost) {
    $ollamaLabel = if ($OllamaWindows) { "Windows host" } elseif ($OllamaWsl) { "WSL native" } else { "external" }
    Write-Host "  Ollama:     $OllamaHost ($ollamaLabel)" -ForegroundColor White
} else {
    Write-Host "  Ollama:     disabled" -ForegroundColor White
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
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow

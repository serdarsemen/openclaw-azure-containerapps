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
#   - -Ollama: add Ollama sidecar container and pull models
#   - -OllamaHost <url>: use an external Ollama instance (no sidecar)
#   - -OllamaModel <name>: pull only this model instead of the default set
#
# Prerequisites:
#   - WSL 2 with a Linux distro installed
#   - Docker Engine running inside WSL (or Docker Desktop with WSL 2 backend)
#
# Usage:
#   .\deploy-openclaw-wsl.ps1                                  # source build
#   .\deploy-openclaw-wsl.ps1 -Tag v2026.2.15                  # source build, pinned tag
#   .\deploy-openclaw-wsl.ps1 -Npm                             # npm install
#   .\deploy-openclaw-wsl.ps1 -Ollama                          # add Ollama sidecar
#   .\deploy-openclaw-wsl.ps1 -Ollama -OllamaModel llama3.1:8b # sidecar + specific model
#   .\deploy-openclaw-wsl.ps1 -OllamaHost http://host.docker.internal:11434
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [switch] $Ollama,
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

function Invoke-WslData {
    param([string] $Command)
    $result = wsl bash -c $Command 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command"
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

    $wslTransferRoot = "/tmp/openclaw-transfer"
    $wslArchivePath = "$wslTransferRoot/$ArchiveName.tar"

    Invoke-Wsl "set -e; mkdir -p '$wslTransferRoot'; rm -f '$wslArchivePath'; git -C '$SourcePath' archive --format=tar --output '$wslArchivePath' HEAD"

    return [pscustomobject]@{
        WslArchivePath = $wslArchivePath
    }
}

function Expand-WslTransferArchive {
    param(
        [string] $ArchivePath,
        [string] $ContextName
    )

    $wslContextRoot = "/tmp/openclaw-docker-context"
    $wslContextPath = "$wslContextRoot/$ContextName"

    Invoke-Wsl "set -e; mkdir -p '$wslContextRoot'; rm -rf '$wslContextPath'; mkdir -p '$wslContextPath'; tar -xf '$ArchivePath' -C '$wslContextPath'"

    return [pscustomobject]@{
        WslContextPath = $wslContextPath
    }
}

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
    Write-Host "  Docker not running — attempting to start..." -ForegroundColor Yellow
    # Use timeout to avoid hanging on sudo password prompt
    $startJob = Start-Job { wsl bash -c "sudo -n service docker start 2>/dev/null || service docker start 2>/dev/null" }
    $null = $startJob | Wait-Job -Timeout 10
    if ($startJob.State -eq 'Running') { $startJob | Stop-Job }
    $startJob | Remove-Job -Force
    $dockerReady = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        if (Test-WslDocker) {
            $dockerReady = $true
            break
        }
        if ($attempt -lt 6) {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $dockerReady) {
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
$dnsOk = $false
try {
    $dnsResult = wsl bash -c "getent hosts registry.npmjs.org > /dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL" 2>$null
    if ($dnsResult -match "DNS_OK") { $dnsOk = $true }
} catch {}

if (-not $dnsOk) {
    Write-Host "  WSL DNS is broken — reconfiguring to use public resolvers (8.8.8.8, 1.1.1.1)..." -ForegroundColor Yellow
    # Overwrite resolv.conf with Google + Cloudflare public DNS
    wsl bash -c "sudo sh -c 'rm -f /etc/resolv.conf; printf ""nameserver 8.8.8.8\nnameserver 1.1.1.1\n"" > /etc/resolv.conf'" 2>$null
    # Prevent WSL from overwriting resolv.conf on next restart
    wsl bash -c "sudo sh -c 'grep -q generateResolvConf /etc/wsl.conf 2>/dev/null || printf ""\n[network]\ngenerateResolvConf = false\n"" >> /etc/wsl.conf'" 2>$null
    # Verify the fix
    try {
        $dnsResult = wsl bash -c "getent hosts registry.npmjs.org > /dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL" 2>$null
        if ($dnsResult -match "DNS_OK") {
            Write-Host "  DNS fixed (using 8.8.8.8 / 1.1.1.1)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: DNS still broken after reconfiguration — build may fail" -ForegroundColor Yellow
            Write-Host "  Try: wsl --shutdown, then re-run this script" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  WARNING: Could not verify DNS fix" -ForegroundColor Yellow
    }
} else {
    Write-Host "  DNS: OK" -ForegroundColor Green
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

        Write-Host "  Step 2e: Building tools layer (Go, gh, gemini, gog)..." -ForegroundColor Gray
        Invoke-Wsl "DOCKER_BUILDKIT=1 docker build --network=host -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
        Write-Host "  Tools image built: ${ImageName}:latest" -ForegroundColor Green
    } finally {
        try { Invoke-Wsl "rm -rf '$($SourceArchive.WslArchivePath)' '$($WslBuildContext.WslContextPath)'" } catch {}
    }
}

# ---------------------------------------------------------------------------
# Step 3: Generate gateway token
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/${totalSteps}: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "  Token generated (save this for Control UI access):" -ForegroundColor Gray
Write-Host "  $GatewayToken" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Step 4/5: Create docker-compose and start containers
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4/${totalSteps}: Starting containers via docker-compose ===" -ForegroundColor Cyan

# Build environment variables for the container
$envVars = @(
    "OPENCLAW_GATEWAY_TOKEN=$GatewayToken",
    "NODE_ENV=production",
    "HOME=$HomeDir",
    "TERM=xterm-256color",
    "REDIS_HOST=redis",
    "REDIS_PORT=6379"
)
if ($GroqApiKey) {
    $envVars += "GROQ_API_KEY=$GroqApiKey"
}
if ($OllamaHost) {
    $envVars += "OLLAMA_HOST=$OllamaHost"
} elseif ($Ollama) {
    $envVars += "OLLAMA_HOST=http://ollama:11434"
}
$envVars += "OPENCLAW_DISABLE_BONJOUR=true"

# Build the startup command
if ($Npm) {
    $startupCmd = @(
        "find $HomeDir/.openclaw/plugin-runtime-deps -name '.openclaw-runtime-mirror.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
        "(openclaw config set gateway.controlUi.allowInsecureAuth true || true)",
        "(openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true)",
        "(openclaw config set gateway.auth.rateLimit.maxAttempts 10 || true)",
        "(openclaw config set gateway.auth.rateLimit.windowMs 60000 || true)",
        "(openclaw config set gateway.auth.rateLimit.lockoutMs 300000 || true)",
        "(openclaw config set browser.executablePath /usr/bin/chromium || true)",
        "npm config set prefix '~/.openclaw/npm-global'",
        "mkdir -p $HomeDir/.openclaw/workspace/memory",
        "mkdir -p $HomeDir/.cache/qmd/models",
        "mkdir -p `"`$`$GOPATH/bin`"",
        "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
        "mkdir -p `$`$HOME/.openclaw/compile-cache",
        "chmod 600 $HomeDir/.openclaw/agents/main/sessions/sessions.json 2>/dev/null || true",
        "export OPENCLAW_NO_RESPAWN=1",
        "openclaw gateway --allow-unconfigured --bind lan --port 18789"
    ) -join " && "
    $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/usr/local/lib/node_modules/openclaw/dist/extensions"
} else {
    $startupCmd = @(
        "find $HomeDir/.openclaw/plugin-runtime-deps -name '.openclaw-runtime-mirror.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
        "chmod -R 755 /app/dist/extensions",
        "mkdir -p $HomeDir/.openclaw/workspace/memory",
        "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
        "mkdir -p `$`$HOME/.openclaw/compile-cache",
        "(node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true)",
        "(node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true)",
        "(node openclaw.mjs config set gateway.auth.rateLimit.maxAttempts 10 || true)",
        "(node openclaw.mjs config set gateway.auth.rateLimit.windowMs 60000 || true)",
        "(node openclaw.mjs config set gateway.auth.rateLimit.lockoutMs 300000 || true)",
        "chmod 600 $HomeDir/.openclaw/agents/main/sessions/sessions.json 2>/dev/null || true",
        "export OPENCLAW_NO_RESPAWN=1",
        "node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789"
    ) -join " && "
    $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/app/dist/extensions"
}

# Build the environment block for docker-compose
$envBlock = ($envVars | ForEach-Object { "      - $_" }) -join "`n"

$composeYaml = @"
version: '3.9'

networks:
  openclaw-net:
    driver: bridge

volumes:
  redis-data:
    driver: local
  openclaw-runtime-deps:
    driver: local
  openclaw-compile-cache:
    driver: local

services:
  openclaw:
    image: ${ImageName}:latest
    container_name: $ContainerName
    networks:
      - openclaw-net
    environment:
$envBlock
    volumes:
      - ${WslDataDir}:${HomeDir}/.openclaw
      - openclaw-runtime-deps:${HomeDir}/.openclaw/plugin-runtime-deps
      - openclaw-compile-cache:${HomeDir}/.openclaw/compile-cache
    ports:
      - "${GatewayPort}:18789"
      - "${BridgePort}:18790"
    init: true
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 6G
        reservations:
          cpus: '2'
          memory: 4G
    command:
      - bash
      - -c
      - >-
        $startupCmd
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 300s
    depends_on:
      redis:
        condition: service_healthy

  redis:
    image: redis:7-alpine
    container_name: ${ContainerName}-redis
    networks:
      - openclaw-net
    volumes:
      - redis-data:/data
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --dir
      - /data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
"@

# Add Ollama sidecar only when -Ollama is specified (and no external host)
$ollamaEnabled = $Ollama -and (-not $OllamaHost)
if ($ollamaEnabled) {
    Write-Host "  Ollama sidecar: enabled" -ForegroundColor Green

    $composeYaml += @"

  ollama:
    image: ollama/ollama:latest
    container_name: ${ContainerName}-ollama
    networks:
      - openclaw-net
    volumes:
      - ./ollama-data:/root/.ollama
    ports:
      - "11434:11434"
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:11434/"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
"@
}

if (-not $Ollama) {
    Write-Host "  Ollama: not enabled (use -Ollama to add sidecar)" -ForegroundColor Gray
}

# Write compose file
$composePath = Join-Path $PSScriptRoot "docker-compose-wsl.yaml"
$composeYaml | Set-Content $composePath -Encoding utf8
Write-Host "  docker-compose file written to: $composePath" -ForegroundColor Gray

$WslComposePath = "$WslScriptRoot/docker-compose-wsl.yaml"

# Stop any existing containers with the same name
Write-Host "  Stopping any existing containers..." -ForegroundColor Gray
try { Invoke-Wsl "docker compose -f '$WslComposePath' down 2>/dev/null" } catch {}

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
        $output = wsl bash -c "docker exec $ContainerName bash -c 'timeout $ExecTimeoutSec $Command'" 2>&1
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

if ($Npm) {
    Invoke-DockerExec -Label "Onboard" `
        -Command "openclaw onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token $GatewayToken --skip-channels --skip-skills --skip-daemon --skip-health"

    Invoke-DockerExec -Label "Model set" `
        -Command "openclaw models set github-copilot/claude-opus-4.6"

    try {
        $auditOk = Invoke-DockerExec -Label "Security audit" `
            -Command "openclaw security audit" `
            -MaxRetries 2 -ExecTimeoutSec 30 `
            -ContinueOnFailure
        if (-not $auditOk) {
            Write-Warning "[Security audit] skipped due to runtime/plugin issue; deployment continues"
        }
    } catch {
        Write-Warning "[Security audit] non-fatal error: $($_.Exception.Message)"
    }
} else {
    Invoke-DockerExec -Label "Onboard" `
        -Command "node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token $GatewayToken --skip-channels --skip-skills --skip-daemon --skip-health"

    Invoke-DockerExec -Label "Model set" `
        -Command "node openclaw.mjs models set github-copilot/claude-opus-4.6"

    try {
        $auditOk = Invoke-DockerExec -Label "Security audit" `
            -Command "node openclaw.mjs security audit" `
            -MaxRetries 2 -ExecTimeoutSec 30 `
            -ContinueOnFailure
        if (-not $auditOk) {
            Write-Warning "[Security audit] skipped due to runtime/plugin issue; deployment continues"
        }
    } catch {
        Write-Warning "[Security audit] non-fatal error: $($_.Exception.Message)"
    }
}

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
    Write-Host "  Ollama:     http://localhost:11434" -ForegroundColor White
    Write-Host "  Models:     $(if ($OllamaModel) { $OllamaModel } else { 'qwen2.5-coder:7b, deepseek-r1:8b, qwen2.5:7b' })" -ForegroundColor White
} elseif ($OllamaHost) {
    Write-Host "  Ollama:     $OllamaHost (external)" -ForegroundColor White
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


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
#   .\update-openclaw-wsl.ps1 -NoCache                         # rebuild without Docker cache
#   .\update-openclaw-wsl.ps1 -PullOnly                        # skip rebuild, just restart
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [switch] $NoCache,
    [switch] $PullOnly,
    [string] $ContainerName = "openclaw",
    [string] $SourcePath    = "openclaw-repo",
    [string] $Tag           = ""
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

function Invoke-NonFatalSecurityAudit {
    param(
        [string] $Command,
        [int]    $ExecTimeoutSec = 45
    )

    Write-Host "  [Security audit] attempt 1/1" -ForegroundColor Gray
    $output = wsl bash -c "docker exec $ContainerName bash -c 'timeout $ExecTimeoutSec $Command'" 2>&1

    if ($LASTEXITCODE -eq 0) {
        if ($output) { Write-Host "    $output" -ForegroundColor DarkGray }
        return $true
    }

    if ($LASTEXITCODE -eq 124) {
        Write-Warning "[Security audit] timed out after ${ExecTimeoutSec}s"
    }
    if ($output) { Write-Host "    $output" -ForegroundColor DarkGray }
    Write-Warning "[Security audit] skipped due to runtime/plugin issue; update continues"
    return $false
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

# Verify the container exists (was previously deployed)
$containerExists = Invoke-WslData "docker ps -a --filter name=^${ContainerName}$ --format '{{.Names}}'"
if (-not ($containerExists -match $ContainerName)) {
    throw "Container '$ContainerName' not found. Run deploy-openclaw-wsl.ps1 first."
}
Write-Host "  Container '$ContainerName': found" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Discover existing configuration from running container
# ---------------------------------------------------------------------------
Write-Host "`n=== Discovering existing configuration ===" -ForegroundColor Cyan

# Read existing gateway token from the container environment
$existingToken = (Invoke-WslData "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $ContainerName" |
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
$existingEnvLines = Invoke-WslData "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $ContainerName"
$existingEnv = @{}
foreach ($line in $existingEnvLines) {
    $trimmed = "$line".Trim()
    if ($trimmed -match '^([^=]+)=(.*)$') {
        $existingEnv[$Matches[1]] = $Matches[2]
    }
}

$OllamaHost  = $existingEnv['OLLAMA_HOST']
$GatewayPort = 18789

# Check if Ollama sidecar is part of this deployment
$ollamaContainerExists = $false
try {
    $ollamaCheck = Invoke-WslData "docker ps -a --filter name=^${ContainerName}-ollama$ --format '{{.Names}}'"
    if ($ollamaCheck -match "${ContainerName}-ollama") {
        $ollamaContainerExists = $true
        Write-Host "  Ollama sidecar: found" -ForegroundColor Green
    }
} catch {}

# Discover the port mapping from the running container
$portMapping = (Invoke-WslData "docker port $ContainerName 18789/tcp") -join ""
if ($portMapping -match ':(\d+)$') {
    $GatewayPort = [int]$Matches[1]
}
Write-Host "  Gateway port: $GatewayPort" -ForegroundColor Green

# Discover compose file path
$WslScriptRoot = (Invoke-WslData "wslpath -u '$($PSScriptRoot -replace '\\','/')'")
$WslScriptRoot = $WslScriptRoot.Trim()
$WslComposePath = "$WslScriptRoot/docker-compose-wsl.yaml"
$composePath = Join-Path $PSScriptRoot "docker-compose-wsl.yaml"

if (-not (Test-Path $composePath)) {
    throw "docker-compose-wsl.yaml not found at $composePath. Was deploy-openclaw-wsl.ps1 run from this directory?"
}
Write-Host "  Compose file: found" -ForegroundColor Green

# Normalize bundled plugin paths in existing compose files so updates also
# pick up deploy-time plugin runtime fixes.
$composeRaw = Get-Content $composePath -Raw
$composeUpdated = $composeRaw `
    -replace '/app/extensions', '/app/dist/extensions' `
    -replace '/usr/local/lib/node_modules/openclaw/extensions', '/usr/local/lib/node_modules/openclaw/dist/extensions'
if ($composeUpdated -ne $composeRaw) {
    $composeUpdated | Set-Content $composePath -Encoding utf8
    Write-Host "  Compose file: patched bundled plugin runtime paths" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Set variant-specific defaults
# ---------------------------------------------------------------------------
if ($Npm) {
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    $ImageName       = "openclaw-npm"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
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
    $dockerBuildCacheArg = if ($NoCache) { "--no-cache " } else { "" }
    $dockerBuildCacheState = if ($NoCache) { "disabled" } else { "enabled" }
    Write-Host "  Docker layer cache: $dockerBuildCacheState" -ForegroundColor DarkGray

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

        $WslBuildDir = (Invoke-WslData "wslpath -u '$($buildDir -replace '\\','/')'")
        $WslBuildDir = $WslBuildDir.Trim()

        try {
            Write-Host "  Step 1a: Rebuilding base image..." -ForegroundColor Gray
            Invoke-Wsl "docker build --network=host ${dockerBuildCacheArg}-t ${ImageName}:base -f '$WslBuildDir/Dockerfile' '$WslBuildDir'"
            Write-Host "  Base image rebuilt: ${ImageName}:base" -ForegroundColor Green

            $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
            $WslToolsContext    = "$WslScriptRoot/images"

            Write-Host "  Step 1b: Rebuilding tools layer..." -ForegroundColor Gray
            Invoke-Wsl "docker build --network=host ${dockerBuildCacheArg}-t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
            Write-Host "  Tools image rebuilt: ${ImageName}:latest" -ForegroundColor Green
        } finally {
            Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        }

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

        $WslSourcePath = (Invoke-WslData "wslpath -u '$($SourcePath -replace '\\','/')'")
        if ($WslSourcePath -notmatch '^/') {
            $WslSourcePath = "$WslScriptRoot/$SourcePath"
        }
        $WslSourcePath = $WslSourcePath.Trim()

        Write-Host "  Step 1a: Packaging source as WSL transfer archive..." -ForegroundColor Gray
        $SourceArchive = New-WslTransferArchive -SourcePath $WslSourcePath -ArchiveName "$ImageName-source"
        Write-Host "  Source archive (WSL): $($SourceArchive.WslArchivePath)" -ForegroundColor Green

        Write-Host "  Step 1b: Expanding source archive in WSL..." -ForegroundColor Gray
        $WslBuildContext = Expand-WslTransferArchive -ArchivePath $SourceArchive.WslArchivePath -ContextName "$ImageName-source"
        Write-Host "  Build context (WSL): $($WslBuildContext.WslContextPath)" -ForegroundColor Green

        # Patch Dockerfile for local Docker compatibility:
        # - Strip '# syntax=docker/dockerfile:...' (avoids pulling BuildKit frontend image — fails when WSL DNS is flaky)
        # - Strip --mount=type=cache directives (not supported by classic Docker builder)
        Write-Host "  Step 1c: Patching Dockerfile for local Docker compatibility..." -ForegroundColor Gray
        Invoke-Wsl "sed -i '1s|^# syntax=docker/dockerfile:.*||' '$($WslBuildContext.WslContextPath)/Dockerfile'"
        Invoke-Wsl "sed -i 's|--mount=type=cache,[^ ]* ||g' '$($WslBuildContext.WslContextPath)/Dockerfile'"
        Write-Host "  Stripped syntax directive and --mount=type=cache" -ForegroundColor Green

        try {
            Write-Host "  Step 1d: Rebuilding base image from source..." -ForegroundColor Gray
            Invoke-Wsl "docker build --network=host ${dockerBuildCacheArg}-t ${ImageName}:base -f '$($WslBuildContext.WslContextPath)/Dockerfile' '$($WslBuildContext.WslContextPath)'"
            Write-Host "  Base image rebuilt: ${ImageName}:base" -ForegroundColor Green

            $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
            $WslToolsContext    = "$WslScriptRoot/images"

            Write-Host "  Step 1e: Rebuilding tools layer..." -ForegroundColor Gray
            Invoke-Wsl "docker build --network=host ${dockerBuildCacheArg}-t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
            Write-Host "  Tools image rebuilt: ${ImageName}:latest" -ForegroundColor Green
        } finally {
            try { Invoke-Wsl "rm -rf '$($SourceArchive.WslArchivePath)' '$($WslBuildContext.WslContextPath)'" } catch {}
        }
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
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:${GatewayPort}/healthz" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host "  Gateway is healthy (attempt $attempt/$maxAttempts)" -ForegroundColor Green
            $healthy = $true
            break
        }
    } catch {}

    # Fallback: trust container health status when host-side checks are blocked/delayed.
    try {
        $dockerHealth = (Invoke-WslData "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ContainerName 2>/dev/null").Trim()
        if ($dockerHealth -in @('healthy', 'none')) {
            Write-Host "  Gateway is healthy via Docker status (attempt $attempt/$maxAttempts, health=$dockerHealth)" -ForegroundColor Green
            $healthy = $true
            break
        }
    } catch {}

    if ($attempt -lt $maxAttempts) {
        Write-Host "  Not ready yet — retrying in 5s ($attempt/$maxAttempts)..." -ForegroundColor Gray
        Start-Sleep -Seconds 5
    }
}
if (-not $healthy) {
    $dockerState = "unknown"
    $dockerHealth = "unknown"
    try { $dockerState = (Invoke-WslData "docker inspect -f '{{.State.Status}}' $ContainerName 2>/dev/null").Trim() } catch {}
    try { $dockerHealth = (Invoke-WslData "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ContainerName 2>/dev/null").Trim() } catch {}
    Write-Warning "Gateway did not become healthy after $maxAttempts attempts (container state: $dockerState, health: $dockerHealth) — check logs: wsl docker logs $ContainerName"
}

# Run a non-fatal security audit with a short timeout to avoid update stalls.
if ($healthy) {
    try {
        $auditCommand = if ($Npm) { "openclaw security audit" } else { "node openclaw.mjs security audit" }
        $null = Invoke-NonFatalSecurityAudit -Command $auditCommand -ExecTimeoutSec 45
    } catch {
        Write-Warning "[Security audit] non-fatal error: $($_.Exception.Message)"
    }
} else {
    Write-Warning "[Security audit] skipped because gateway is not healthy yet"
}

# ---------------------------------------------------------------------------
# Step 3/3: Show status and recent logs
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/3: Post-update status ===" -ForegroundColor Cyan

$containerImage = (Invoke-WslData "docker inspect --format '{{.Config.Image}}' $ContainerName") -join ""
$containerImage = $containerImage.Trim()

Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Invoke-Wsl "docker logs --tail 30 $ContainerName 2>&1" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

Write-Host "`n=== Update complete ===" -ForegroundColor Green

$variantLabel = if ($Npm) { "npm" } else { "source" }
$refLabel = if (-not $Npm -and $ref) { " to: $ref" } else { "" }
Write-Host "  OpenClaw ($variantLabel) updated$refLabel — image: $containerImage" -ForegroundColor Green
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
Write-Host ""
Write-Host "=== Last step: save gateway token ===" -ForegroundColor Cyan
Write-Host ""
$tokenPadded = $existingToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow

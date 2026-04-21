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
    [string] $Cpu           = "4",
    [string] $Memory        = "8g",
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

function Test-WslDocker {
    try {
        $null = Invoke-Wsl "docker info > /dev/null 2>&1"
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

# Check WSL is available
$wslStatus = wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WSL is not available. Install WSL 2: wsl --install"
}
Write-Host "  WSL: OK" -ForegroundColor Green

# Check Docker inside WSL — auto-start if not running
if (-not (Test-WslDocker)) {
    Write-Host "  Docker not running — attempting to start..." -ForegroundColor Yellow
    wsl bash -c "sudo service docker start" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    if (-not (Test-WslDocker)) {
        throw "Docker is not running inside WSL and could not be started. Start Docker Engine or Docker Desktop with WSL 2 backend."
    }
    Write-Host "  Docker (WSL): started" -ForegroundColor Green
} else {
    Write-Host "  Docker (WSL): OK" -ForegroundColor Green
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
$WslDataDir = Invoke-Wsl "wslpath -u '$($DataDir -replace '\\','/')'"
$WslDataDir = ($WslDataDir -join "").Trim()
Write-Host "  Data dir (WSL): $WslDataDir" -ForegroundColor Green

# Convert script root and source path to WSL paths
$WslScriptRoot = (Invoke-Wsl "wslpath -u '$($PSScriptRoot -replace '\\','/')'") -join ""
$WslScriptRoot = $WslScriptRoot.Trim()

# ---------------------------------------------------------------------------
# Step 1: Build image
# ---------------------------------------------------------------------------
if ($Npm) {
    # ===== NPM variant: create inline Dockerfile and build locally =====
    Write-Host "`n=== Step 1/5: Creating Dockerfile (Debian Slim + npm) ===" -ForegroundColor Cyan

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

    $WslBuildDir = (Invoke-Wsl "wslpath -u '$($buildDir -replace '\\','/')'") -join ""
    $WslBuildDir = $WslBuildDir.Trim()

    Write-Host "`n=== Step 2/5: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    Write-Host "  Step 2a: Building base image..." -ForegroundColor Gray
    Invoke-Wsl "docker build -t ${ImageName}:base -f '$WslBuildDir/Dockerfile' '$WslBuildDir'"
    Write-Host "  Base image built: ${ImageName}:base" -ForegroundColor Green

    # Copy tools Dockerfile to WSL-accessible path
    $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
    $WslToolsContext    = "$WslScriptRoot/images"

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
    Invoke-Wsl "docker build -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
    Write-Host "  Tools image built: ${ImageName}:latest" -ForegroundColor Green

    # Clean up temp build dir
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

} else {
    # ===== Source-build variant: pull/checkout source and build locally =====
    Write-Host "`n=== Step 1/5: Cloning/updating OpenClaw source ===" -ForegroundColor Cyan

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

    Write-Host "`n=== Step 2/5: Building OpenClaw image locally via Docker ===" -ForegroundColor Cyan

    $WslSourcePath = (Invoke-Wsl "wslpath -u '$($SourcePath -replace '\\','/')'") -join ""
    # Handle relative paths — prepend script root if not already absolute
    if ($WslSourcePath -notmatch '^/') {
        $WslSourcePath = "$WslScriptRoot/$SourcePath"
    }
    $WslSourcePath = $WslSourcePath.Trim()

    Write-Host "  Step 2a: Building base OpenClaw image from source..." -ForegroundColor Gray
    Invoke-Wsl "docker build -t ${ImageName}:base -f '$WslSourcePath/Dockerfile' '$WslSourcePath'"
    Write-Host "  Base image built: ${ImageName}:base" -ForegroundColor Green

    $WslToolsDockerfile = "$WslScriptRoot/$ToolsDockerfile"
    $WslToolsContext    = "$WslScriptRoot/images"

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog)..." -ForegroundColor Gray
    Invoke-Wsl "docker build -t ${ImageName}:latest --build-arg BASE_IMAGE=${ImageName}:base -f '$WslToolsDockerfile' '$WslToolsContext'"
    Write-Host "  Tools image built: ${ImageName}:latest" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 3/5: Generate gateway token
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3/5: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "  Token generated (save this for Control UI access):" -ForegroundColor Gray
Write-Host "  $GatewayToken" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Step 4/5: Create docker-compose and start containers
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 4/5: Starting containers via docker-compose ===" -ForegroundColor Cyan

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
}

# Build the startup command
if ($Npm) {
    $startupCmd = @(
        "(openclaw config set gateway.controlUi.allowInsecureAuth true || true)",
        "(openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true)",
        "(openclaw config set browser.executablePath /usr/bin/chromium || true)",
        "npm config set prefix '~/.openclaw/npm-global'",
        "mkdir -p $HomeDir/.openclaw/workspace/memory",
        "mkdir -p $HomeDir/.cache/qmd/models",
        "mkdir -p `"`$GOPATH/bin`"",
        "export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache",
        "mkdir -p `$HOME/.openclaw/compile-cache",
        "export OPENCLAW_NO_RESPAWN=1",
        "openclaw gateway --allow-unconfigured --bind lan --port 18789"
    ) -join " && "
    $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/usr/local/lib/node_modules/openclaw/extensions"
} else {
    $startupCmd = @(
        "chmod -R 755 /app/extensions",
        "mkdir -p $HomeDir/.openclaw/workspace/memory",
        "export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache",
        "mkdir -p `$HOME/.openclaw/compile-cache",
        "export OPENCLAW_NO_RESPAWN=1",
        "(node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true)",
        "(node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true)",
        "node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789"
    ) -join " && "
    $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/app/extensions"
}

# Build the environment block for docker-compose
$envBlock = ($envVars | ForEach-Object { "      - $_" }) -join "`n"

$composeYaml = @"
services:
  openclaw:
    image: ${ImageName}:latest
    container_name: $ContainerName
    environment:
$envBlock
    volumes:
      - ${WslDataDir}:${HomeDir}/.openclaw
    ports:
      - "${GatewayPort}:18789"
      - "${BridgePort}:18790"
    init: true
    restart: unless-stopped
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
      start_period: 20s
    depends_on:
      redis:
        condition: service_started

  redis:
    image: redis:7-alpine
    container_name: ${ContainerName}-redis
    command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 5s
      retries: 3
"@

# Add Ollama sidecar only when -Ollama is specified (and no external host)
$ollamaEnabled = $Ollama -and (-not $OllamaHost)
if ($ollamaEnabled) {
    Write-Host "  Ollama sidecar: enabled" -ForegroundColor Green

    $composeYaml += @"

  ollama:
    image: ollama/ollama:latest
    container_name: ${ContainerName}-ollama
    volumes:
      - ollama-data:/root/.ollama
    ports:
      - "11434:11434"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:11434/"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s

volumes:
  ollama-data:
"@
    # Update env to point at the local Ollama service
    $composeYaml = $composeYaml -replace "(environment:`n(?:.*`n)*?)(    depends_on:)", "`$1      - OLLAMA_HOST=http://ollama:11434`n    depends_on:"
} elseif (-not $Ollama) {
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
    Write-Warning "Gateway did not become healthy after $maxAttempts attempts — check logs with: wsl docker logs $ContainerName"
}

# ---------------------------------------------------------------------------
# Step 5/5: Configure OpenClaw (non-interactive)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 5/5: Configuring OpenClaw ===" -ForegroundColor Cyan

function Invoke-DockerExec {
    param(
        [string] $Label,
        [string] $Command,
        [int]    $MaxRetries = 3,
        [int]    $DelaySec   = 10
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "  [$Label] attempt $i/$MaxRetries" -ForegroundColor Gray
        $output = Invoke-Wsl "docker exec $ContainerName bash -c '$Command' 2>&1"
        if ($LASTEXITCODE -eq 0) {
            if ($output) { Write-Host "    $output" -ForegroundColor DarkGray }
            return
        }
        if ($i -lt $MaxRetries) {
            Write-Host "  [$Label] exec failed — retrying in ${DelaySec}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySec
        }
    }
    Write-Warning "[$Label] failed after $MaxRetries attempts"
}

if ($Npm) {
    Invoke-DockerExec -Label "Onboard" `
        -Command "openclaw onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token \$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health"

    Invoke-DockerExec -Label "Model set" `
        -Command "openclaw models set github-copilot/claude-opus-4.6"

    Invoke-DockerExec -Label "Security audit" `
        -Command "openclaw security audit"
} else {
    Invoke-DockerExec -Label "Onboard" `
        -Command "node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token \$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health"

    Invoke-DockerExec -Label "Model set" `
        -Command "node openclaw.mjs models set github-copilot/claude-opus-4.6"

    Invoke-DockerExec -Label "Security audit" `
        -Command "node openclaw.mjs security audit"
}

# ---------------------------------------------------------------------------
# Step 6/6: Pull Ollama models (if Ollama sidecar is running)
# ---------------------------------------------------------------------------
if ($ollamaEnabled) {
    Write-Host "`n=== Step 6/6: Pulling Ollama models ===" -ForegroundColor Cyan

    # Wait for Ollama to become ready
    Write-Host "  Waiting for Ollama to become ready..."
    $ollamaReady = $false
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 3
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:11434/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200) {
                Write-Host "  Ollama is ready" -ForegroundColor Green
                $ollamaReady = $true
                break
            }
        } catch {}
        Write-Host "  Not ready yet — retrying ($i/20)..." -ForegroundColor Gray
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
} else {
    Write-Host "`n=== Step 6/6: Skipping Ollama model pull (no local Ollama) ===" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Done — print summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Deployment complete ===" -ForegroundColor Green

$variantLabel = if ($Npm) { "npm" } else { "source" }
Write-Host ""
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
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

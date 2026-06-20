# ---------------------------------------------------------------------------
# deploy-openclaw-ACA.ps1 — Build and deploy OpenClaw to an existing ACA environment
#
# Combines deploy-openclaw.ps1 (source build) and deploy-openclawnpm.ps1 (npm)
# into a single script controlled by the -Npm switch.
#
# Without -Npm: source-build variant (rg-openclaw, main.bicep, ca-openclaw, acropenclaw)
#   - Builds from the OpenClaw Git repo Dockerfile
#   - Three containers: OpenClaw gateway + Redis + CRW
#   - Home directory: /home/node
#
# With -Npm: npm-install variant (rg-openclawnpm, mainnpm.bicep, ca-openclawnpm, acropennpm)
#   - Builds a custom Dockerfile (node:22-slim + npm i -g openclaw)
#   - Three containers: OpenClaw gateway + Redis + CRW
#   - Home directory: /home/openclaw
#   - Includes Bun, Playwright/Chromium, QMD
#
# Prerequisites: infrastructure deployed via the corresponding Bicep template
#
# Usage:
#   .\deploy-openclaw-ACA.ps1                                  # source build
#   .\deploy-openclaw-ACA.ps1 -Tag v2026.2.15                  # source build, pinned tag
#   .\deploy-openclaw-ACA.ps1 -Npm                             # npm install
#   .\deploy-openclaw-ACA.ps1 -GroqApiKey gsk_...              # set the Groq API key secret
#   .\deploy-openclaw-ACA.ps1 -Cpu 3 -Memory 6Gi              # override OpenClaw container size
#
# Other parameters: -ResourceGroup, -DeploymentName, -AppName, -SourcePath
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $ResourceGroup = "rg-openclaw",
    [string] $DeploymentName = "main",
    [string] $AppName = "",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = "",
    [string] $Cpu = "",
    [string] $Memory = "",
    [string] $GroqApiKey = ""  # Groq API key — passed as a secret, never hardcoded
)

$ErrorActionPreference = "Stop"

# Azure Container Apps rejects secrets with empty values — use a placeholder
if (-not $GroqApiKey) { $GroqApiKey = "REPLACE_ME" }

# --- Set variant-specific defaults ---
if ($Npm) {
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup'))  { $ResourceGroup  = "rg-openclawnpm" }
    if (-not $PSBoundParameters.ContainsKey('DeploymentName')) { $DeploymentName = "mainnpm" }
    $BicepFile       = "mainnpm.bicep"
    $HomeDir         = "/home/openclaw"
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $BicepFile       = "main.bicep"
    $HomeDir         = "/home/node"
    $ToolsDockerfile = "images/Dockerfile.tools"
    Write-Host "`n*** Source-build variant selected ***" -ForegroundColor Magenta
}

# $HomeDir is interpolated unquoted into YAML shell commands and path values —
# whitespace or YAML-special characters would break both layers.
if ($HomeDir -match '\s' -or $HomeDir -match '["''`:#]') {
    throw "HomeDir '$HomeDir' contains whitespace or YAML-special characters; refuse to interpolate."
}

# --- Resource defaults (both variants use Consumption: 4 CPU / 8Gi max) ---
if (-not $Cpu)    { $Cpu    = "3.5" }
if (-not $Memory) { $Memory = "7Gi" }
# Sidecars: Redis (0.25 CPU / 0.5Gi) + CRW (0.25 CPU / 0.5Gi) — validate total <= 4 CPU / 8Gi
$redisCpu = 0.25; $redisMem = 0.5
$crwCpu = 0.25; $crwMem = 0.5
$totalCpu = [double]$Cpu + $redisCpu + $crwCpu
$totalMem = [double]($Memory -replace '[^0-9.]','') + $redisMem + $crwMem
if ($totalCpu -gt 4.0 -or $totalMem -gt 8.0) {
    throw "Total resources (CPU: $totalCpu, Memory: ${totalMem}Gi) exceed Consumption profile max (4 CPU / 8Gi). Reduce -Cpu/-Memory to account for Redis (0.25 CPU / 0.5Gi) + CRW (0.25 CPU / 0.5Gi) sidecars."
}

# --- Discover resource names from Bicep deployment outputs ---
Write-Host "`n=== Discovering resources from Bicep deployment ===" -ForegroundColor Cyan
$AcrName = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
if (-not $AppName) {
    $AppName = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
        --query "properties.outputs.appName.value" -o tsv 2>$null
}

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was $BicepFile deployed to '$ResourceGroup'?"
}
Write-Host "  ACR:  $AcrName" -ForegroundColor Green
Write-Host "  App:  $AppName" -ForegroundColor Green

$AcrServer = "$AcrName.azurecr.io"

# --- Build image ---
if ($Npm) {
    # ===== NPM variant: create inline Dockerfile and build =====
    Write-Host "`n=== Step 1/6: Creating Dockerfile (Debian Slim + npm) ===" -ForegroundColor Cyan

    $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-npm-build"
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

# Start gateway server — bind to loopback by default for security.
# Override CMD at deploy time to bind to LAN for container platforms.
CMD ["openclaw", "gateway", "--allow-unconfigured"]
"@

    $dockerfile | Set-Content (Join-Path $buildDir "Dockerfile") -Encoding utf8
    Write-Host "  Dockerfile created at $buildDir" -ForegroundColor Green

    Write-Host "`n=== Step 2/6: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
    Write-Host "This uploads the Dockerfile to Azure and builds remotely..."

    $env:PYTHONIOENCODING = "utf-8"

    Write-Host "  Step 2a: Building base OpenClaw image..." -ForegroundColor Gray
    az acr build `
        --registry $AcrName `
        --image openclaw:base `
        --file "$buildDir/Dockerfile" `
        $buildDir

    if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    Write-Host "  Base image pushed to $AcrServer/openclaw:base" -ForegroundColor Green

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
    az acr build `
        --registry $AcrName `
        --image openclaw:latest `
        --build-arg "BASE_IMAGE=$AcrServer/openclaw:base" `
        --file $ToolsDockerfile `
        images

    if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
    Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green

    # Clean up temp build dir
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

} else {
    # ===== Source-build variant: pull/checkout source and build =====
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
    Write-Host "This uploads source to Azure and builds remotely (~6 min)..."

    $env:PYTHONIOENCODING = "utf-8"

    # Export tracked files only into a clean temp context to avoid uploading untracked/modified files.
    $BuildContextDir = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-acr-context-" + [System.IO.Path]::GetRandomFileName())
    $ArchivePath = "$BuildContextDir.zip"
    New-Item -ItemType Directory -Path $BuildContextDir | Out-Null

    try {
        git -C $SourcePath archive --format=zip --output $ArchivePath HEAD
        if ($LASTEXITCODE -ne 0) { throw "Failed to export source archive for ACR build context" }

        Expand-Archive -Path $ArchivePath -DestinationPath $BuildContextDir -Force
        Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
        Write-Host "  Prepared clean ACR build context from tracked source files" -ForegroundColor Gray

        # Patch Dockerfile for ACR Tasks compatibility: strip BuildKit --mount directives
        # and suppress pnpm self-update checks that can stall headless builds.
        $AcrDockerfile = Join-Path $BuildContextDir "Dockerfile.acr"
        (Get-Content (Join-Path $BuildContextDir "Dockerfile") -Raw) `
            -replace '--mount=type=cache,\S+\s*', '' `
            -replace 'pnpm install --frozen-lockfile', 'PNPM_DISABLE_SELF_UPDATE_CHECK=1 pnpm install --frozen-lockfile' `
            -replace 'CI=true\s+pnpm prune --prod', 'CI=true PNPM_DISABLE_SELF_UPDATE_CHECK=1 PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
            -replace '(?m)^\s+\\\r?\n', '' |
            Set-Content $AcrDockerfile -Encoding utf8
        Write-Host "  Patched Dockerfile for ACR compatibility" -ForegroundColor Gray

        Write-Host "  Step 2a: Building base OpenClaw image (~6 min)..." -ForegroundColor Gray
        az acr build `
            --registry $AcrName `
            --image openclaw:base `
            --file $AcrDockerfile `
            $BuildContextDir

        if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
        Write-Host "  Base image pushed to $AcrServer/openclaw:base" -ForegroundColor Green
    }
    finally {
        Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item $BuildContextDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog)..." -ForegroundColor Gray
    az acr build `
        --registry $AcrName `
        --image openclaw:latest `
        --build-arg "BASE_IMAGE=$AcrServer/openclaw:base" `
        --file $ToolsDockerfile `
        images

    if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
    Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green
}

# --- Step 3/6: Generate gateway token ---
Write-Host "`n=== Step 3/6: Generating gateway token ===" -ForegroundColor Cyan
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
Write-Host "Token generated (save this for Control UI access):"
Write-Host "  $GatewayToken" -ForegroundColor Yellow

# --- Step 3.5/6: Import latest CRW image to ACR ---
Write-Host "`n=== Step 3.5/6: Importing latest CRW image to ACR ===" -ForegroundColor Cyan
try {
    Write-Host "  Importing ghcr.io/us/crw:latest -> $AcrServer/crw:latest" -ForegroundColor Gray
    az acr import `
        --name $AcrName `
        --source ghcr.io/us/crw:latest `
        --image crw:latest `
        --force
    Write-Host "  CRW image imported to ACR" -ForegroundColor Green
} catch {
    Write-Warning "  Failed to import CRW image to ACR — deployment will attempt to pull from ghcr.io directly"
}

# --- Step 4/6: Update Container App with OpenClaw ---
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

# Both variants use the built-in Consumption workload profile
$profileName = "Consumption"
Write-Host "Using built-in Consumption workload profile on environment $envName" -ForegroundColor Gray

# Pin to the OpenClaw storage link by name — the environment may also have
# an 'ollamastorage' link (added by ollama.bicep) and [0] is non-deterministic.
$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[?name=='openclawstorage'].name | [0]" -o tsv 2>$null
if (-not $StorageName) { throw "openclawstorage link not found on environment $envName. Was $BicepFile deployed?" }

$volumeName = "openclaw-state"

# Discover Ollama internal URL from the ca-ollama Container App in the same environment
$OllamaFqdn = az containerapp show --name ca-ollama --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
if ($OllamaFqdn) {
    $OllamaHost = "http://${OllamaFqdn}"
    Write-Host "  Ollama URL: $OllamaHost" -ForegroundColor Green
} else {
    Write-Host "  ca-ollama not found — OLLAMA_HOST will not be set" -ForegroundColor Yellow
    $OllamaHost = ""
}

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

if ($Npm) {
    # --- NPM variant YAML (with Redis sidecar) ---
    $updatedYaml = @"
properties:
  workloadProfileName: $profileName
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
    - name: groq-api-key
      value: $GroqApiKey
  template:
    containers:
    - name: $AppName
      image: $AcrServer/openclaw:latest
      command:
      - bash
      - -c
      - >-
        umask 077 &&
        (openclaw config set gateway.controlUi.allowInsecureAuth true || true) &&
        (openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        (openclaw config set browser.executablePath /usr/bin/chromium || true) &&
        npm config set prefix '~/.openclaw/npm-global' &&
        mkdir -p $HomeDir/.openclaw/workspace/memory &&
        mkdir -p $HomeDir/.cache/qmd/models &&
        mkdir -p "`$GOPATH/bin" &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true &&
        freqtrade trade --config /opt/freqtrade/config.json --db-url sqlite:///`$HOME/.openclaw/freqtrade.db &
        openclaw gateway --allow-unconfigured --bind lan --port 18789
      resources:
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: REDIS_HOST
        value: localhost
      - name: REDIS_PORT
        value: "6379"
      - name: CRW_HOST
        value: localhost
      - name: CRW_PORT
        value: "3000"
      - name: GROQ_API_KEY
        secretRef: groq-api-key
      - name: NODE_ENV
        value: production
      - name: HOME
        value: $HomeDir
      - name: TERM
        value: xterm-256color
      - name: OPENCLAW_BUNDLED_PLUGINS_DIR
        value: /usr/local/lib/node_modules/openclaw/extensions
      - name: OLLAMA_HOST
        value: "$OllamaHost"
      - name: OPENCLAW_DISABLE_BONJOUR
        value: "true"
      volumeMounts:
      - volumeName: $volumeName
        mountPath: $HomeDir/.openclaw
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
    - name: redis
      image: redis:7-alpine
      command:
      - redis-server
      - --save
      - ""
      - --appendonly
      - "no"
      resources:
        cpu: 0.25
        memory: 0.5Gi
      probes:
      - type: liveness
        tcpSocket:
          port: 6379
        periodSeconds: 30
    - name: crw
      image: ghcr.io/us/crw:latest
      resources:
        cpu: 0.25
        memory: 0.5Gi
      probes:
      - type: liveness
        tcpSocket:
          port: 3000
        periodSeconds: 30
    scale:
      # Single-instance gateway: local SQLite + in-memory OpenClaw state means
      # replicas cannot be scaled horizontally. Do not change without adopting
      # a shared-state model (external Redis, Postgres, etc.).
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@
} else {
    # --- Source-build variant YAML (with Redis sidecar) ---
    $updatedYaml = @"
properties:
  workloadProfileName: $profileName
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
    - name: groq-api-key
      value: $GroqApiKey
  template:
    containers:
    - name: $AppName
      image: $AcrServer/openclaw:latest
      command:
      - sh
      - -c
      - >-
        umask 077 &&
        chmod -R 755 /app/dist/extensions &&
        mkdir -p $HomeDir/.openclaw/workspace/memory &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) &&
        (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        (node openclaw.mjs config set gateway.auth.rateLimit.maxAttempts 10 || true) &&
        (node openclaw.mjs config set gateway.auth.rateLimit.windowMs 60000 || true) &&
        (node openclaw.mjs config set gateway.auth.rateLimit.lockoutMs 300000 || true) &&
        find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true &&
        freqtrade trade --config /opt/freqtrade/config.json --db-url sqlite:///`$HOME/.openclaw/freqtrade.db &
        node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
      resources:
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OPENCLAW_GATEWAY_TOKEN
        secretRef: gateway-token
      - name: REDIS_HOST
        value: localhost
      - name: REDIS_PORT
        value: "6379"
      - name: CRW_HOST
        value: localhost
      - name: CRW_PORT
        value: "3000"
      - name: GROQ_API_KEY
        secretRef: groq-api-key
      - name: NODE_ENV
        value: production
      - name: HOME
        value: $HomeDir
      - name: TERM
        value: xterm-256color
      - name: OPENCLAW_BUNDLED_PLUGINS_DIR
        value: /app/extensions
      - name: OLLAMA_HOST
        value: "$OllamaHost"
      - name: OPENCLAW_DISABLE_BONJOUR
        value: "true"
      volumeMounts:
      - volumeName: $volumeName
        mountPath: $HomeDir/.openclaw
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
    - name: redis
      image: redis:7-alpine
      command:
      - redis-server
      - --appendonly
      - "yes"
      resources:
        cpu: 0.25
        memory: 0.5Gi
      probes:
      - type: liveness
        tcpSocket:
          port: 6379
        periodSeconds: 30
    - name: crw
      image: ghcr.io/us/crw:latest
      resources:
        cpu: 0.25
        memory: 0.5Gi
      probes:
      - type: liveness
        tcpSocket:
          port: 3000
        periodSeconds: 30
    scale:
      # Single-instance gateway: local SQLite + in-memory OpenClaw state means
      # replicas cannot be scaled horizontally. Do not change without adopting
      # a shared-state model (external Redis, Postgres, etc.).
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@
}

$updatedYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

# Wait for the container to become ready
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

# --- Health check: verify OpenClaw gateway is responding ---
Write-Host "`nChecking OpenClaw health..." -ForegroundColor Cyan
$healthFqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
$healthUrl = "https://$healthFqdn"
$healthOk = $false
$healthMaxAttempts = 12
for ($h = 1; $h -le $healthMaxAttempts; $h++) {
    try {
        $resp = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
            Write-Host "  OpenClaw is healthy (HTTP $($resp.StatusCode)) — $healthUrl" -ForegroundColor Green
            $healthOk = $true
            break
        }
        Write-Host "  Unexpected status $($resp.StatusCode) — retrying in 10s ($h/$healthMaxAttempts)..." -ForegroundColor Yellow
    } catch {
        Write-Host "  Not responding yet — retrying in 10s ($h/$healthMaxAttempts)..." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 10
}
if (-not $healthOk) {
    Write-Warning "OpenClaw health check failed after $healthMaxAttempts attempts — proceeding anyway"
}

# --- Step 5/6: Configure OpenClaw (non-interactive) ---
Write-Host "`n=== Step 5/6: Configuring OpenClaw (non-interactive) ===" -ForegroundColor Cyan

# Retry helper — ACA exec can fail with ClusterExecFailure while the gateway
# process is still initialising inside the container.
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
      throw "[$Label] failed after $MaxRetries attempts (exit $LASTEXITCODE)"
}

if ($Npm) {
    # NPM variant uses bare 'openclaw' command
    Invoke-ContainerExec -Label "Onboard" `
        -Command "bash -c 'openclaw onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token \$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health'"

    Invoke-ContainerExec -Label "Model set" `
        -Command "openclaw models set github-copilot/claude-opus-4.6"

    Invoke-ContainerExec -Label "Security audit" `
        -Command "openclaw security audit"

    az containerapp exec --name $AppName --resource-group $ResourceGroup `
        --command "openclaw models auth login-github-copilot"
    if ($LASTEXITCODE -ne 0) { Write-Warning "GitHub Copilot auth failed (exit $LASTEXITCODE) — complete manually via 'az containerapp exec'" }
} else {
    # Source-build variant uses 'node openclaw.mjs'
    Invoke-ContainerExec -Label "Onboard" `
        -Command "bash -c 'node openclaw.mjs onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token \$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health'"

    Invoke-ContainerExec -Label "Model set" `
        -Command "node openclaw.mjs models set github-copilot/claude-opus-4.6"

    Invoke-ContainerExec -Label "Security audit" `
        -Command "node openclaw.mjs security audit"

    az containerapp exec --name $AppName --resource-group $ResourceGroup `
        --command "node openclaw.mjs models auth login-github-copilot"
    if ($LASTEXITCODE -ne 0) { Write-Warning "GitHub Copilot auth failed (exit $LASTEXITCODE) — complete manually via 'az containerapp exec'" }
}

# --- Step 6/6: Done ---
Write-Host "`n=== Step 6/6: Gateway configured ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

$variantLabel = if ($Npm) { "npm" } else { "source" }
Write-Host ""
$boxLabel  = "GATEWAY TOKEN: $GatewayToken"
$boxBorder = "─" * ($boxLabel.Length + 2)
Write-Host "  ┌$boxBorder┐" -ForegroundColor Yellow
Write-Host "  │ $boxLabel │" -ForegroundColor Yellow
Write-Host "  └$boxBorder┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "OpenClaw ($variantLabel) URL: https://$fqdn"
Write-Host "Control UI:   https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "=== Working with books (book-to-skill) ===" -ForegroundColor Cyan
Write-Host "  Copy PDF or EPUB files to OpenClaw for processing into skills:" -ForegroundColor Gray
Write-Host "  Use kubectl cp (for AKS) or mount via NFS share (for ACA/File Share)" -ForegroundColor Gray
Write-Host "  Files persist at: /home/node/.openclaw/book-to-skill/books/" -ForegroundColor Gray
Write-Host "  See README.md for detailed copy instructions" -ForegroundColor White
Write-Host ""
Write-Host "=== One manual step remaining: GitHub Copilot auth ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Connect to container:" -ForegroundColor Yellow
Write-Host "   az containerapp exec --name $AppName --resource-group $ResourceGroup"
Write-Host ""
Write-Host "2. Inside the container:" -ForegroundColor Yellow
$authCmd = if ($Npm) { "openclaw models auth login-github-copilot" } else { "node openclaw.mjs models auth login-github-copilot" }
Write-Host "   $authCmd" -ForegroundColor White
Write-Host "   (open browser, enter code, authorize, then type: exit)"
Write-Host ""
Write-Host "3. Open Control UI:" -ForegroundColor Yellow
Write-Host "   https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "=== Last step: save gateway token and URL ===" -ForegroundColor Cyan
Write-Host ""
$tokenPaddedLast = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPaddedLast │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Control UI: https://$fqdn/#token=$GatewayToken" -ForegroundColor White


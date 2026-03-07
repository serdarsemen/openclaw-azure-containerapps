# ---------------------------------------------------------------------------
# deploy-openclawfull.ps1 — Build and deploy OpenClaw to an existing ACA environment
#
# Combines deploy-openclaw.ps1 (source build) and deploy-openclawnpm.ps1 (npm)
# into a single script controlled by the -Npm switch.
#
# Without -Npm: source-build variant (rg-openclaw, main.bicep, ca-openclaw, acropenclaw)
#   - Builds from the OpenClaw Git repo Dockerfile
#   - Two containers: OpenClaw gateway + Ollama sidecar
#   - Home directory: /home/node
#
# With -Npm: npm-install variant (rg-openclawnpm, mainnpm.bicep, ca-openclawnpm, acropennpm)
#   - Builds a custom Dockerfile (node:22-slim + npm i -g openclaw)
#   - Three containers: OpenClaw gateway + Redis + Ollama
#   - Home directory: /home/openclaw
#   - Includes Bun, Playwright/Chromium, QMD
#
# Prerequisites: infrastructure deployed via the corresponding Bicep template
#
# Usage:
#   .\deploy-openclawfull.ps1                                  # source build
#   .\deploy-openclawfull.ps1 -Tag v2026.2.15                  # source build, pinned tag
#   .\deploy-openclawfull.ps1 -Npm                             # npm install
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $ResourceGroup = "rg-openclaw",
    [string] $DeploymentName = "main",
    [string] $AppName = "",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = "",
    [string] $Cpu = "",
    [string] $Memory = ""
)

$ErrorActionPreference = "Stop"

# --- Set variant-specific defaults ---
if ($Npm) {
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup'))  { $ResourceGroup  = "rg-openclawnpm" }
    if (-not $PSBoundParameters.ContainsKey('DeploymentName')) { $DeploymentName = "mainnpm" }
    $BicepFile       = "mainnpm.bicep"
    $HomeDir         = "/home/openclaw"
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    if (-not $Cpu)    { $Cpu    = "2.75" }
    if (-not $Memory) { $Memory = "5.5Gi" }
    # Redis sidecar: 0.25 CPU / 0.5Gi, Ollama sidecar: 1.0 CPU / 2Gi — validate total <= 4 CPU / 8Gi
    $redisCpu = 0.25; $redisMem = 0.5; $ollamaCpu = 1.0; $ollamaMem = 2.0
    $totalCpu = [double]$Cpu + $redisCpu + $ollamaCpu
    $totalMem = [double]($Memory -replace '[^0-9.]','') + $redisMem + $ollamaMem
    if ($totalCpu -gt 4.0 -or $totalMem -gt 8.0) {
        throw "Total resources (CPU: $totalCpu, Memory: ${totalMem}Gi) exceed Consumption tier max (4 CPU / 8Gi). Reduce -Cpu/-Memory to account for Redis (0.25 CPU / 0.5Gi) + Ollama (1.0 CPU / 2Gi) sidecars."
    }
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $BicepFile       = "main.bicep"
    $HomeDir         = "/home/node"
    $ToolsDockerfile = "images/Dockerfile.tools"
    if (-not $Cpu)    { $Cpu    = "3.0" }
    if (-not $Memory) { $Memory = "6Gi" }
    # Ollama sidecar uses 1.0 CPU / 2Gi; validate total stays within Consumption tier limits (4 CPU / 8Gi)
    $ollamaCpu = 1.0; $ollamaMem = 2.0
    $totalCpu = [double]$Cpu + $ollamaCpu
    $totalMem = [double]($Memory -replace '[^0-9.]','') + $ollamaMem
    if ($totalCpu -gt 4.0 -or $totalMem -gt 8.0) {
        throw "Total resources (CPU: $totalCpu, Memory: ${totalMem}Gi) exceed Consumption tier max (4 CPU / 8Gi). Reduce -Cpu/-Memory to account for Ollama sidecar (1.0 CPU / 2Gi)."
    }
    Write-Host "`n*** Source-build variant selected ***" -ForegroundColor Magenta
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
RUN npm i -g openclaw@$TAG && npm cache clean --force

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

    Write-Host "  Step 2a: Building base OpenClaw image (~6 min)..." -ForegroundColor Gray
    az acr build `
        --registry $AcrName `
        --image openclaw:base `
        --file "$SourcePath/Dockerfile" `
        $SourcePath

    if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
    Write-Host "  Base image pushed to $AcrServer/openclaw:base" -ForegroundColor Green

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

$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null
if (-not $StorageName) { throw "No NFS storage found on environment $envName. Was $BicepFile deployed?" }

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

if ($Npm) {
    # --- NPM variant YAML (with Redis + Ollama sidecars) ---
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
      - bash
      - -c
      - >-
        (openclaw config set gateway.controlUi.allowInsecureAuth true || true) &&
        (openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        (openclaw config set browser.executablePath /usr/bin/chromium || true) &&
        npm config set prefix '~/.openclaw/npm-global' &&
        mkdir -p /home/openclaw/.openclaw/workspace/memory &&
        mkdir -p /home/openclaw/.cache/qmd/models &&
        mkdir -p "`$GOPATH/bin" &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        exec openclaw gateway --allow-unconfigured --bind lan --port 18789
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
      - name: OLLAMA_HOST
        value: http://localhost:11434
      - name: NODE_ENV
        value: production
      - name: HOME
        value: /home/openclaw
      - name: TERM
        value: xterm-256color
      - name: OPENCLAW_BUNDLED_PLUGINS_DIR
        value: /usr/local/lib/node_modules/openclaw/extensions
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/openclaw/.openclaw
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
      - --dir
      - /data
      resources:
        cpu: 0.25
        memory: 0.5Gi
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /data
      probes:
      - type: liveness
        tcpSocket:
          port: 6379
        periodSeconds: 30
    - name: ollama
      image: ollama/ollama:latest
      resources:
        cpu: 1.0
        memory: 2Gi
      env:
      - name: OLLAMA_HOST
        value: 0.0.0.0:11434
      - name: OLLAMA_MODELS
        value: /home/ollama/.ollama/models
      - name: HOME
        value: /home/ollama
      probes:
      - type: liveness
        httpGet:
          path: /
          port: 11434
        periodSeconds: 30
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/ollama/.ollama
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $StorageName
"@
} else {
    # --- Source-build variant YAML (with Ollama sidecar) ---
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
        chmod -R 755 /app/extensions &&
        mkdir -p /home/node/.openclaw/workspace/memory &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) &&
        (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
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
      - name: OLLAMA_HOST
        value: http://localhost:11434
      - name: NODE_ENV
        value: production
      - name: HOME
        value: /home/node
      - name: TERM
        value: xterm-256color
      - name: OPENCLAW_BUNDLED_PLUGINS_DIR
        value: /app/extensions
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/node/.openclaw
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
    - name: ollama
      image: ollama/ollama:latest
      resources:
        cpu: 1.0
        memory: 2Gi
      env:
      - name: OLLAMA_HOST
        value: 0.0.0.0:11434
      - name: OLLAMA_MODELS
        value: /home/ollama/.ollama/models
      - name: HOME
        value: /home/ollama
      probes:
      - type: liveness
        httpGet:
          path: /
          port: 11434
        periodSeconds: 30
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /home/ollama/.ollama
    scale:
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
    Write-Warning "[$Label] failed after $MaxRetries attempts (exit $LASTEXITCODE)"
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
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "OpenClaw ($variantLabel) URL: https://$fqdn"
Write-Host "Control UI:   https://$fqdn/#token=$GatewayToken"
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

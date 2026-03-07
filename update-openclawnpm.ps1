# ---------------------------------------------------------------------------
# update-openclawnpm.ps1 — Update the OpenClaw (npm) image without regenerating tokens or config
#
# Prerequisites: OpenClaw already deployed via deploy-openclawnpm.ps1
# What this does:
#   1. Rebuilds the container image remotely via az acr build
#      (re-runs `npm i -g openclaw` to pull the latest published version)
#   2. Updates the Container App via a full YAML template (preserves existing
#      secrets, env vars, NFS volume, probes, sidecars, and startup commands)
#
# Existing gateway token, OpenClaw config, .md files, and auth state on
# the NFS volume (/home/openclaw/.openclaw) are preserved.
#
# Usage:
#   .\update-openclawnpm.ps1 -ResourceGroup rg-openclawnpm
# ---------------------------------------------------------------------------

param(
    [Parameter(Mandatory)] [string] $ResourceGroup
)

$ErrorActionPreference = "Stop"

# --- Discover resource names from Bicep deployment outputs ---
Write-Host "`n=== Discovering resources from Bicep deployment ===" -ForegroundColor Cyan
$AcrName = az deployment group show --resource-group $ResourceGroup --name mainnpm `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$AppName = az deployment group show --resource-group $ResourceGroup --name mainnpm `
    --query "properties.outputs.appName.value" -o tsv 2>$null

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was mainnpm.bicep deployed to '$ResourceGroup'?"
}
Write-Host "  ACR:  $AcrName" -ForegroundColor Green
Write-Host "  App:  $AppName" -ForegroundColor Green

# --- Step 1/3: Create Dockerfile and build image ---
Write-Host "`n=== Step 1/3: Creating Dockerfile (node:22-slim incl. npm) ===" -ForegroundColor Cyan

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
RUN npm i -g openclaw@latest && npm cache clean --force

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

Write-Host "`n=== Step 2/3: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
Write-Host "This uploads the Dockerfile to Azure and builds remotely..."

$env:PYTHONIOENCODING = "utf-8"

# Two-step build: base OpenClaw image, then layer with pre-baked tools
Write-Host "  Step 2a: Building base OpenClaw image..." -ForegroundColor Gray
az acr build `
    --registry $AcrName `
    --image openclaw:base `
    --file "$buildDir/Dockerfile" `
    $buildDir

if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
Write-Host "  Base image pushed to $AcrName.azurecr.io/openclaw:base" -ForegroundColor Green

$AcrServer = "$AcrName.azurecr.io"

Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --build-arg "BASE_IMAGE=$AcrServer/openclaw:base" `
    --file "images/Dockerfile.npmtools" `
    images

if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green

# Clean up temp build dir
Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Step 3/3: Update container app via YAML (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App via YAML ===" -ForegroundColor Cyan

# Discover existing environment, resources, and secrets from the running app
$appInfo = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "{envId:properties.managedEnvironmentId, cpu:properties.template.containers[0].resources.cpu, mem:properties.template.containers[0].resources.memory}" -o json 2>$null | ConvertFrom-Json
if (-not $appInfo -or -not $appInfo.envId) { throw "Failed to query Container App '$AppName'" }
$envId = $appInfo.envId
$envName = $envId.Split("/")[-1]
$currentCpu = if ($appInfo.cpu) { $appInfo.cpu } else { "4.0" }
$currentMem = if ($appInfo.mem) { $appInfo.mem } else { "8Gi" }

$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[0].name" -o tsv 2>$null
if (-not $StorageName) { throw "No NFS storage found on environment $envName" }

# Retrieve existing secrets so the YAML preserves them
$AcrCreds = az acr credential show --name $AcrName 2>$null | ConvertFrom-Json
if (-not $AcrCreds) { throw "Failed to get ACR credentials for $AcrName" }
$AcrUsername = $AcrCreds.username
$AcrPassword = $AcrCreds.passwords[0].value

$GatewayToken = az containerapp secret show --name $AppName --resource-group $ResourceGroup `
    --secret-name gateway-token --query "value" -o tsv 2>$null
if (-not $GatewayToken) { throw "Could not read existing gateway-token secret" }

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

$updateYaml = @"
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
        mkdir -p "`$GOPATH/bin" &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        exec openclaw gateway --allow-unconfigured --bind lan --port 18789
      resources:
        cpu: $currentCpu
        memory: $currentMem
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

$updateYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

Write-Host "Container App updated via YAML" -ForegroundColor Green

# Wait for the container to become ready
Write-Host "`nWaiting for container to become ready..."
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $latestRev = az containerapp show --name $AppName --resource-group $ResourceGroup `
        --query "properties.latestRevisionName" -o tsv 2>$null
    $running = az containerapp revision show --name $AppName --revision $latestRev --resource-group $ResourceGroup `
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

$rev = $latestRev
$img = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.template.containers[0].image" -o tsv 2>$null

# --- Post-update: Show recent container logs ---
Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Write-Host "  Current revision: $rev (image: $img)" -ForegroundColor Green
az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 60 2>$null

Write-Host "`n=== Update complete ===" -ForegroundColor Green
$fqdn = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv 2>$null

az containerapp revision list --name $AppName --resource-group $ResourceGroup -o table

Write-Host "  OpenClaw updated — image: $img" -ForegroundColor Green
Write-Host "  App restarted with new image, FQDN: $fqdn"
Write-Host ""
$tokenPadded = $GatewayToken.PadRight(61)
Write-Host "  ┌───────────────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
Write-Host "  │  GATEWAY TOKEN:                                                   │" -ForegroundColor Yellow
Write-Host "  │  $tokenPadded │" -ForegroundColor Yellow
Write-Host "  └───────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Control UI: https://$fqdn/#token=$GatewayToken"
Write-Host ""
Write-Host "Your gateway token, config, and data are unchanged." -ForegroundColor Green

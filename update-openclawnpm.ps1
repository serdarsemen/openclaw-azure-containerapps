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
Write-Host "`n=== Step 1/3: Creating Dockerfile (node:22-bookworm-slim  + npm) ===" -ForegroundColor Cyan

$buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-npm-build"
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory -Path $buildDir | Out-Null


#debian:bookworm-slim
# RUN openclaw onboard --install-daemon

$dockerfile = @"
FROM node:22-bookworm-slim 


# Prevent interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies, git, unzip, and Chromium runtime deps in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash curl ca-certificates gnupg \
  git unzip gh \
        libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
        libdrm2 libdbus-1-3 libxkbcommon0 libatspi2.0-0 \
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        libgbm1 libpango-1.0-0 libcairo2 libasound2 \
        libwayland-client0 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# (Optional) Make npm installs slightly quieter & consistent
ENV npm_config_fund=false npm_config_audit=false

# (optional) upgrade npm
RUN npm i -g npm@11.11.0


RUN node -v && npm -v


# Install OpenClaw globally via npm
RUN npm i -g openclaw



# Rename existing node user/group (UID/GID 1000) to openclaw
RUN groupmod -n openclaw node \
 && usermod -l openclaw -d /home/openclaw -m -s /bin/bash node

# Switch to non-root user
USER openclaw
WORKDIR /home/openclaw

# Install Bun (JavaScript runtime/bundler)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/openclaw/.bun/bin:`${PATH}"

# Install QMD via Bun
RUN bun install -g https://github.com/tobi/qmd

# Install Chromium via Playwright (headless browser)
RUN npx playwright install chromium

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

az acr build `
    --registry $AcrName `
    --image openclaw:latest `
    --file "$buildDir/Dockerfile" `
    $buildDir

if ($LASTEXITCODE -ne 0) { throw "Image build failed" }
Write-Host "Image built and pushed to $AcrName.azurecr.io/openclaw:latest" -ForegroundColor Green

# Clean up temp build dir
Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Step 3/3: Update container app via YAML (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App via YAML ===" -ForegroundColor Cyan

$AcrServer = "$AcrName.azurecr.io"

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
        mkdir -p /home/openclaw/.local/bin &&
        chmod -R 700 /home/openclaw/.openclaw &&
        (openclaw config set gateway.controlUi.allowInsecureAuth true || true) &&
        (openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        npm config set prefix '~/.local' &&
        export PATH="`$HOME/.local/bin:`$PATH" &&
        export PATH="/home/openclaw/.bun/bin:`$PATH" &&
        export NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache &&
        mkdir -p /var/tmp/openclaw-compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        mkdir /home/openclaw/.openclaw/workspace/memory -p  &&
        mkdir -p /home/openclaw/.openclaw/bin &&
        if [ ! -x /home/openclaw/.openclaw/bin/gh ]; then curl -fsSL https://github.com/cli/cli/releases/download/v2.72.0/gh_2.72.0_linux_amd64.tar.gz | tar -xz --strip-components=2 -C /home/openclaw/.openclaw/bin gh_2.72.0_linux_amd64/bin/gh; fi &&
        chmod +x /home/openclaw/.openclaw/bin/gh &&
        export PATH="/home/openclaw/.openclaw/bin:`$PATH" &&
        if [ ! -x `$HOME/.openclaw/go/bin/go ]; then curl -fsSL https://go.dev/dl/go1.24.1.linux-amd64.tar.gz | tar -xz -C `$HOME/.openclaw/; fi &&
        export GOROOT="`$HOME/.openclaw/go" && export GOPATH="`$HOME/.openclaw/gopath" && mkdir -p "`$GOPATH/bin" &&
        export PATH="`$GOROOT/bin:`$GOPATH/bin:`$PATH" &&
        if [ ! -f `$HOME/.openclaw/npm-global/bin/gemini ]; then NPM_CONFIG_PREFIX=`$HOME/.openclaw/npm-global npm install -g @google/gemini-cli@latest 2>/dev/null || true; fi &&
        export PATH="`$HOME/.openclaw/npm-global/bin:`$PATH" &&
        if [ ! -x "`$GOPATH/bin/gog" ]; then git clone https://github.com/steipete/gogcli.git /tmp/gogcli && cd /tmp/gogcli && go build -o "`$GOPATH/bin/gog" ./cmd/gog && cd - && rm -rf /tmp/gogcli; fi &&
        (openclaw doctor --fix || true) &&
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
    if ($running -eq "Running") {
        Write-Host "  Container is running (attempt $attempt/$maxAttempts)" -ForegroundColor Green
        break
    }
    Write-Host "  Not ready yet (state: $running) — retrying in 10s ($attempt/$maxAttempts)..."
    Start-Sleep -Seconds 10
}
if ($running -ne "Running") {
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

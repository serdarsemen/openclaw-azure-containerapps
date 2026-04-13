# ---------------------------------------------------------------------------
# update-openclawfull.ps1 — Update the OpenClaw image without regenerating tokens or config
#
# Combines update-openclaw.ps1 (source build) and update-openclawnpm.ps1 (npm)
# into a single script controlled by the -Npm switch.
#
# Without -Npm: source-build variant (rg-openclaw, main.bicep, ca-openclaw, acropenclaw)
# With    -Npm: npm-install variant  (rg-openclawnpm, mainnpm.bicep, ca-openclawnpm, acropennpm)
#
# Prerequisites: OpenClaw already deployed via the corresponding deploy script.
#
# Usage:
#   .\update-openclawfull.ps1                                  # source build
#   .\update-openclawfull.ps1 -Tag v2026.3.2                  # source build, pinned tag
#   .\update-openclawfull.ps1 -Npm                             # npm install
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $ResourceGroup = "rg-openclaw",
    [string] $DeploymentName = "main",
    [string] $AppName = "",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = ""
)

$ErrorActionPreference = "Stop"

# --- Set variant-specific defaults ---
if ($Npm) {
    if (-not $PSBoundParameters.ContainsKey('ResourceGroup'))  { $ResourceGroup  = "rg-openclawnpm" }
    if (-not $PSBoundParameters.ContainsKey('DeploymentName')) { $DeploymentName = "mainnpm" }
    $BicepFile       = "mainnpm.bicep"
    # $HomeDir         = "/home/openclaw"
    $ToolsDockerfile = "images/Dockerfile.npmtools"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $BicepFile       = "main.bicep"
    $HomeDir         = "/home/node"
    $ToolsDockerfile = "images/Dockerfile.tools"
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
    Write-Host "`n=== Step 1/3: Creating Dockerfile (node:22-slim incl. npm) ===" -ForegroundColor Cyan

    $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) "openclaw-npm-build"
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Path $buildDir | Out-Null

    $npmTag = if ($Tag) { $Tag } else { "latest" }
    $npmTagSafe = ($npmTag -replace '[^A-Za-z0-9_.-]', '-').ToLower()
    $baseImageTag = "openclaw:base-npm-$npmTagSafe"
    $baseTagName = "base-npm-$npmTagSafe"

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

    Write-Host "`n=== Step 2/3: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
    Write-Host "This uploads the Dockerfile to Azure and builds remotely..."

    $env:PYTHONIOENCODING = "utf-8"
    $step2Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $step2aStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $baseTagExists = az acr repository show-tags `
      --name $AcrName `
      --repository openclaw `
      --query "[?@=='$baseTagName'] | length(@)" -o tsv 2>$null
    $reuseBase = ($Tag -and $baseTagExists -eq "1")

    if ($reuseBase) {
      $step2aMode = "cache-hit (reused base image)"
      Write-Host "  Step 2a: Reusing existing base image $AcrServer/$baseImageTag" -ForegroundColor Gray
    } else {
      $step2aMode = "rebuilt base image"
      Write-Host "  Step 2a: Building base OpenClaw image as $baseImageTag..." -ForegroundColor Gray
      az acr build `
        --registry $AcrName `
        --image $baseImageTag `
        --file "$buildDir/Dockerfile" `
        $buildDir

      if ($LASTEXITCODE -ne 0) { throw "Base image build failed" }
      Write-Host "  Base image pushed to $AcrServer/$baseImageTag" -ForegroundColor Green
    }
    $step2aStopwatch.Stop()
    Write-Host ("  Step 2a result: {0} in {1:N1}s" -f $step2aMode, $step2aStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog, bun, qmd)..." -ForegroundColor Gray
    $step2bStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    az acr build `
        --registry $AcrName `
        --image openclaw:latest `
      --build-arg "BASE_IMAGE=$AcrServer/$baseImageTag" `
        --file $ToolsDockerfile `
        images

    if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
    $step2bStopwatch.Stop()
    $step2Stopwatch.Stop()
    Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green
    Write-Host ("  Step 2b duration: {0:N1}s" -f $step2bStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    Write-Host ("  Step 2 total duration: {0:N1}s" -f $step2Stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    # Clean up temp build dir
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

} else {
    # ===== Source-build variant: pull/checkout source and build =====
    Write-Host "`n=== Step 1/3: Updating OpenClaw source ===" -ForegroundColor Cyan

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

    $sourceCommit = git -C $SourcePath rev-parse --short=12 HEAD 2>$null
    if (-not $sourceCommit) { throw "Failed to read source commit from $SourcePath" }

    $baseImageTag = "openclaw:base-$sourceCommit"
    $baseTagName = "base-$sourceCommit"

    $ref = if ($Tag) { "$Tag ($sourceCommit)" } else { "latest (main @ $sourceCommit)" }
    Write-Host "  Source updated to: $ref" -ForegroundColor Green

    Write-Host "`n=== Step 2/3: Building OpenClaw image in ACR ===" -ForegroundColor Cyan
    Write-Host "This uploads source to Azure and builds remotely (~15 min)..."

    $env:PYTHONIOENCODING = "utf-8"
    $step2Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $step2aStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $baseTagExists = az acr repository show-tags `
      --name $AcrName `
      --repository openclaw `
      --query "[?@=='$baseTagName'] | length(@)" -o tsv 2>$null

    if ($baseTagExists -eq "1") {
      $step2aMode = "cache-hit (reused base image)"
      Write-Host "  Step 2a: Reusing existing base image $AcrServer/$baseImageTag" -ForegroundColor Gray
    } else {
      $step2aMode = "rebuilt base image"
      # Export tracked files only into a clean temp context to avoid slow local tar scanning.
      $BuildContextDir = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-acr-context-" + [System.IO.Path]::GetRandomFileName())
      $ArchivePath = "$BuildContextDir.zip"
      New-Item -ItemType Directory -Path $BuildContextDir | Out-Null

      try {
        git -C $SourcePath archive --format=zip --output $ArchivePath HEAD
        if ($LASTEXITCODE -ne 0) { throw "Failed to export source archive for ACR build context" }

        Expand-Archive -Path $ArchivePath -DestinationPath $BuildContextDir -Force
        Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
        Write-Host "  Prepared clean ACR build context from tracked source files" -ForegroundColor Gray

        # Patch Dockerfile for ACR Tasks compatibility: strip BuildKit --mount directives.
        $AcrDockerfile = Join-Path $BuildContextDir "Dockerfile.acr"
        (Get-Content (Join-Path $BuildContextDir "Dockerfile") -Raw) `
          -replace '--mount=type=cache,\S+\s*', '' `
          -replace 'pnpm install --frozen-lockfile', 'PNPM_DISABLE_SELF_UPDATE_CHECK=1 pnpm install --frozen-lockfile' `
          -replace 'CI=true\s+pnpm prune --prod', 'CI=true PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
          -replace 'CI=true PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod', 'CI=true PNPM_DISABLE_SELF_UPDATE_CHECK=1 PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
          -replace '(?m)^\s+\\\r?\n', '' |
          Set-Content $AcrDockerfile -Encoding utf8
        Write-Host "  Patched Dockerfile for ACR compatibility" -ForegroundColor Gray

        Write-Host "  Step 2a: Building base OpenClaw image as $baseImageTag (~15 min)..." -ForegroundColor Gray
        az acr build `
          --registry $AcrName `
          --image $baseImageTag `
          --file $AcrDockerfile `
          $BuildContextDir

        $buildExitCode = $LASTEXITCODE
        if ($buildExitCode -ne 0) { throw "Base image build failed" }
        Write-Host "  Base image pushed to $AcrServer/$baseImageTag" -ForegroundColor Green
      }
      finally {
        Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
        Remove-Item $BuildContextDir -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    $step2aStopwatch.Stop()
    Write-Host ("  Step 2a result: {0} in {1:N1}s" -f $step2aMode, $step2aStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    Write-Host "  Step 2b: Building tools layer (Go, gh, gemini, gog)..." -ForegroundColor Gray
    $step2bStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    az acr build `
        --registry $AcrName `
        --image openclaw:latest `
      --build-arg "BASE_IMAGE=$AcrServer/$baseImageTag" `
        --file $ToolsDockerfile `
        images

    if ($LASTEXITCODE -ne 0) { throw "Tools image build failed" }
    $step2bStopwatch.Stop()
    $step2Stopwatch.Stop()
    Write-Host "Image built and pushed to $AcrServer/openclaw:latest" -ForegroundColor Green
    Write-Host ("  Step 2b duration: {0:N1}s" -f $step2bStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    Write-Host ("  Step 2 total duration: {0:N1}s" -f $step2Stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}

# --- Step 3/3: Update container app via YAML (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App via YAML ===" -ForegroundColor Cyan

# Discover existing environment, resources, and secrets from the running app
$appInfo = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "{envId:properties.managedEnvironmentId, cpu:properties.template.containers[0].resources.cpu, mem:properties.template.containers[0].resources.memory}" -o json 2>$null | ConvertFrom-Json
if (-not $appInfo -or -not $appInfo.envId) { throw "Failed to query Container App '$AppName'" }
$envId = $appInfo.envId
$envName = $envId.Split("/")[-1]

# Ensure workload profile exists on the environment
if ($Npm) {
    $profileName = "Consumption"; $profileType = ""; $profileLabel = "Consumption"
} else {
  $profileName = "Consumption"; $profileType = ""; $profileLabel = "Consumption"
}
$existingProfiles = az containerapp env workload-profile list `
    --resource-group $ResourceGroup --name $envName `
    --query "[?name=='$profileName'].name" -o tsv 2>$null
if (-not $existingProfiles) {
  if ($profileName -eq "Consumption") {
    Write-Host "Using built-in Consumption workload profile on environment $envName" -ForegroundColor Gray
  } else {
    Write-Host "Adding $profileLabel workload profile to environment $envName..." -ForegroundColor Yellow
    az containerapp env workload-profile add `
      --resource-group $ResourceGroup --name $envName `
      --workload-profile-type $profileType --workload-profile-name $profileName `
      --min-nodes 1 --max-nodes 3
    if ($LASTEXITCODE -ne 0) { throw "Failed to add $profileLabel workload profile" }
    Write-Host "$profileLabel workload profile added" -ForegroundColor Green
  }
}

if ($Npm) {
    $maxCpu = 4.0; $maxMem = 8.0
} else {
    $maxCpu = 4.0; $maxMem = 8.0
}
if ($Npm) {
    # NPM: sidecars = Redis (0.25/0.5) + Ollama (2.25/5.5) = 2.5 CPU / 6.0Gi
    $sidecarCpu = 2.5; $sidecarMem = 6.0
} else {
    # Source-build: sidecars = Redis (0.25/0.5) + Ollama (2.25/5.5) = 2.5 CPU / 6.0Gi
    $sidecarCpu = 2.5; $sidecarMem = 6.0
}
$currentCpu = if ($appInfo.cpu) { [math]::Min([double]$appInfo.cpu, $maxCpu - $sidecarCpu) } else { $maxCpu - $sidecarCpu }
$currentMem = if ($appInfo.mem) {
    $memVal = [double]($appInfo.mem -replace '[^0-9.]','')
    "$([math]::Min($memVal, $maxMem - $sidecarMem))Gi"
} else { "$($maxMem - $sidecarMem)Gi" }

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

$GroqApiKey = az containerapp secret show --name $AppName --resource-group $ResourceGroup `
    --secret-name groq-api-key --query "value" -o tsv 2>$null
if (-not $GroqApiKey) { Write-Host "  Warning: groq-api-key secret not found — will be empty" -ForegroundColor Yellow; $GroqApiKey = "" }

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

if ($Npm) {
    # --- NPM variant YAML (with Redis + Ollama sidecars) ---
    $updateYaml = @"
properties:
  workloadProfileName: Consumption
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
      - name: GROQ_API_KEY
        secretRef: groq-api-key
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
      command:
      - /bin/sh
      - -c
      - "ollama serve & sleep 10 && ollama pull qwen2.5-coder:7b && ollama pull deepseek-r1:7b && ollama pull phi4-mini; wait"
      resources:
        cpu: 2.25
        memory: 5.5Gi
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
    $updateYaml = @"
properties:
  workloadProfileName: Consumption
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
        chmod -R 755 /app/extensions &&
        mkdir -p /home/node/.openclaw/workspace/memory &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) &&
        (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
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
      - name: GROQ_API_KEY
        secretRef: groq-api-key
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
      command:
      - /bin/sh
      - -c
      - "ollama serve & sleep 10 && ollama pull qwen2.5-coder:7b && ollama pull deepseek-r1:7b && ollama pull phi4-mini; wait"
      resources:
        cpu: 2.25
        memory: 5.5Gi
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

$variantLabel = if ($Npm) { "npm" } else { "source" }
$refLabel = if (-not $Npm -and $ref) { " to: $ref" } else { "" }
Write-Host "  OpenClaw ($variantLabel) updated$refLabel — image: $img" -ForegroundColor Green
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

# ---------------------------------------------------------------------------
# update-openclaw-ACA.ps1 — Update the OpenClaw image without regenerating tokens or config
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
#   .\update-openclaw-ACA.ps1                                  # source build
#   .\update-openclaw-ACA.ps1 -Tag v2026.3.2                  # source build, pinned tag
#   .\update-openclaw-ACA.ps1 -Npm                             # npm install
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $ResourceGroup = "rg-openclaw",
    [string] $DeploymentName = "main",
  [string] $AppName = "",
    [string] $SourcePath = "openclaw-repo",
    [string] $Tag = "",
    [int]    $KeepBaseImages = 3   # retain N newest openclaw:base-* tags; older ones are deleted
)

$ErrorActionPreference = "Stop"

# --- Helper: prune old base-* image tags to stay under ACR Basic (10 GiB) quota ---
function Invoke-AcrBaseImageSweep {
    param(
        [Parameter(Mandatory)][string] $Registry,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $KeepTagPrefix,
        [int] $Keep = 3
    )
    Write-Host "  Sweeping old '$KeepTagPrefix*' tags in $Registry/$Repository (keeping newest $Keep)..." -ForegroundColor Gray
    $tagsJson = az acr repository show-tags `
        --name $Registry `
        --repository $Repository `
        --orderby time_desc `
        --detail `
        --query "[?starts_with(name, '$KeepTagPrefix')].{name:name,created:createdTime}" `
        -o json 2>$null
    if (-not $tagsJson) { return }
    try { $tags = $tagsJson | ConvertFrom-Json } catch { return }
    if (-not $tags -or $tags.Count -le $Keep) { return }
    $toDelete = $tags | Select-Object -Skip $Keep
    foreach ($t in $toDelete) {
        Write-Host "    Deleting ${Repository}:$($t.name)" -ForegroundColor DarkGray
        az acr repository delete --name $Registry --image "${Repository}:$($t.name)" --yes 2>$null | Out-Null
    }
}

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

    Invoke-AcrBaseImageSweep -Registry $AcrName -Repository 'openclaw' -KeepTagPrefix 'base-npm-' -Keep $KeepBaseImages

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
          -replace 'CI=true\s+pnpm prune --prod', 'CI=true PNPM_DISABLE_SELF_UPDATE_CHECK=1 PNPM_CONFIG_FROZEN_LOCKFILE=false pnpm prune --prod' `
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

    Invoke-AcrBaseImageSweep -Registry $AcrName -Repository 'openclaw' -KeepTagPrefix 'base-' -Keep $KeepBaseImages
}

# --- Step 3/3: Update container app via YAML (creates a new revision automatically) ---
Write-Host "`n=== Step 3/3: Updating Container App via YAML ===" -ForegroundColor Cyan

# Discover existing environment, resources, and secrets from the running app
# Run 4 independent az CLI calls in parallel (saves ~10-15s vs sequential).
# Secrets are fetched with a single `secret list` call instead of one
# `secret show` per name \u2014 halves the secret round-trips.
# Start-ThreadJob runs in-process thread runspaces (~10x faster startup than
# Start-Job, which forks a new PowerShell.exe per job). Module ThreadJob is
# bundled with PowerShell 7+; fall back to Start-Job on Windows PowerShell 5.1.
Write-Host "  Running discovery queries in parallel..." -ForegroundColor Gray
$useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
$startJob = if ($useThreadJob) { Get-Command Start-ThreadJob } else { Get-Command Start-Job }

$jAppInfo  = & $startJob -ScriptBlock { param($a,$r) az containerapp show --name $a --resource-group $r --query "{envId:properties.managedEnvironmentId}" -o json 2>$null } -ArgumentList $AppName,$ResourceGroup
$jAcr      = & $startJob -ScriptBlock { param($n) az acr credential show --name $n 2>$null } -ArgumentList $AcrName
# NOTE: `az containerapp secret list` returns names only (no values). To read the
# actual secret value you MUST use `secret show --secret-name X --query value`.
$jGwToken  = & $startJob -ScriptBlock { param($a,$r) az containerapp secret show --name $a --resource-group $r --secret-name gateway-token --query "value" -o tsv 2>$null } -ArgumentList $AppName,$ResourceGroup
$jGroqKey  = & $startJob -ScriptBlock { param($a,$r) az containerapp secret show --name $a --resource-group $r --secret-name groq-api-key  --query "value" -o tsv 2>$null } -ArgumentList $AppName,$ResourceGroup
$jOllama   = & $startJob -ScriptBlock { param($r) az containerapp show --name ca-ollama --resource-group $r --query "properties.configuration.ingress.fqdn" -o tsv 2>$null } -ArgumentList $ResourceGroup

Wait-Job $jAppInfo,$jAcr,$jGwToken,$jGroqKey,$jOllama | Out-Null

# Surface job failures rather than silently swallowing them (Receive-Job would
# otherwise just return $null and downstream parsing would mask the cause).
$allJobs = @($jAppInfo,$jAcr,$jGwToken,$jGroqKey,$jOllama)
$failed  = $allJobs | Where-Object { $_.State -ne 'Completed' }
if ($failed) {
    $details = foreach ($j in $failed) {
        $reason = if ($j.ChildJobs -and $j.ChildJobs[0].JobStateInfo.Reason) { $j.ChildJobs[0].JobStateInfo.Reason.Message } else { $j.State }
        "    [$($j.Name)] $reason"
    }
    throw "Parallel discovery jobs failed:`n$($details -join "`n")"
}

$appInfoJson  = (Receive-Job $jAppInfo) -join "`n"
$acrCredsJson = (Receive-Job $jAcr) -join "`n"
$GatewayToken = ((Receive-Job $jGwToken) -join "").Trim()
$GroqApiKey   = ((Receive-Job $jGroqKey) -join "").Trim()
$OllamaFqdn   = ((Receive-Job $jOllama) -join "").Trim()
Remove-Job $jAppInfo,$jAcr,$jGwToken,$jGroqKey,$jOllama -Force

$appInfo = $appInfoJson | ConvertFrom-Json
if (-not $appInfo -or -not $appInfo.envId) { throw "Failed to query Container App '$AppName'" }
$envId = $appInfo.envId
$envName = $envId.Split("/")[-1]

$AcrCreds = $acrCredsJson | ConvertFrom-Json
if (-not $AcrCreds) { throw "Failed to get ACR credentials for $AcrName" }
$AcrUsername = $AcrCreds.username
$AcrPassword = $AcrCreds.passwords[0].value

if (-not $GatewayToken) { throw "Could not read existing gateway-token secret" }
if (-not $GroqApiKey) { Write-Host "  Warning: groq-api-key secret not found — will be empty" -ForegroundColor Yellow; $GroqApiKey = "" }

if ($OllamaFqdn) {
    $OllamaHost = "http://${OllamaFqdn}"
    Write-Host "  Ollama URL: $OllamaHost" -ForegroundColor Green
} else {
    Write-Host "  ca-ollama not found — OLLAMA_HOST will not be set" -ForegroundColor Yellow
    $OllamaHost = ""
}

# Both variants use the built-in Consumption workload profile
$profileName = "Consumption"
Write-Host "  Workload profile: Consumption on $envName" -ForegroundColor Gray

# Both variants use Consumption: 4 CPU / 8Gi max, sidecar = Redis (0.25/0.5)
$maxCpu = 4.0; $maxMem = 8.0
$sidecarCpu = 0.25; $sidecarMem = 0.5
$currentCpu = $maxCpu - $sidecarCpu
$currentMem = "$($maxMem - $sidecarMem)Gi"

# Storage depends on envName — runs after parallel block
# Pin to the OpenClaw storage link by name — the environment may also have
# an 'ollamastorage' link (added by ollama.bicep) and [0] is non-deterministic.
$StorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[?name=='openclawstorage'].name | [0]" -o tsv 2>$null
if (-not $StorageName) { throw "openclawstorage link not found on environment $envName" }

$volumeName = "openclaw-state"

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

if ($Npm) {
    # --- NPM variant YAML (with Redis sidecar) ---
    $updateYaml = @"
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
        freqtrade trade --config /opt/freqtrade/config.json --db-url sqlite:///`$HOME/.openclaw/freqtrade.db &
        openclaw gateway --allow-unconfigured --bind lan --port 18789
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
    $updateYaml = @"
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
        chmod -R 755 /app/extensions &&
        mkdir -p $HomeDir/.openclaw/workspace/memory &&
        export NODE_COMPILE_CACHE=`$HOME/.openclaw/compile-cache &&
        mkdir -p `$HOME/.openclaw/compile-cache &&
        export OPENCLAW_NO_RESPAWN=1 &&
        (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) &&
        (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) &&
        find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true &&
        find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true &&
        freqtrade trade --config /opt/freqtrade/config.json --db-url sqlite:///`$HOME/.openclaw/freqtrade.db &
        node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
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

$updateYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

Write-Host "Container App updated via YAML" -ForegroundColor Green

# Wait for the container to become ready (single az call per iteration)
Write-Host "`nWaiting for container to become ready..."
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $revTsv = az containerapp revision list --name $AppName --resource-group $ResourceGroup `
        --query "reverse(sort_by(@, &properties.createdTime))[0].[name,properties.runningState]" -o tsv 2>$null
    $parts = $revTsv -split "`t"
    $latestRev = $parts[0]
    $running = $parts[1]
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

$rev = $latestRev
# Single call for both image and FQDN
$postTsv = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "[properties.template.containers[0].image, properties.configuration.ingress.fqdn]" -o tsv 2>$null
$postParts = $postTsv -split "`t"
$img = $postParts[0]
$fqdn = $postParts[1]

# --- Post-update: Show recent container logs ---
Write-Host "`n=== Recent container logs ===" -ForegroundColor Cyan
Write-Host "  Current revision: $rev (image: $img)" -ForegroundColor Green
az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 60 2>$null

Write-Host "`n=== Update complete ===" -ForegroundColor Green

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


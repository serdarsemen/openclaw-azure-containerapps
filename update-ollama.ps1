# ---------------------------------------------------------------------------
# update-ollama.ps1 — Update the standalone Ollama Container App
#
# Updates ca-ollama to the latest ollama/ollama image or changes resources.
# Models are stored on an NFS volume (ollama-state) mounted at /root/.ollama,
# so they survive container restarts and updates — no re-pull needed.
#
# Usage:
#   .\update-ollama.ps1 -ResourceGroup rg-openclaw
#   .\update-ollama.ps1 -ResourceGroup rg-openclaw -Cpu 2 -Memory 4Gi
# ---------------------------------------------------------------------------

param(
    [string] $ResourceGroup = "rg-openclaw",
    [string] $Cpu = "",
    [string] $Memory = ""
)

$ErrorActionPreference = "Stop"

$AppName = "ca-ollama"

# --- Step 1/3: Discover existing app ---
Write-Host "`n=== Step 1/3: Discovering Ollama Container App ===" -ForegroundColor Cyan

$appInfo = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "{envId:properties.managedEnvironmentId}" -o json 2>$null | ConvertFrom-Json
if (-not $appInfo -or -not $appInfo.envId) { throw "Failed to query Container App '$AppName' in '$ResourceGroup'" }
$envId = $appInfo.envId

Write-Host "  App:         $AppName" -ForegroundColor Green
Write-Host "  Environment: $($envId.Split('/')[-1])" -ForegroundColor Green

# Discover NFS storage mount name from the environment
$envName = $envId.Split('/')[-1]
$OllamaStorageName = az containerapp env storage list `
    --name $envName --resource-group $ResourceGroup `
    --query "[?contains(name,'ollama')].name | [0]" -o tsv 2>$null
if (-not $OllamaStorageName) { throw "No Ollama NFS storage found on environment $envName" }
$volumeName = "ollama-state"
Write-Host "  NFS Storage: $OllamaStorageName (volume: $volumeName)" -ForegroundColor Green

# --- Determine resource allocation ---
# Consumption max: 4 CPU / 8Gi
if (-not $Cpu)    { $Cpu = "4" }
if (-not $Memory) { $Memory = "8Gi" }

$cpuVal = [double]$Cpu
$memVal = [double]($Memory -replace '[^0-9.]','')
if ($cpuVal -gt 4.0 -or $memVal -gt 8.0) {
    throw "Resources (CPU: $cpuVal, Memory: ${memVal}Gi) exceed Consumption profile max (4 CPU / 8Gi)."
}

# --- Step 2/3: Update via YAML ---
Write-Host "`n=== Step 2/3: Updating Ollama Container App ===" -ForegroundColor Cyan

$yamlPath = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")

$updateYaml = @"
properties:
  workloadProfileName: Consumption
  managedEnvironmentId: $envId
  configuration:
    ingress:
      external: false
      targetPort: 11434
      transport: http
  template:
    containers:
    - name: ollama
      image: ollama/ollama:latest
      resources:
        cpu: $Cpu
        memory: $Memory
      env:
      - name: OLLAMA_HOST
        value: "0.0.0.0:11434"
      volumeMounts:
      - volumeName: $volumeName
        mountPath: /root/.ollama
      probes:
      - type: startup
        httpGet:
          port: 11434
          path: /
        initialDelaySeconds: 5
        periodSeconds: 10
        failureThreshold: 30
      - type: liveness
        httpGet:
          port: 11434
          path: /
        periodSeconds: 30
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
    - name: $volumeName
      storageType: NfsAzureFile
      storageName: $OllamaStorageName
"@

$updateYaml | Set-Content $yamlPath -Encoding utf8

try {
    az containerapp update --name $AppName --resource-group $ResourceGroup --yaml $yamlPath
    if ($LASTEXITCODE -ne 0) { throw "Container App update failed" }
} finally {
    Remove-Item $yamlPath -ErrorAction SilentlyContinue
}

Write-Host "  Ollama Container App updated" -ForegroundColor Green

# --- Step 3/3: Wait and verify models ---
Write-Host "`n=== Step 3/3: Waiting for Ollama to start ===" -ForegroundColor Cyan
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $latestRev = az containerapp show --name $AppName --resource-group $ResourceGroup `
        --query "properties.latestRevisionName" -o tsv 2>$null
    $running = az containerapp revision show --name $AppName --revision $latestRev --resource-group $ResourceGroup `
        --query "properties.runningState" -o tsv 2>$null
    if ($running -in "Running", "RunningAtMaxScale") {
        Write-Host "  Ollama is running (attempt $attempt/$maxAttempts)" -ForegroundColor Green
        break
    }
    Write-Host "  Not ready yet (state: $running) — retrying in 10s ($attempt/$maxAttempts)..."
    Start-Sleep -Seconds 10
}
if ($running -notin "Running", "RunningAtMaxScale") {
    Write-Warning "Ollama did not reach Running state after $maxAttempts attempts"
}

Write-Host "`n  Models are persisted on NFS — checking availability..." -ForegroundColor Gray

$models = @(
    @{ name = "qwen2.5-coder:7b"; desc = "Best coding model at 7B — code generation, completion, refactoring" },
    @{ name = "deepseek-r1:8b";   desc = "Strong chain-of-thought reasoning" },
    @{ name = "qwen2.5:7b";       desc = "General-purpose — writing, analysis, summarisation" }
)

foreach ($model in $models) {
    $exists = az containerapp exec --name $AppName --resource-group $ResourceGroup `
        --command "ollama show $($model.name)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $($model.name) already present on NFS" -ForegroundColor Green
    } else {
        Write-Host "  Pulling $($model.name) ($($model.desc))..." -ForegroundColor Gray
        az containerapp exec --name $AppName --resource-group $ResourceGroup `
            --command "ollama pull $($model.name)"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to pull $($model.name) — pull later via: az containerapp exec --name $AppName -g $ResourceGroup --command 'ollama pull $($model.name)'"
        } else {
            Write-Host "  $($model.name) ready" -ForegroundColor Green
        }
    }
}

Write-Host "`n=== Ollama update complete ===" -ForegroundColor Green
Write-Host "  Models: $($models.name -join ', ')"

# Pre-load default model so it's ready for inference immediately
$defaultModel = "deepseek-r1:8b"
Write-Host "`n  Loading $defaultModel as default model..." -ForegroundColor Cyan
az containerapp exec --name $AppName --resource-group $ResourceGroup `
    --command "ollama run $defaultModel --keepalive 24h ''"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  Failed to pre-load $defaultModel — load manually via: az containerapp exec --name $AppName -g $ResourceGroup --command 'ollama run $defaultModel'"
} else {
    Write-Host "  $defaultModel loaded and kept alive (24h)" -ForegroundColor Green
}

Write-Host "`n=== Ollama update complete ===" -ForegroundColor Green

# ---------------------------------------------------------------------------
# deploy-ollama.ps1 — Deploy Ollama as a standalone Container App
#
# Deploys bicep/ollama.bicep infrastructure then starts the Ollama container.
# Must be run AFTER the main infrastructure (main.bicep or mainnpm.bicep)
# is deployed, since the Ollama app joins the existing cae-openclaw environment.
#
# After deployment, ca-openclaw reaches Ollama via internal DNS:
#   http://ca-ollama.internal.<env-default-domain>:11434
#
# Prerequisites:
#   - Resource group exists: az group create --name rg-openclaw --location swedencentral
#   - main.bicep (or mainnpm.bicep) already deployed to the resource group
#
# Usage:
#   .\deploy-ollama.ps1 -ResourceGroup rg-openclaw
#   .\deploy-ollama.ps1 -ResourceGroup rg-openclaw -Cpu 2 -Memory 4Gi
# ---------------------------------------------------------------------------

param(
    [string] $ResourceGroup = "rg-openclaw",
    [string] $DeploymentName = "ollama",
    [string] $Cpu = "4",
    [string] $Memory = "8Gi"
)

$ErrorActionPreference = "Stop"

# --- Validate Consumption limits ---
$cpuVal = [double]$Cpu
$memVal = [double]($Memory -replace '[^0-9.]','')
if ($cpuVal -gt 4.0 -or $memVal -gt 8.0) {
    throw "Resources (CPU: $cpuVal, Memory: ${memVal}Gi) exceed Consumption profile max (4 CPU / 8Gi)."
}

# --- Step 1/3: Deploy Bicep infrastructure ---
Write-Host "`n=== Step 1/3: Deploying Ollama infrastructure ===" -ForegroundColor Cyan

az deployment group create `
    --resource-group $ResourceGroup `
    --template-file bicep/ollama.bicep `
    --parameters bicep/ollama.bicepparam `
    --parameters ollamaCpu=$Cpu ollamaMemory=$Memory `
    --name $DeploymentName
if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed" }

# Discover outputs
$OllamaAppName = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.ollamaAppName.value" -o tsv 2>$null
$OllamaUrl = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.ollamaUrl.value" -o tsv 2>$null

if (-not $OllamaAppName) { throw "Could not read ollamaAppName from deployment outputs" }

Write-Host "  Ollama App: $OllamaAppName" -ForegroundColor Green
Write-Host "  Ollama URL: $OllamaUrl" -ForegroundColor Green

# --- Step 2/3: Wait for container to become ready ---
Write-Host "`n=== Step 2/3: Waiting for Ollama container ===" -ForegroundColor Cyan
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $latestRev = az containerapp show --name $OllamaAppName --resource-group $ResourceGroup `
        --query "properties.latestRevisionName" -o tsv 2>$null
    $running = az containerapp revision show --name $OllamaAppName --revision $latestRev --resource-group $ResourceGroup `
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

# --- Step 3/3: Pull models that fit within 8 GiB memory ---
# Each model is ~4.7-4.9 GB on disk. Ollama loads one at a time, so all three fit the 8 GiB budget.
$models = @(
    @{ name = "qwen2.5-coder:7b"; desc = "Best coding model at 7B — code generation, completion, refactoring" },
    @{ name = "deepseek-r1:8b";   desc = "Strong chain-of-thought reasoning" },
    @{ name = "qwen2.5:7b";       desc = "General-purpose — writing, analysis, summarisation" }
)

Write-Host "`n=== Step 3/3: Pulling $($models.Count) models ===" -ForegroundColor Cyan
foreach ($model in $models) {
    Write-Host "  Pulling $($model.name) ($($model.desc))..." -ForegroundColor Gray
    az containerapp exec --name $OllamaAppName --resource-group $ResourceGroup `
        --command "ollama pull $($model.name)"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Failed to pull $($model.name) — pull later via: az containerapp exec --name $OllamaAppName -g $ResourceGroup --command 'ollama pull $($model.name)'"
    } else {
        Write-Host "  $($model.name) ready" -ForegroundColor Green
    }
}

# --- Done ---
Write-Host "`n=== Ollama deployment complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  Ollama App:  $OllamaAppName"
Write-Host "  Internal URL: $OllamaUrl"
Write-Host "  Models:       $($models.name -join ', ')"
Write-Host ""
Write-Host "  Other Container Apps in the same environment can reach Ollama at:" -ForegroundColor Yellow
Write-Host "    OLLAMA_HOST=$OllamaUrl" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Pull additional models:" -ForegroundColor Gray
Write-Host "    az containerapp exec --name $OllamaAppName --resource-group $ResourceGroup --command 'ollama pull <model>'"

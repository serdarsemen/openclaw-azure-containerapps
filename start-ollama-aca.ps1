#!/usr/bin/env pwsh
<#
.SYNOPSIS
Deploy Ollama with qwen3.5 model to Azure Container Apps

.DESCRIPTION
Creates a Container App for Ollama in Azure and pulls the qwen3.5 model.
This enables CRW to access Ollama for LLM-powered extraction via Azure Container Apps.

.PARAMETER ResourceGroup
The Azure resource group (required)

.PARAMETER Environment
The Container Apps environment name (required)

.PARAMETER ContainerAppName
Name for the Ollama Container App (default: ollama)

.PARAMETER Model
Ollama model to pull (default: qwen3.5)

.PARAMETER Memory
Container memory in GB (default: 4, options: 2, 4, 8)

.PARAMETER Cpu
Container CPU in vCores (default: 2.0, options: 0.5-4.0)

.EXAMPLE
.\start-ollama-aca.ps1 -ResourceGroup my-rg -Environment my-env

.EXAMPLE
.\start-ollama-aca.ps1 -ResourceGroup my-rg -Environment my-env -Memory 8 -Cpu 4.0

.NOTES
Requires:
- Azure CLI (az) logged in to correct subscription
- Container Apps environment created
- Sufficient quota in resource group
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$Environment,

    [string]$ContainerAppName = "ollama",
    [string]$Model = "qwen3.5",
    [int]$Memory = 4,
    [double]$Cpu = 2.0
)

$ErrorActionPreference = "Stop"

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Ollama Azure Container Apps + Qwen3.5 Deployment Script    ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Step 1: Verify Azure CLI
Write-Host "`n[1/4] Verifying Azure CLI..." -ForegroundColor Cyan
try {
    $azVersion = az --version 2>&1 | Select-Object -First 1
    Write-Host "  Azure CLI: $azVersion" -ForegroundColor Green
} catch {
    Write-Host "  Error: Azure CLI is required" -ForegroundColor Red
    exit 1
}

# Step 2: Verify Container Apps environment
Write-Host "`n[2/4] Verifying Container Apps environment..." -ForegroundColor Cyan
try {
    $env = az containerapp env show --name $Environment --resource-group $ResourceGroup --query "id" 2>&1
    if (-not $env) {
        throw "Environment not found"
    }
    Write-Host "  Environment: $Environment" -ForegroundColor Green
    Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Green
} catch {
    Write-Host "  Error: Container Apps environment '$Environment' not found in '$ResourceGroup'" -ForegroundColor Red
    Write-Host "  Create environment first with: az containerapp env create ..." -ForegroundColor Yellow
    exit 1
}

# Step 3: Create Container App
Write-Host "`n[3/4] Creating Ollama Container App..." -ForegroundColor Cyan

# Validate resource limits
$validMemory = @(2, 4, 8)
if ($validMemory -notcontains $Memory) {
    Write-Host "  Warning: Memory must be 2, 4, or 8 GB. Using 4." -ForegroundColor Yellow
    $Memory = 4
}

if ($Cpu -lt 0.5 -or $Cpu -gt 4.0) {
    Write-Host "  Warning: CPU must be 0.5-4.0 vCores. Using 2.0." -ForegroundColor Yellow
    $Cpu = 2.0
}

Write-Host "  Creating app: $ContainerAppName" -ForegroundColor Gray
Write-Host "  Resources: $Cpu vCPU / $Memory GB RAM" -ForegroundColor Gray

try {
    az containerapp create `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --environment $Environment `
        --image ollama/ollama:latest `
        --cpu $Cpu `
        --memory "${Memory}Gi" `
        --ingress external `
        --target-port 11434 `
        --env-vars "OLLAMA_HOST=0.0.0.0:11434" `
        --transport tcp `
        --min-replicas 1 `
        --max-replicas 1 `
        2>&1 | Out-Null

    Write-Host "  Container App created successfully" -ForegroundColor Green
} catch {
    Write-Host "  Error creating Container App: $_" -ForegroundColor Red
    exit 1
}

# Get Container App URL
Write-Host "  Retrieving Container App URL..." -ForegroundColor Gray
$url = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv 2>&1
if ($url) {
    Write-Host "  URL: https://$url" -ForegroundColor Green
} else {
    Write-Host "  Warning: Could not retrieve URL" -ForegroundColor Yellow
}

# Step 4: Pull model using Container Exec
Write-Host "`n[4/4] Pulling $Model model..." -ForegroundColor Cyan
Write-Host "  Note: Model pulling happens inside the container" -ForegroundColor Gray
Write-Host "  Monitor progress with: az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup" -ForegroundColor Gray

try {
    # Get container ID
    $containerId = az containerapp exec `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --command "ollama pull $Model" 2>&1

    Write-Host "  Model pull initiated" -ForegroundColor Green
} catch {
    Write-Host "  Note: Model pull may be running asynchronously in the container" -ForegroundColor Yellow
}

# Verification
Write-Host "`n[Verification] Deployment Status..." -ForegroundColor Cyan
try {
    $status = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup --query "properties.provisioningState" -o tsv 2>&1
    Write-Host "  Provisioning State: $status" -ForegroundColor Green

    $replicas = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup --query "properties.runningStatus" -o tsv 2>&1
    Write-Host "  Running Status: $replicas" -ForegroundColor Green
} catch {
    Write-Host "  Could not retrieve status" -ForegroundColor Yellow
}

Write-Host "`n✅ Ollama Container App deployment initiated!" -ForegroundColor Green
Write-Host "   FQDN: $url" -ForegroundColor Green
Write-Host "   Port: 11434" -ForegroundColor Green
Write-Host "`n   Monitor container logs:" -ForegroundColor Gray
Write-Host "   az containerapp logs show --name $ContainerAppName --resource-group $ResourceGroup --follow" -ForegroundColor Gray
Write-Host "`n   CRW configuration:" -ForegroundColor Gray
Write-Host "   CRW_EXTRACTION__LLM__BASE_URL=https://$url/v1" -ForegroundColor Gray

Write-Host ""

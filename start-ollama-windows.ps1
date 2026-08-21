#!/usr/bin/env pwsh
<#
.SYNOPSIS
Start Ollama natively on Windows and pull qwen3.5 model

.DESCRIPTION
Starts the Ollama service natively on Windows (not in WSL), waits for it to be ready,
then pulls the qwen3.5 model. Useful for Azure Container Apps or GitHub Actions runners
running on Windows.

.EXAMPLE
.\start-ollama-windows.ps1

.EXAMPLE
.\start-ollama-windows.ps1 -UpgradeOllama

.NOTES
Requires:
- Ollama installed natively on Windows: https://ollama.ai/download/windows
- Network connectivity to pull model from ollama.ai registry
#>

param(
    [switch] $UpgradeOllama
)

$ErrorActionPreference = "Stop"

# Import helpers
$helperPath = Join-Path $PSScriptRoot "wsl-helpers.ps1"
if (-not (Test-Path $helperPath)) {
    Write-Host "Error: wsl-helpers.ps1 not found at $helperPath" -ForegroundColor Red
    exit 1
}
. $helperPath

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Ollama Windows + Qwen3.5 Model Startup Script            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Step 1: Start Ollama service on Windows
Write-Host "`n[1/3] Starting Ollama on Windows..." -ForegroundColor Cyan
$ollamaStarted = Start-OllamaWindows -Upgrade:$UpgradeOllama
if (-not $ollamaStarted) {
    Write-Host "Failed to start Ollama. Download from: https://ollama.ai/download/windows" -ForegroundColor Red
    exit 1
}

# Step 2: Wait for Ollama API to be ready
Write-Host "`n[2/3] Waiting for Ollama API to be ready..." -ForegroundColor Cyan
$maxWaitAttempts = 30
$ollamaReady = $false
for ($i = 0; $i -lt $maxWaitAttempts; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 2 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            Write-Host "  Ollama API is ready" -ForegroundColor Green
            $ollamaReady = $true
            break
        }
    } catch {
        # Expected during startup
    }
    if ($i -lt $maxWaitAttempts - 1) {
        Write-Host "  Waiting... ($([Math]::Min($i + 1, $maxWaitAttempts))/30)" -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
}

if (-not $ollamaReady) {
    Write-Host "Ollama API did not become ready within 30 seconds" -ForegroundColor Yellow
    Write-Host "Attempting model pull anyway..." -ForegroundColor Gray
}

# Step 3: Pull qwen3.5 model
Write-Host "`n[3/3] Pulling qwen3.5 model..." -ForegroundColor Cyan
try {
    Write-Host "  Sending pull request (this may take 2-10 minutes depending on model size)..." -ForegroundColor Gray

    # Use Ollama CLI directly
    $pullCmd = "ollama pull qwen3.5"

    & cmd /c $pullCmd 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Gray
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Model qwen3.5 pulled successfully" -ForegroundColor Green
    } else {
        Write-Host "  Warning: Model pull returned non-zero exit code" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Error pulling model: $_" -ForegroundColor Yellow
    exit 1
}

# Verify model is available
Write-Host "`n[Verification] Checking available models..." -ForegroundColor Cyan
try {
    $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 5 -ErrorAction Stop
    $models = $response.Content | ConvertFrom-Json

    if ($models.models) {
        Write-Host "  Available models:" -ForegroundColor Green
        $models.models | ForEach-Object {
            $size = if ($_.size) { " ($('{0:N2}' -f ($_.size / 1GB)) GB)" } else { "" }
            Write-Host "    • $($_.name)$size" -ForegroundColor Green
        }

        if ($models.models.name -contains "qwen3.5:latest" -or $models.models.name -match "qwen3\.5") {
            Write-Host "`n✅ Setup complete! Ollama is running with qwen3.5 model ready." -ForegroundColor Green
            Write-Host "   Access Ollama at: http://localhost:11434" -ForegroundColor Green
        } else {
            Write-Host "`n⚠️  Ollama is running but qwen3.5 may not be fully loaded yet." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No models found - pull may still be in progress" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Could not query models: $_" -ForegroundColor Yellow
    Write-Host "  Ollama may still be pulling - check manually with: ollama list" -ForegroundColor Gray
}

Write-Host ""

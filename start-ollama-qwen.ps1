#!/usr/bin/env pwsh
<#
.SYNOPSIS
Start Ollama in WSL and pull qwen3.5 model

.DESCRIPTION
Starts the Ollama service in WSL, waits for it to be ready, then pulls the qwen3.5 model.
Useful for setting up the LLM backend for CRW before deploying OpenClaw.

.EXAMPLE
.\start-ollama-qwen.ps1

.NOTES
Requires:
- Windows Subsystem for Linux (WSL 2)
- Ollama installed in WSL: wsl -- sudo apt-get install ollama
- Network connectivity to pull model from ollama.ai registry
#>

$ErrorActionPreference = "Stop"

# Import helpers
$helperPath = Join-Path $PSScriptRoot "wsl-helpers.ps1"
if (-not (Test-Path $helperPath)) {
    Write-Host "Error: wsl-helpers.ps1 not found at $helperPath" -ForegroundColor Red
    exit 1
}
. $helperPath

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          Ollama WSL + Qwen3.5 Model Startup Script             ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Step 1: Start Ollama service
Write-Host "`n[1/3] Starting Ollama in WSL..." -ForegroundColor Cyan
Write-Host "  Note: If Ollama is already running from a previous session, it will be killed and restarted." -ForegroundColor Gray
Write-Host "  This ensures it binds to 0.0.0.0:11434 instead of 127.0.0.1 (required for Docker containers)." -ForegroundColor Gray
$ollamaStarted = Start-OllamaWsl
if (-not $ollamaStarted) {
    Write-Host "`n❌ Auto-start failed. Try manual workaround:" -ForegroundColor Yellow
    Write-Host "  1. Open WSL terminal (or use: wsl)" -ForegroundColor Gray
    Write-Host "  2. Run this command:" -ForegroundColor Gray
    Write-Host "     OLLAMA_HOST=0.0.0.0:11434 ollama serve" -ForegroundColor Cyan
    Write-Host "  3. Rerun this script after Ollama is running" -ForegroundColor Gray
    Write-Host "`n  To verify Ollama is accessible, in another terminal run:" -ForegroundColor Gray
    Write-Host "     curl http://localhost:11434/api/tags" -ForegroundColor Cyan
    Write-Host "`nFailed to start Ollama. Check WSL installation and try: wsl -- sudo apt-get install ollama" -ForegroundColor Red
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

# Step 2b: Verify Docker can reach Ollama (critical for OpenClaw container)
Write-Host "`n[2b/3] Verifying Docker container connectivity..." -ForegroundColor Cyan
Write-Host "  Testing if Ollama is accessible from within a Docker container..." -ForegroundColor Gray
try {
    # Test using docker run to verify from container perspective
    $dockerTest = & docker run --rm --network host curlimages/curl:latest curl -sf --connect-timeout 2 "http://localhost:11434/api/tags" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Docker container CAN reach Ollama at http://host.docker.internal:11434" -ForegroundColor Green
    } else {
        Write-Host "  ✗ WARNING: Docker container CANNOT reach Ollama (bound to 127.0.0.1 only?)" -ForegroundColor Red
        Write-Host "    This will cause CRW to fail when deployed in Docker!" -ForegroundColor Red
        Write-Host "    Manual fix: In WSL terminal, run: OLLAMA_HOST=0.0.0.0:11434 ollama serve" -ForegroundColor Cyan
        Write-Host "    Then return here and re-run this script." -ForegroundColor Gray
        exit 1
    }
} catch {
    Write-Host "  Could not test Docker connectivity (Docker may not be running)" -ForegroundColor Yellow
    Write-Host "  Proceeding anyway, but verify manually: docker run --rm --network host curlimages/curl curl http://localhost:11434" -ForegroundColor Gray
}

# Step 3: Pull qwen3.5 model
Write-Host "`n[3/3] Pulling qwen3.5 model..." -ForegroundColor Cyan
try {
    Write-Host "  Sending pull request (this may take 2-10 minutes depending on model size)..." -ForegroundColor Gray

    # Use Ollama CLI directly in WSL for more reliable pulling
    $pullCmd = @"
ollama pull qwen3.5
"@

    wsl -- bash -c $pullCmd 2>&1 | ForEach-Object {
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
            Write-Host "   CRW will use:     http://host.docker.internal:11434/v1" -ForegroundColor Green
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

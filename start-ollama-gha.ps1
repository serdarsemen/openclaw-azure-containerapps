#!/usr/bin/env pwsh
<#
.SYNOPSIS
Start Ollama with qwen3.5 model for GitHub Actions or Codespaces

.DESCRIPTION
Starts Ollama service and pulls the qwen3.5 model for use in GitHub Actions workflows
or GitHub Codespaces environments. Works on both Linux (Codespaces/Actions runners)
and Windows runners.

.PARAMETER RunnerOS
Operating system context: Linux, Windows, or auto-detect (default: auto-detect)

.EXAMPLE
.\start-ollama-gha.ps1

.EXAMPLE
# In GitHub Actions workflow
- name: Start Ollama
  run: pwsh .\start-ollama-gha.ps1

.NOTES
Requires:
- PowerShell 7+ or PowerShell 5.1+
- bash (for Linux runners)
- curl or Invoke-WebRequest (for API interaction)
- Network connectivity to ollama.ai registry

For GitHub Actions:
- Runs on ubuntu-latest, windows-latest, macos-latest
- Model pull can take 5-15 minutes
- Adjust timeout in workflow if needed

For GitHub Codespaces:
- Ollama pre-installed, just run this script
- Model cache persists across sessions
#>

$ErrorActionPreference = "Stop"

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Ollama GitHub Actions/Codespaces + Qwen3.5 Startup Script     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Detect environment
Write-Host "`n[1/3] Detecting environment..." -ForegroundColor Cyan

$isLinux = $PSVersionTable.Platform -eq "Unix" -or $PSVersionTable.OS -like "*Linux*"
$isWindows = $PSVersionTable.Platform -eq "Win32NT" -or $env:OS -eq "Windows_NT"
$isMacOS = $PSVersionTable.Platform -eq "Unix" -and $PSVersionTable.OS -like "*Darwin*"

$env:PLATFORM = if ($isLinux) { "linux" } elseif ($isWindows) { "windows" } elseif ($isMacOS) { "macos" } else { "unknown" }

Write-Host "  Detected Platform: $($env:PLATFORM)" -ForegroundColor Green
Write-Host "  PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Green

# Environment detection
if ($env:GITHUB_ACTIONS) {
    Write-Host "  Environment: GitHub Actions (Runner)" -ForegroundColor Green
} elseif ($env:CODESPACES) {
    Write-Host "  Environment: GitHub Codespaces" -ForegroundColor Green
} else {
    Write-Host "  Environment: Local Development" -ForegroundColor Green
}

# Step 1: Start Ollama based on platform
Write-Host "`n[2/3] Starting Ollama..." -ForegroundColor Cyan

if ($env:PLATFORM -eq "linux") {
    Write-Host "  Starting on Linux..." -ForegroundColor Gray

    # Check if Ollama is installed
    $ollamaCheck = bash -c "which ollama" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Ollama not found. Installing..." -ForegroundColor Yellow
        try {
            bash -c "curl -fsSL https://ollama.ai/install.sh | sh" 2>&1 | Out-Null
        } catch {
            Write-Host "  Warning: Could not auto-install Ollama: $_" -ForegroundColor Yellow
            Write-Host "  Manual install: https://ollama.ai/download/linux" -ForegroundColor Gray
        }
    }

    # Start Ollama service
    Write-Host "  Starting Ollama service..." -ForegroundColor Gray
    bash -c "nohup ollama serve >/dev/null 2>&1 &" 2>&1 | Out-Null

} elseif ($env:PLATFORM -eq "windows") {
    Write-Host "  Starting on Windows..." -ForegroundColor Gray

    # Try to start Ollama from common installation paths
    $ollamaPaths = @(
        "$env:ProgramFiles\Ollama\ollama.exe",
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
        "C:\Users\$env:USERNAME\AppData\Local\Programs\Ollama\ollama.exe"
    )

    $ollamaExe = $null
    foreach ($path in $ollamaPaths) {
        if (Test-Path $path) {
            $ollamaExe = $path
            break
        }
    }

    if (-not $ollamaExe) {
        Write-Host "  Ollama not found in standard paths" -ForegroundColor Red
        Write-Host "  Download from: https://ollama.ai/download/windows" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "  Found Ollama at: $ollamaExe" -ForegroundColor Gray
    Write-Host "  Starting Ollama..." -ForegroundColor Gray

    # Start Ollama in background
    Start-Process $ollamaExe -WindowStyle Hidden -ErrorAction SilentlyContinue

} elseif ($env:PLATFORM -eq "macos") {
    Write-Host "  Starting on macOS..." -ForegroundColor Gray

    # Check if Ollama is installed
    $ollamaCheck = bash -c "which ollama" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Ollama not found" -ForegroundColor Red
        Write-Host "  Download from: https://ollama.ai/download/mac" -ForegroundColor Yellow
        exit 1
    }

    # Start Ollama service
    Write-Host "  Starting Ollama service..." -ForegroundColor Gray
    bash -c "nohup ollama serve >/dev/null 2>&1 &" 2>&1 | Out-Null

} else {
    Write-Host "  Unknown platform: $($env:PLATFORM)" -ForegroundColor Red
    exit 1
}

# Wait for Ollama API to be ready
Write-Host "  Waiting for Ollama API (up to 30 seconds)..." -ForegroundColor Gray
$maxAttempts = 30
$ollamaReady = $false

for ($i = 0; $i -lt $maxAttempts; $i++) {
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

    if ($i -lt $maxAttempts - 1) {
        Write-Host "    Attempt $($i + 1)/30..." -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
}

if (-not $ollamaReady) {
    Write-Host "  Ollama did not respond within 30 seconds" -ForegroundColor Yellow
}

# Step 2: Pull model
Write-Host "`n[3/3] Pulling qwen3.5 model..." -ForegroundColor Cyan
Write-Host "  This may take 5-15 minutes depending on network and disk speed" -ForegroundColor Gray

try {
    if ($env:PLATFORM -eq "linux" -or $env:PLATFORM -eq "macos") {
        bash -c "ollama pull qwen3.5" 2>&1 | ForEach-Object {
            if ($_ -match "pulling|downloading|verifying") {
                Write-Host "  $_" -ForegroundColor Gray
            }
        }
    } else {
        # Windows: use Ollama command
        & ollama pull qwen3.5 2>&1 | ForEach-Object {
            if ($_ -match "pulling|downloading|verifying") {
                Write-Host "  $_" -ForegroundColor Gray
            }
        }
    }

    Write-Host "  Model pull completed" -ForegroundColor Green
} catch {
    Write-Host "  Warning: Model pull encountered an error: $_" -ForegroundColor Yellow
}

# Verification
Write-Host "`n[Verification] Checking available models..." -ForegroundColor Cyan
try {
    $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 5 -ErrorAction Stop
    $models = $response.Content | ConvertFrom-Json

    if ($models.models) {
        Write-Host "  Available models:" -ForegroundColor Green
        foreach ($model in $models.models) {
            $size = if ($model.size) { " ($('{0:N2}' -f ($model.size / 1GB)) GB)" } else { "" }
            Write-Host "    • $($model.name)$size" -ForegroundColor Green
        }

        if ($models.models.name -match "qwen3\.5") {
            Write-Host "`n✅ Setup complete! Ollama is ready with qwen3.5 model." -ForegroundColor Green
        } else {
            Write-Host "`n⚠️  Ollama is running but qwen3.5 may not be loaded yet." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "  Could not query models: $_" -ForegroundColor Yellow
}

Write-Host "`n  Ollama API: http://localhost:11434" -ForegroundColor Green
Write-Host "  LLM Endpoint: http://localhost:11434/v1" -ForegroundColor Green

Write-Host ""

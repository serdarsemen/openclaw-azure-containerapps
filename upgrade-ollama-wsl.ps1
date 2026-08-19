#!/usr/bin/env pwsh
<#
.SYNOPSIS
Upgrade Ollama inside WSL using the official installer.

.DESCRIPTION
Reports the installed Ollama version, runs the official Ollama installer in WSL,
and verifies the installed version afterward. This script does not restart Ollama
or pull models.

.EXAMPLE
.\upgrade-ollama-wsl.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "`n=== Ollama WSL upgrade ===" -ForegroundColor Cyan

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw "WSL is not installed or wsl.exe is not available in PATH."
}

$beforeVersion = wsl -- bash -lc 'ollama --version 2>/dev/null || true' | Select-Object -First 1
if ($beforeVersion) {
    Write-Host "  Current: $beforeVersion" -ForegroundColor Gray
} else {
    Write-Host "  Current: Ollama is not installed; the installer will install it." -ForegroundColor Yellow
}

Write-Host "  Running the official Ollama installer in WSL..." -ForegroundColor Gray
wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
if ($LASTEXITCODE -ne 0) {
    throw "Ollama upgrade failed with exit code $LASTEXITCODE."
}

$afterVersion = wsl -- bash -lc 'ollama --version'
if ($LASTEXITCODE -ne 0 -or -not $afterVersion) {
    throw "Ollama was installed, but its version could not be verified in WSL."
}

$afterVersion = $afterVersion | Select-Object -First 1
Write-Host "  Updated: $afterVersion" -ForegroundColor Green
Write-Host "`n=== Ollama WSL upgrade complete ===" -ForegroundColor Green
Write-Host "  Run .\start-ollama-qwen.ps1 to restart Ollama with the repository's WSL network settings." -ForegroundColor Gray
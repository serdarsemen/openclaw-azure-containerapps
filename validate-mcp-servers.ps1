#
# MCP Server Validation Script (PowerShell)
# Comprehensive test suite for all MCP servers in the openclaw-azure-containerapps project
#
# Usage:
#   .\validate-mcp-servers.ps1
#   .\validate-mcp-servers.ps1 -Verbose
#   .\validate-mcp-servers.ps1 -FixSymlinks
#   .\validate-mcp-servers.ps1 -Verbose -FixSymlinks
#

param(
  [switch]$Verbose = $false,
  [switch]$FixSymlinks = $false
)

$ErrorActionPreference = "Stop"

# Initialize counters
$PassedChecks = 0
$FailedChecks = 0
$WarningChecks = 0

# Helper functions
function Write-Header {
  param([string]$Message)
  Write-Host ""
  Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Success {
  param([string]$Message)
  Write-Host "✅ $Message" -ForegroundColor Green
  $script:PassedChecks++
}

function Write-Failure {
  param([string]$Message)
  Write-Host "❌ $Message" -ForegroundColor Red
  $script:FailedChecks++
}

function Write-Warning {
  param([string]$Message)
  Write-Host "⚠️  $Message" -ForegroundColor Yellow
  $script:WarningChecks++
}

function Write-Info {
  param([string]$Message)
  Write-Host "ℹ️  $Message" -ForegroundColor Cyan
}

function Write-Verbose-Info {
  param([string]$Message)
  if ($Verbose) {
    Write-Host "   $Message" -ForegroundColor DarkGray
  }
}

# Check if command exists globally via npm
function Test-NpmPackage {
  param(
    [string]$PackageName,
    [string]$DisplayName = $PackageName
  )

  try {
    $output = npm list -g $PackageName 2>$null
    if ($LASTEXITCODE -eq 0) {
      # Extract version if possible
      $versionMatch = $output[0] -match '@[\d\.]+'
      $version = if ($versionMatch) { $Matches[0] } else { "unknown" }
      Write-Success "NPM package $DisplayName installed (version: $version)"
      Write-Verbose-Info "npm list -g $PackageName"
      return $true
    } else {
      Write-Failure "NPM package $DisplayName NOT installed"
      Write-Verbose-Info "npm list -g $PackageName"
      return $false
    }
  } catch {
    Write-Failure "Error checking NPM package $DisplayName : $_"
    return $false
  }
}

# Check if command exists in PATH
function Test-CommandExists {
  param([string]$CommandName)

  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
  if ($cmd) {
    Write-Success "Executable '$CommandName' found at $($cmd.Source)"
    Write-Verbose-Info "Get-Command $CommandName"

    # Try to get version
    try {
      $version = & $CommandName --version 2>&1 | Select-Object -First 1
      Write-Verbose-Info "$CommandName --version → $version"
    } catch { }

    return $true
  } else {
    Write-Failure "Executable '$CommandName' NOT found in PATH"
    Write-Verbose-Info "Get-Command $CommandName"
    return $false
  }
}

# Check if file/symlink exists
function Test-FilePath {
  param([string]$Path)

  if (Test-Path -Path $Path) {
    if ((Get-Item $Path).LinkType -eq "SymbolicLink") {
      $target = (Get-Item $Path).Target
      Write-Success "Symlink exists: $Path → $target"
    } else {
      Write-Success "File exists: $Path"
    }
    Write-Verbose-Info "Test-Path $Path"
    return $true
  } else {
    Write-Failure "Path does NOT exist: $Path"
    Write-Verbose-Info "Test-Path $Path"
    return $false
  }
}

# Check service connectivity
function Test-ServiceConnectivity {
  param(
    [string]$Url,
    [string]$ServiceName
  )

  try {
    $response = Invoke-WebRequest -Uri $Url -TimeoutSec 5 -ErrorAction Stop
    Write-Success "Service $ServiceName is reachable at $Url"
    Write-Verbose-Info "Invoke-WebRequest -Uri $Url"
    return $true
  } catch {
    Write-Warning "Service $ServiceName NOT reachable at $Url"
    Write-Verbose-Info "Error: $($_.Exception.Message)"
    return $false
  }
}

# Check if Docker container is running
function Test-DockerContainer {
  param([string]$ContainerName)

  try {
    $container = docker ps --format "{{.Names}}" 2>$null | Where-Object { $_ -eq $ContainerName }
    if ($container) {
      $inspect = docker inspect $ContainerName --format='{{.State.Status}}' 2>$null
      Write-Success "Docker container '$ContainerName' is running (status: $inspect)"
      Write-Verbose-Info "docker ps | grep $ContainerName"
      return $true
    } else {
      Write-Warning "Docker container '$ContainerName' is NOT running"
      Write-Verbose-Info "docker-compose -f docker-compose-wsl.yaml up -d"
      return $false
    }
  } catch {
    Write-Warning "Could not check Docker container status: $_"
    return $false
  }
}

# Create symlinks
function New-MpcSymlinks {
  $npmBin = Join-Path $HOME ".openclaw" "npm-global" "bin"
  $localBin = Join-Path $HOME ".local" "node_modules" ".bin"

  if (-not (Test-Path $localBin)) {
    New-Item -ItemType Directory -Path $localBin -Force | Out-Null
    Write-Success "Created directory: $localBin"
  }

  $commands = @("mslearn")

  foreach ($cmd in $commands) {
    $source = Join-Path $npmBin $cmd
    $target = Join-Path $localBin $cmd

    if (Test-Path $source) {
      if (Test-Path $target) {
        Remove-Item $target -Force
      }
      New-Item -ItemType SymbolicLink -Path $target -Target $source -Force | Out-Null
      Write-Success "Created symlink: $target → $source"
    } else {
      Write-Warning "Cannot symlink $cmd — executable not found at $source"
    }
  }
}

# Main validation flow
Write-Host ""
Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  MCP Server Validation (PowerShell)        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Header "1. Environment Setup"
Write-Info "User: $env:USERNAME"
Write-Info "Home: $HOME"
Write-Info "OS: $(if ($IsWindows) { 'Windows' } else { 'Unix' })"
Write-Info "PSVersion: $($PSVersionTable.PSVersion)"

try {
  $npmVersion = npm --version
  Write-Info "npm version: $npmVersion"
} catch {
  Write-Warning "npm not found in PATH"
}

Write-Header "2. NPM Packages"
Write-Info "Checking supported npm-based tooling..."
Test-NpmPackage "@microsoft/learn-cli" "microsoft/learn-cli" | Out-Null

Write-Header "3. Executables in PATH"
Write-Info "Checking if supported tooling is accessible..."
Test-CommandExists "mslearn" | Out-Null

Write-Header "4. Symlinks"
$localBinPath = Join-Path $HOME ".local" "node_modules" ".bin"
Write-Info "Checking symlinks in $localBinPath ..."
if (Test-Path $localBinPath) {
  Test-FilePath (Join-Path $localBinPath "mslearn") | Out-Null
} else {
  Write-Warning "Directory $localBinPath does not exist"
}

Write-Header "5. Service Connectivity"
Write-Info "Checking connectivity to service backends..."
Test-ServiceConnectivity "http://127.0.0.1:6379" "Redis" | Out-Null
Test-ServiceConnectivity "http://127.0.0.1:8080/healthz" "SearXNG" | Out-Null
Test-ServiceConnectivity "http://127.0.0.1:3000" "CRW" | Out-Null
Test-ServiceConnectivity "http://127.0.0.1:18789/healthz" "OpenClaw Gateway" | Out-Null

Write-Header "6. Docker Containers"
Write-Info "Checking if Docker containers are running..."
Test-DockerContainer "openclaw-redis" | Out-Null
Test-DockerContainer "searxng" | Out-Null
Test-DockerContainer "openclaw-crw" | Out-Null
Test-DockerContainer "openclaw" | Out-Null

if ($FixSymlinks) {
  Write-Header "7. Fixing Symlinks"
  New-MpcSymlinks
}

Write-Header "Summary"
Write-Host "Passed checks: " -NoNewline
Write-Host $PassedChecks -ForegroundColor Green
Write-Host "Warning checks: " -NoNewline
Write-Host $WarningChecks -ForegroundColor Yellow
Write-Host "Failed checks: " -NoNewline
Write-Host $FailedChecks -ForegroundColor Red

Write-Host ""
if ($FailedChecks -eq 0) {
  Write-Host "✅ Supported tooling and runtime services are properly configured!" -ForegroundColor Green
  exit 0
} else {
  Write-Host "❌ Some checks failed. Review output above and run with -Verbose for details." -ForegroundColor Red
  Write-Host ""
  Write-Host "Common fixes:" -ForegroundColor Yellow
  Write-Host "1. Install supported npm tooling:"
  Write-Host "   npm install -g @microsoft/learn-cli"
  Write-Host "2. Fix symlinks:"
  Write-Host "   .\validate-mcp-servers.ps1 -FixSymlinks"
  Write-Host "3. Start Docker containers:"
  Write-Host "   docker-compose -f docker-compose-wsl.yaml up -d"
  exit 1
}

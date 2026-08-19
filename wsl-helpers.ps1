# ---------------------------------------------------------------------------
# wsl-helpers.ps1 — Shared helpers for OpenClaw WSL deploy/update scripts
#
# Dot-source from deploy-openclaw-wsl.ps1 and update-openclaw-wsl.ps1:
#   . "$PSScriptRoot/wsl-helpers.ps1"
# ---------------------------------------------------------------------------

# Run a WSL command, merge stderr into the return value, throw on non-zero exit.
# Retries once automatically when a WSL service-level socket timeout is detected
# (Wsl/Service/0x8007274c) — these are always transient and never indicate a real failure.
function Invoke-Wsl {
    param([string] $Command, [int] $ServiceRetries = 2)
    $attempt = 0
    while ($true) {
        $attempt++
        $result = wsl bash -c $Command 2>&1
        if ($LASTEXITCODE -eq 0) { return $result }
        $output = ($result -join [Environment]::NewLine)
        if ($attempt -lt $ServiceRetries -and (Test-WslTransientNetworkError -Output $output)) {
            $delay = $attempt * 3
            Write-Host "  WSL service error on attempt $attempt — retrying in ${delay}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
            continue
        }
        throw "WSL command failed (exit $LASTEXITCODE): $Command`n$output"
    }
}

# Heuristic for transient network failures seen during Docker/BuildKit dependency
# downloads (npm registry timeouts, DNS hiccups, TLS/connect resets).
function Test-WslTransientNetworkError {
  param([string] $Output)
  if (-not $Output) { return $false }

  $patterns = @(
    'UND_ERR_CONNECT_TIMEOUT',
    'Connect Timeout Error',
    'fetch failed',
    'Temporary failure in name resolution',
    'i/o timeout',
    'TLS handshake timeout',
    'connection reset by peer',
    'network is unreachable',
    'context deadline exceeded',
    'lookup .*: no such host',
    'registry\.npmjs\.org',
    'registry-1\.docker\.io',
    # WSL service-level socket timeouts (Wsl/Service/0x8007274c et al.)
    'Wsl/Service/',
    'connected party did not properly respond',
    'connected host has failed to respond',
    '0x8007274c',
    '0x80072746'
  )

  foreach ($pattern in $patterns) {
    if ($Output -match $pattern) { return $true }
  }
  return $false
}

# Run a WSL command with retries when the failure looks network-transient.
function Invoke-WslRetry {
  param(
    [string] $Command,
    [int] $MaxAttempts = 3,
    [int] $InitialDelaySeconds = 5
  )

  $attempt = 1
  $delaySeconds = $InitialDelaySeconds
  $lastResult = ""
  $lastExitCode = 0

  while ($attempt -le $MaxAttempts) {
    $result = wsl bash -c $Command 2>&1
    $lastExitCode = $LASTEXITCODE

    if ($lastExitCode -eq 0) {
      return $result
    }

    $lastResult = ($result -join [Environment]::NewLine)
    $isTransient = Test-WslTransientNetworkError -Output $lastResult

    if (-not $isTransient -or $attempt -eq $MaxAttempts) {
      throw "WSL command failed (exit $lastExitCode): $Command`n$lastResult"
    }

    Write-Host "  Transient network failure detected (attempt $attempt/$MaxAttempts). Retrying in ${delaySeconds}s..." -ForegroundColor Yellow
    Start-Sleep -Seconds $delaySeconds
    $delaySeconds = [Math]::Min($delaySeconds * 2, 30)
    $attempt++
  }

  throw "WSL command failed (exit $lastExitCode): $Command`n$lastResult"
}

# Run a WSL command, discard stderr (use for value capture), throw on non-zero exit.
function Invoke-WslData {
    param([string] $Command)
    $result = wsl bash -c $Command 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command"
    }
    return $result
}

# Run a WSL command and stream its output live to the terminal (do not capture).
# Use for long-running commands like 'docker pull' where progress should be shown.
function Invoke-WslStream {
    param([string] $Command)
    wsl bash -c $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command"
    }
}

# Run a WSL command and recover once from Docker bridge subnet exhaustion by
# pruning unused networks and retrying. This targets the common compose error:
# "all predefined address pools have been fully subnetted".
function Invoke-WslWithNetworkPoolRecovery {
  param(
    [string] $Command,
    [string] $Context = "Docker command"
  )

  try {
    return Invoke-Wsl $Command
  } catch {
    $message = $_.Exception.Message
    if ($message -notmatch 'predefined address pools have been fully subnetted') {
      throw
    }

    Write-Host "  $Context failed due to exhausted Docker address pools." -ForegroundColor Yellow
    Write-Host "  Pruning unused Docker networks and retrying once..." -ForegroundColor Yellow
    Invoke-Wsl "docker network prune -f"

    return Invoke-Wsl $Command
  }
}

function Test-WslDocker {
    try {
        $null = Invoke-Wsl "docker info > /dev/null 2>&1"
        return $true
    } catch {
        return $false
    }
}

# Start Docker inside WSL if it's not already running. Uses sudo -n so an
# unconfigured sudoers file won't hang the script on a password prompt.
function Start-WslDocker {
    Write-Host "  Docker not running — attempting to start..." -ForegroundColor Yellow
    $startJob = Start-Job { wsl bash -c "sudo -n service docker start 2>/dev/null || service docker start 2>/dev/null" }
    $null = $startJob | Wait-Job -Timeout 10
    if ($startJob.State -eq 'Running') { $startJob | Stop-Job }
    $startJob | Remove-Job -Force

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        if (Test-WslDocker) { return $true }
        if ($attempt -lt 6) { Start-Sleep -Seconds 1 }
    }
    return $false
}

# Repair WSL2 DNS by writing public resolvers to /etc/resolv.conf.
# Uses sudo -n + Start-Job timeout to avoid hanging on a password prompt.
function Repair-WslDns {
    $dnsOk = $false
    try {
        $dnsResult = wsl bash -c "getent hosts registry.npmjs.org > /dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL" 2>$null
        if ($dnsResult -match "DNS_OK") { $dnsOk = $true }
    } catch {}

    if ($dnsOk) {
        Write-Host "  DNS: OK" -ForegroundColor Green
        return $true
    }

    Write-Host "  WSL DNS is broken — reconfiguring to use public resolvers (8.8.8.8, 1.1.1.1)..." -ForegroundColor Yellow

    # sudo -n + 10s timeout so we don't hang on a password prompt.
    $dnsScript = @'
sudo -n sh -c 'rm -f /etc/resolv.conf; printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf' 2>/dev/null
sudo -n sh -c 'grep -q generateResolvConf /etc/wsl.conf 2>/dev/null || printf "\n[network]\ngenerateResolvConf = false\n" >> /etc/wsl.conf' 2>/dev/null
'@

    $dnsJob = Start-Job -ScriptBlock { param($s) wsl bash -c $s } -ArgumentList $dnsScript
    $null = $dnsJob | Wait-Job -Timeout 10
    if ($dnsJob.State -eq 'Running') {
        $dnsJob | Stop-Job
        Write-Host "  WARNING: DNS reconfiguration timed out — sudo may require a password" -ForegroundColor Yellow
        Write-Host "  Fix: enable passwordless sudo for /etc/resolv.conf updates, or run 'wsl --shutdown' and retry" -ForegroundColor Yellow
        $dnsJob | Remove-Job -Force
        return $false
    }
    $dnsJob | Remove-Job -Force

    try {
        $dnsResult = wsl bash -c "getent hosts registry.npmjs.org > /dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL" 2>$null
        if ($dnsResult -match "DNS_OK") {
            Write-Host "  DNS fixed (using 8.8.8.8 / 1.1.1.1)" -ForegroundColor Green
            Write-Host "  NOTE: made a persistent change to /etc/resolv.conf and /etc/wsl.conf (generateResolvConf = false)." -ForegroundColor Gray
            return $true
        }
    } catch {}

    Write-Host "  WARNING: DNS still broken after reconfiguration — build may fail" -ForegroundColor Yellow
    Write-Host "  Try: wsl --shutdown, then re-run this script" -ForegroundColor Yellow
    return $false
}

function New-WslTransferArchive {
    param(
        [string] $SourcePath,
        [string] $ArchiveName
    )
    $wslTransferRoot = "/tmp/openclaw-transfer"
    $wslArchivePath = "$wslTransferRoot/$ArchiveName.tar"
    Invoke-Wsl "set -e; mkdir -p '$wslTransferRoot'; rm -f '$wslArchivePath'; git -C '$SourcePath' archive --format=tar --output '$wslArchivePath' HEAD"
    return [pscustomobject]@{ WslArchivePath = $wslArchivePath }
}

function Expand-WslTransferArchive {
    param(
        [string] $ArchivePath,
        [string] $ContextName
    )
    $wslContextRoot = "/tmp/openclaw-docker-context"
    $wslContextPath = "$wslContextRoot/$ContextName"
    Invoke-Wsl "set -e; mkdir -p '$wslContextRoot'; rm -rf '$wslContextPath'; mkdir -p '$wslContextPath'; tar -xf '$ArchivePath' -C '$wslContextPath'"
    return [pscustomobject]@{ WslContextPath = $wslContextPath }
}

# Patch a source Dockerfile for local (WSL) Docker builds. Strips the
# '# syntax=docker/dockerfile:...' directive (avoids pulling the BuildKit frontend
# image, which fails when WSL DNS is flaky) but KEEPS --mount=type=cache directives,
# since BuildKit is the default builder in Docker 23.0+ and cache mounts speed up
# rebuilds. Both deploy and update call this so source builds stay consistent.
function Update-LocalBuildDockerfile {
    param([Parameter(Mandatory)] [string] $WslDockerfilePath)
    Invoke-Wsl "sed -i '1s|^# syntax=docker/dockerfile:.*||' '$WslDockerfilePath'"
}

# Get the latest Ollama version from GitHub releases.
function Get-LatestOllamaVersion {
    try {
        Write-Host "  Fetching latest Ollama version from GitHub..." -ForegroundColor Gray
        $releases = Invoke-WebRequest -Uri "https://api.github.com/repos/ollama/ollama/releases/latest" -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($releases.StatusCode -eq 200) {
            $releaseData = $releases.Content | ConvertFrom-Json
            $latestTag = $releaseData.tag_name -replace '^v', ''
            Write-Host "  Latest Ollama version: $latestTag" -ForegroundColor Green
            return $latestTag
        }
    } catch {}
    Write-Host "  Could not fetch latest version from GitHub. Using installed version." -ForegroundColor Yellow
    return $null
}

  function Test-OllamaUpgradeRequired {
    param(
      [Parameter(Mandatory)] [string] $CurrentVersion,
      [Parameter(Mandatory)] [string] $LatestVersion,
      [switch] $Force
    )

    if ($Force) {
      return $true
    }

    try {
      return ([version]$LatestVersion -gt [version]$CurrentVersion)
    } catch {
      return $false
    }
  }

  # Upgrade Ollama inside WSL using the official installer script.
  # Returns $true when Ollama is already current or upgraded successfully.
  function Update-OllamaWsl {
    param(
      [switch] $Force,
      [string] $CurrentVersion = "",
      [string] $LatestVersion = ""
    )

    Write-Host "  Checking whether Ollama upgrade is needed in WSL..." -ForegroundColor Gray

    $ollamaPath = wsl -- bash -c "command -v ollama" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ollamaPath) {
      Write-Host "  Ollama not found in WSL. Install first: wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'" -ForegroundColor Yellow
      return $false
    }

    if (-not $CurrentVersion) {
      $currentVersionRaw = wsl -- bash -c "ollama --version 2>/dev/null | head -n1" 2>$null
      if ($currentVersionRaw -match '(\d+\.\d+\.\d+)') {
        $CurrentVersion = $Matches[1]
      }
    }

    if (-not $LatestVersion) {
      $LatestVersion = Get-LatestOllamaVersion
    }
    if (-not $Force -and $LatestVersion -and $CurrentVersion -and `
        -not (Test-OllamaUpgradeRequired -CurrentVersion $CurrentVersion -LatestVersion $LatestVersion)) {
      Write-Host "  Ollama in WSL is already up to date ($CurrentVersion)" -ForegroundColor Green
      return $true
    }

    Write-Host "  Upgrading Ollama in WSL via official installer..." -ForegroundColor Gray
    wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  Ollama upgrade failed in WSL" -ForegroundColor Yellow
      return $false
    }

    $newVersionRaw = wsl -- bash -c "ollama --version 2>/dev/null | head -n1" 2>$null
    $newVersion = ""
    if ($newVersionRaw -match '(\d+\.\d+\.\d+)') {
      $newVersion = $Matches[1]
    }

    if ($newVersion) {
      Write-Host "  Ollama upgraded in WSL: $CurrentVersion -> $newVersion" -ForegroundColor Green
    } else {
      Write-Host "  Ollama upgrade completed in WSL" -ForegroundColor Green
    }

    return $true
  }

# Auto-start Ollama on Windows by setting OLLAMA_HOST and starting the service.
function Start-OllamaWindows {
    try {
        Write-Host "  Attempting to auto-start Ollama on Windows..." -ForegroundColor Gray

        # Check if Ollama executable exists
        $ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $ollamaPath) {
            Write-Host "  Ollama not found in PATH. Install from https://ollama.ai" -ForegroundColor Yellow
            return $false
        }

        # Fetch and display latest version info
        Write-Host "  Checking Ollama version..." -ForegroundColor Gray
        $latestVersion = Get-LatestOllamaVersion
        try {
            $currentVersion = & ollama --version 2>$null | Select-Object -First 1
            Write-Host "    Current: $currentVersion" -ForegroundColor Gray
        } catch {}
        if ($latestVersion) {
            Write-Host "    Latest available: $latestVersion" -ForegroundColor Gray
            Write-Host "    Tip: Visit https://ollama.ai to update to the latest version" -ForegroundColor Gray
        }

        # Ensure the current process and user profile both prefer non-loopback
        # binding so WSL/Docker can reach Ollama over TCP.
        $env:OLLAMA_HOST = '0.0.0.0:11434'

        # Set OLLAMA_HOST to 0.0.0.0:11434 in user profile if not already set
        $currentHost = [System.Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')
        if ($currentHost -ne '0.0.0.0:11434') {
            Write-Host "    Setting OLLAMA_HOST=0.0.0.0:11434 in user environment..." -ForegroundColor Gray
            [System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0:11434', 'User')
        }

        # Try to start the Ollama service
        Write-Host "    Starting Ollama service..." -ForegroundColor Gray
        try {
            Start-Service -Name "Ollama" -ErrorAction SilentlyContinue
        } catch {}

        # Alternative: start ollama CLI if service doesn't exist
        if (-not (Get-Service -Name "Ollama" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })) {
            Write-Host "    Ollama service not available, trying CLI start..." -ForegroundColor Gray
          Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -Environment @{ OLLAMA_HOST = '0.0.0.0:11434' } -ErrorAction SilentlyContinue
        }

        # Wait for Ollama to become reachable
        Write-Host "    Waiting for Ollama to start (up to 15 seconds)..." -ForegroundColor Gray
        $maxAttempts = 15
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200) {
                  # Confirm listener is not loopback-only.
                  $listeners = Get-NetTCPConnection -State Listen -LocalPort 11434 -ErrorAction SilentlyContinue
                  $nonLoopbackListener = $listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') } | Select-Object -First 1
                  if ($nonLoopbackListener) {
                    Write-Host "    Ollama started successfully (listening on $($nonLoopbackListener.LocalAddress):11434)" -ForegroundColor Green
                    return $true
                  }

                  Write-Host "    Ollama responded on localhost but appears loopback-only." -ForegroundColor Yellow
                  Write-Host "    Ensure startup uses OLLAMA_HOST=0.0.0.0:11434 (current listener is not externally reachable)." -ForegroundColor Yellow
                  return $false
                }
            } catch {
                # Check for port already in use error
                if ($_.Exception.Message -match "bind.*address already in use" -or $_.Exception.Message -match "11434.*already in use") {
                    Write-Host "`n" -ForegroundColor Red
                    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
                    Write-Host "⚠️  OLLAMA IS RUNNING ON WINDOWS" -ForegroundColor Red
                    Write-Host "PORT 11434 IS ALREADY IN USE BY AN EXISTING OLLAMA INSTANCE" -ForegroundColor Red
                    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
                    Write-Host "Fix: Stop the existing Ollama process or use -OllamaWSL to run in WSL instead" -ForegroundColor Yellow
                    Write-Host "`n"
                    return $false
                }
            }
            Start-Sleep -Seconds 1
        }
        Write-Host "    Ollama not responding after 15 seconds. Manual start may be required." -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "    Error starting Ollama: $_" -ForegroundColor Yellow
        return $false
    }
}

# Auto-start Ollama in WSL by setting OLLAMA_HOST and starting the service.
function Start-OllamaWsl {
  param([switch] $Upgrade)

    $upgradeRequired = $false

    try {
        Write-Host "  Attempting to auto-start Ollama in WSL..." -ForegroundColor Gray

        # Check if Ollama is installed in WSL
        $ollamaCheck = wsl -- which ollama 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Host "  Ollama not found in WSL. Install with: wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'" -ForegroundColor Yellow
            return $false
        }

        # Check and display version info
        Write-Host "  Checking Ollama version in WSL..." -ForegroundColor Gray
        try {
            $currentVersionRaw = wsl -- bash -c "ollama --version" 2>$null
            if ($currentVersionRaw) {
              Write-Host "    Current: $currentVersionRaw" -ForegroundColor Gray
              if ($currentVersionRaw -match '(\d+\.\d+\.\d+)') {
                $currentVersion = $Matches[1]
              }
            }
        } catch {}
        $latestVersion = Get-LatestOllamaVersion
        if ($latestVersion) {
            Write-Host "    Latest available: $latestVersion" -ForegroundColor Gray
          Write-Host "    Tip: upgrade with -UpgradeOllama (or run: wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh')" -ForegroundColor Gray
        }

        $upgradeRequired = $Upgrade -or (
          $currentVersion -and
          $latestVersion -and
          (Test-OllamaUpgradeRequired -CurrentVersion $currentVersion -LatestVersion $latestVersion)
        )
        if ($upgradeRequired) {
          if ($Upgrade) {
            Write-Host "    Forced Ollama upgrade requested." -ForegroundColor Yellow
          } else {
            Write-Host "    Older Ollama version detected ($currentVersion -> $latestVersion). Upgrading..." -ForegroundColor Yellow
          }

          $upgradeSucceeded = Update-OllamaWsl `
            -Force:$Upgrade `
            -CurrentVersion $currentVersion `
            -LatestVersion $latestVersion
          if (-not $upgradeSucceeded) {
            throw "Required Ollama upgrade failed in WSL."
          }
        } elseif ($currentVersion -and $latestVersion) {
          Write-Host "    Ollama in WSL is already up to date ($currentVersion)." -ForegroundColor Green
        }

        # Kill any existing Ollama process to ensure fresh start with correct OLLAMA_HOST
        Write-Host "    Ensuring no existing Ollama process (may already be running from previous session)..." -ForegroundColor Gray
        $killCmd = 'pkill -f "ollama serve" || true; sleep 1'
        wsl -- bash -c $killCmd 2>&1 | Out-Null

        # Set OLLAMA_HOST in WSL environment and start service fresh
        Write-Host "    Setting OLLAMA_HOST=0.0.0.0:11434 and starting Ollama in WSL..." -ForegroundColor Gray
        $startCmd = 'export OLLAMA_HOST=0.0.0.0:11434; '
        $startCmd += 'if command -v systemctl &>/dev/null; then '
        $startCmd += '  sudo systemctl restart ollama; '
        $startCmd += 'else '
        $startCmd += '  nohup ollama serve >/dev/null 2>&1 &; '
        $startCmd += 'fi'

        $startOutput = wsl -- bash -c $startCmd 2>&1

        # Check for port already in use error
        if ($startOutput -match "bind.*address already in use" -or $startOutput -match "11434.*already in use") {
            Write-Host "`n" -ForegroundColor Red
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host "⚠️  OLLAMA IS RUNNING ON WINDOWS" -ForegroundColor Red
            Write-Host "STOP THE WINDOWS OLLAMA SERVICE TO RUN OLLAMA IN WSL" -ForegroundColor Red
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Red
            Write-Host "Port 11434 is already in use (likely from Windows Ollama instance)" -ForegroundColor Yellow
            Write-Host "Fix: Stop Windows Ollama, then try again" -ForegroundColor Yellow
            Write-Host "`n"
            return $false
        }

        # Wait for Ollama to become reachable from Docker containers (via 0.0.0.0 binding).
        # Require both HTTP responsiveness and a local listener in WSL to avoid
        # false positives when localhost is forwarded to Windows Ollama.
        Write-Host "    Waiting for Ollama to respond on 0.0.0.0:11434 (up to 20 seconds)..." -ForegroundColor Gray
        $maxAttempts = 20
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            try {
            $check = wsl -- bash -c "ss -ltn '( sport = :11434 )' 2>/dev/null | grep -q ':11434' && curl -sf --connect-timeout 2 'http://127.0.0.1:11434' >/dev/null 2>&1 && echo OK || echo FAIL" 2>$null
                if ($check -match "OK") {
                    Write-Host "    Ollama is accessible and bound to 0.0.0.0:11434" -ForegroundColor Green

                  $versionLine = wsl -- bash -c "ollama version 2>/dev/null | head -n1" 2>$null
                  if ($versionLine) {
                    Write-Host "    $versionLine" -ForegroundColor Gray
                    if ($versionLine -match 'Warning:\s*client version') {
                      Write-Host "    Client/server version mismatch detected in WSL Ollama." -ForegroundColor Yellow
                      Write-Host "    Run with -UpgradeOllama to upgrade both binaries, then retry." -ForegroundColor Yellow
                    }
                  }

                    return $true
                }
            } catch {}
            if ($i -lt $maxAttempts - 1) {
                Start-Sleep -Seconds 1
            }
        }
        Write-Host "    Ollama not responding after 15 seconds. Manual start may be required." -ForegroundColor Yellow
        return $false
    } catch {
      if ($upgradeRequired) {
        throw
      }
        Write-Host "    Error starting Ollama in WSL: $_" -ForegroundColor Yellow
        return $false
    }
}

# Return true when an Ollama endpoint is reachable from WSL.
# Accepts either a root URL (http://ip:11434) or full URL.
function Test-OllamaEndpointFromWsl {
  param(
    [Parameter(Mandatory)] [string] $Url,
    [int] $TimeoutSeconds = 2
  )

  try {
    $baseUrl = $Url.TrimEnd('/')
    $check = wsl -- bash -c "curl -sf --connect-timeout $TimeoutSeconds '${baseUrl}/api/tags' >/dev/null 2>&1 && echo OK || (curl -sf --connect-timeout $TimeoutSeconds '${baseUrl}' >/dev/null 2>&1 && echo OK || echo FAIL)" 2>$null
    return ($check -match "OK")
  } catch {
    return $false
  }
}

# Wait for an Ollama endpoint to become reachable from WSL.
function Wait-OllamaEndpointFromWsl {
  param(
    [Parameter(Mandatory)] [string] $Url,
    [int] $MaxAttempts = 10,
    [int] $DelaySeconds = 1
  )

  for ($i = 0; $i -lt $MaxAttempts; $i++) {
    if (Test-OllamaEndpointFromWsl -Url $Url) {
      return $true
    }
    if ($i -lt $MaxAttempts - 1) {
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  return $false
}

# Resolve -OllamaWindows / -OllamaWsl / -OllamaHost into a concrete URL and
# verify reachability. Returns @{ OllamaHost = '...'; Reachable = $bool }.
# Passes the resolved OllamaHost through unchanged when an explicit URL is given.
function Resolve-OllamaHost {
    param(
        [switch] $OllamaWindows,
        [switch] $OllamaWsl,
    [string] $OllamaHost = "",
    [switch] $UpgradeOllamaWsl
    )

    if (-not ($OllamaWindows -or $OllamaWsl -or $OllamaHost)) {
        return @{ OllamaHost = ""; Reachable = $false }
    }

    Write-Host "`n=== Resolving Ollama host ===" -ForegroundColor Cyan
    Write-Host "  Note: this script does not auto-install Ollama." -ForegroundColor Gray
    Write-Host "  Ollama runs only when explicitly requested via -Ollama / -OllamaWindows / -OllamaWsl / -OllamaHost." -ForegroundColor Gray

    $dockerOs = (Invoke-WslData "docker info --format '{{.OperatingSystem}}' 2>/dev/null").Trim()
    $isDockerDesktop = $dockerOs -match "Docker Desktop"
    if ($isDockerDesktop) {
        Write-Host "  Docker runtime: Docker Desktop (host.docker.internal -> Windows)" -ForegroundColor Gray
    } else {
        Write-Host "  Docker runtime: Docker Engine in WSL (host.docker.internal -> WSL)" -ForegroundColor Gray
    }

    if ($OllamaWindows) {
      $selectedHost = ""
        if ($isDockerDesktop) {
            $OllamaHost = "http://host.docker.internal:11434"
            Write-Host "  Routing via host.docker.internal (Docker Desktop -> Windows)" -ForegroundColor Green
        } else {
        $candidateIps = @()

        # Best signal for classic WSL2 NAT mode: vEthernet (WSL) adapter on Windows.
        try {
          $wslVnetIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "vEthernet (WSL)" -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' } |
            Select-Object -ExpandProperty IPAddress -First 1
          if ($wslVnetIp) { $candidateIps += $wslVnetIp }
        } catch {}

        # Mirrored networking can expose Windows via its LAN adapter IP.
        try {
          $activeWindowsIps = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            ForEach-Object { $_.IPv4Address.IPAddress } |
            Where-Object { $_ -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' }
          if ($activeWindowsIps) { $candidateIps += $activeWindowsIps }
        } catch {}

        # In mirrored networking, default route gateway can be the LAN router.
        # Keep it as a candidate but don't trust it until connectivity is verified.
        try {
          $routeGateway = (Invoke-WslData "ip route show default 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -n1").Trim()
          if ($routeGateway) { $candidateIps += $routeGateway }
        } catch {}

        # In NAT mode this often points to the Windows host side of the WSL vSwitch.
        try {
          $nsLine = (Invoke-WslData "grep -m1 nameserver /etc/resolv.conf").Trim()
          $nsIp = ($nsLine -split '\s+')[-1]
          if ($nsIp) { $candidateIps += $nsIp }
        } catch {}

        $candidateIps = $candidateIps |
          Where-Object { $_ -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' } |
          Select-Object -Unique

        if (-not $candidateIps -or $candidateIps.Count -eq 0) {
          throw "Could not determine a private Windows host IP from WSL. Use -OllamaHost http://<your-windows-ip>:11434 instead."
        }

        Write-Host "  Candidate Windows host IPs from WSL: $($candidateIps -join ', ')" -ForegroundColor Gray
        $fallbackIp = [string]($candidateIps | Select-Object -First 1)
        $OllamaHost = ('http://{0}:11434' -f $fallbackIp)
        }
        Write-Host "  Auto-starting Ollama on Windows..." -ForegroundColor Green
        $null = Start-OllamaWindows

      # With WSL Docker Engine, probe candidate IPs and pick the one that is
      # actually reachable from WSL. This avoids selecting a LAN router IP
      # in mirrored mode (for example 192.168.1.1).
      if (-not $isDockerDesktop) {
        foreach ($ip in $candidateIps) {
          $candidateUrl = "http://${ip}:11434"
          Write-Host "  Probing candidate from WSL: $candidateUrl" -ForegroundColor Gray
          if (Wait-OllamaEndpointFromWsl -Url $candidateUrl -MaxAttempts 3 -DelaySeconds 1) {
            $selectedHost = $candidateUrl
            break
          }
        }

        if ($selectedHost) {
          $OllamaHost = $selectedHost
          Write-Host "  Selected reachable Windows Ollama endpoint: $OllamaHost" -ForegroundColor Green
        } else {
          Write-Host "  No candidate responded from WSL yet; keeping fallback endpoint: $OllamaHost" -ForegroundColor Yellow
        }
      }

      # WSL mirrored networking forwards its localhost to Windows, but Docker
      # bridge containers do not inherit that forwarding. Use a compose-managed
      # host-network relay when no private Windows address was proven reachable.
      if ((-not $selectedHost) -and (Wait-OllamaEndpointFromWsl -Url "http://127.0.0.1:11434" -MaxAttempts 3 -DelaySeconds 1)) {
        $OllamaHost = "http://host.docker.internal:11435"
        Write-Host "  Windows Ollama is reachable through WSL localhost; enabling container relay on port 11435" -ForegroundColor Green
      }
    }

    if ($OllamaWsl) {
        if ($isDockerDesktop) {
            $wslIp = (Invoke-WslData "hostname -I | awk '{print `$1}'").Trim()
            if (-not $wslIp) {
                throw "Could not detect WSL IP. Use -OllamaHost http://<wsl-ip>:11434 instead."
            }
            $OllamaHost = "http://${wslIp}:11434"
            Write-Host "  WSL IP: $wslIp" -ForegroundColor Green
        } else {
            $OllamaHost = "http://host.docker.internal:11434"
            Write-Host "  Using host.docker.internal for WSL Ollama" -ForegroundColor Green
        }
        Write-Host "  Auto-starting Ollama in WSL..." -ForegroundColor Green
        $null = Start-OllamaWsl -Upgrade:$UpgradeOllamaWsl
    }

    Write-Host "  Verifying Ollama connectivity at $OllamaHost ..." -ForegroundColor Gray
    $ollamaReachable = $false
    try {
        if ($OllamaHost -match 'host\.docker\.internal') {
            if ($OllamaWindows -and $isDockerDesktop) {
                $resp = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200) { $ollamaReachable = $true }
            } else {
          $ollamaReachable = Wait-OllamaEndpointFromWsl -Url "http://localhost:11434" -MaxAttempts 5 -DelaySeconds 1
            }
        } else {
        $ollamaReachable = Wait-OllamaEndpointFromWsl -Url $OllamaHost -MaxAttempts 5 -DelaySeconds 1
        }
    } catch {}

    if ($ollamaReachable) {
      Write-Host "  Ollama connectivity verified" -ForegroundColor Green
      if ((-not $OllamaWindows) -and (-not $OllamaWsl) -and $OllamaHost) {
        Write-Host "  External endpoint reachable; no resolver rewrite applied." -ForegroundColor Green
      }
    } else {
        $sourceLabel = if ($OllamaWindows) { "Windows" } elseif ($OllamaWsl) { "WSL" } else { "the external host" }
        Write-Warning "Ollama not reachable at $OllamaHost"
        Write-Host "  Auto-start was attempted. If Ollama did not start, please check:" -ForegroundColor Yellow
        Write-Host "    - Ollama is installed on $sourceLabel" -ForegroundColor Yellow
        Write-Host "    - OLLAMA_HOST is set to 0.0.0.0:11434 (not 127.0.0.1)" -ForegroundColor Yellow
        Write-Host "    - Ollama service/process has sufficient permissions" -ForegroundColor Yellow
        Write-Host "  Continuing deployment — Ollama features will be unavailable until connectivity is restored." -ForegroundColor Yellow
    }
    Write-Host "  OLLAMA_HOST=$OllamaHost" -ForegroundColor Green

    return @{ OllamaHost = $OllamaHost; Reachable = $ollamaReachable }
}

# Return the terminal summary lines for the selected Ollama mode.
function Get-OllamaSummaryLines {
  param(
    [switch] $OllamaSidecar,
    [switch] $OllamaWindows,
    [switch] $OllamaWsl,
    [string] $OllamaHost = ""
  )

  if ($OllamaSidecar) {
    return "  Ollama:     http://localhost:11434 (Docker sidecar)"
  }

  if ($OllamaWindows -and $OllamaHost) {
    return @(
      "  Ollama:          http://localhost:11434 (Windows host)"
      "  Container route: $OllamaHost (WSL relay)"
    )
  }

  if ($OllamaHost) {
    $ollamaLabel = if ($OllamaWsl) { "WSL native" } else { "external" }
    return "  Ollama:     $OllamaHost ($ollamaLabel)"
  }

  return "  Ollama:     disabled"
}

# Verify CRW (Code Ready Workspace) is running and healthy in Docker.
# CRW typically starts quickly but this waits up to 30 seconds with TCP health checks.
# Returns $true if healthy, $false if container doesn't exist or fails health check.
function Normalize-OllamaHostForContainer {
  param([string] $OllamaHost)

  if (-not $OllamaHost) { return "" }

  try {
    $uri = [Uri]$OllamaHost
    $loopbackHosts = @("127.0.0.1", "localhost", "::1", "0.0.0.0")
    if ($loopbackHosts -contains $uri.Host) {
      $builder = New-Object System.UriBuilder($uri)
      $builder.Host = "host.docker.internal"
      return $builder.Uri.AbsoluteUri.TrimEnd('/')
    }
  } catch {
    # Keep original value if it cannot be parsed as absolute URI.
  }

  return $OllamaHost.TrimEnd('/')
}

function Get-OpenAiCompatBaseUrl {
  param([string] $BaseHost)

  if (-not $BaseHost) {
    return "http://host.docker.internal:11434/v1"
  }

  try {
    $uri = [Uri]$BaseHost
    $path = if ($uri.AbsolutePath) { $uri.AbsolutePath.TrimEnd('/') } else { "" }

    if (-not $path -or $path -eq "/") {
      return ("{0}://{1}:{2}/v1" -f $uri.Scheme, $uri.Host, $uri.Port)
    }

    if ($path -match '/v1$') {
      return ("{0}://{1}:{2}{3}" -f $uri.Scheme, $uri.Host, $uri.Port, $path)
    }

    return ("{0}://{1}:{2}{3}/v1" -f $uri.Scheme, $uri.Host, $uri.Port, $path)
  } catch {
    return "http://host.docker.internal:11434/v1"
  }
}

function Test-WslCrwHealth {
    param(
        [string] $ContainerName = "openclaw-crw",
        [int] $TimeoutSeconds = 30
    )

    try {
        # Check if container exists and is running
        $containerExists = wsl bash -c "docker ps -q -f name=^${ContainerName}$" 2>$null
        if (-not $containerExists) {
            return $false
        }

        # Wait for CRW to respond on port 3000
        $elapsed = 0
        while ($elapsed -lt $TimeoutSeconds) {
            $check = wsl bash -c "timeout 3 bash -c '</dev/tcp/localhost/3000' 2>/dev/null && echo OK || echo FAIL" 2>$null
            if ($check -match "OK") {
                return $true
            }
            Start-Sleep -Seconds 1
            $elapsed++
        }
        return $false
    } catch {
        return $false
    }
}

# Generate the docker-compose-wsl.yaml content from a single template.
# This is the SOURCE OF TRUTH for compose layout — both deploy and update use it.
function New-OpenClawComposeYaml {
    param(
        [Parameter(Mandatory)] [string] $ContainerName,
        [Parameter(Mandatory)] [string] $ImageName,
        [Parameter(Mandatory)] [string] $HomeDir,
        [Parameter(Mandatory)] [string] $WslDataDir,
        [Parameter(Mandatory)] [int]    $GatewayPort,
        [Parameter(Mandatory)] [int]    $BridgePort,
        [Parameter(Mandatory)] [string] $GatewayToken,
        [string] $OllamaHost = "",
        [switch] $OllamaSidecar,
        [string] $GroqApiKey = "",
        [switch] $Npm,
        [switch] $LanAccess
    )

    # Resolve an Ollama host value that is reachable from containers.
    $effectiveOllamaHost = ""
    $needsWindowsOllamaProxy = $false
    if ($OllamaHost) {
      $effectiveOllamaHost = Normalize-OllamaHostForContainer -OllamaHost $OllamaHost
      try {
        $ollamaUri = [Uri]$effectiveOllamaHost
        $needsWindowsOllamaProxy = $ollamaUri.Host -eq "host.docker.internal" -and $ollamaUri.Port -eq 11435
      } catch {}
      if ($effectiveOllamaHost -ne $OllamaHost) {
        Write-Host "  Rewriting container OLLAMA_HOST from $OllamaHost to $effectiveOllamaHost" -ForegroundColor Yellow
      } else {
        Write-Host "  Container OLLAMA_HOST unchanged: $effectiveOllamaHost" -ForegroundColor Gray
      }
    }

    # Determine Ollama base URL based on deployment mode.
    $ollamaBaseUrl = if ($OllamaSidecar) {
      "http://ollama:11434/v1"  # Docker sidecar on same network
    } else {
      Get-OpenAiCompatBaseUrl -BaseHost $effectiveOllamaHost
    }

    # SearXNG always runs in Docker on openclaw-net
    $searxngUrl = "http://searxng:8080"

    $envVars = @(
        "OPENCLAW_GATEWAY_TOKEN=$GatewayToken",
        "NODE_ENV=production",
        "HOME=$HomeDir",
        "TERM=xterm-256color",
        "REDIS_HOST=localhost",
        "REDIS_PORT=6379",
        "CRW_HOST=localhost",
        "CRW_PORT=3000"
    )
    if ($GroqApiKey) { $envVars += "GROQ_API_KEY=$GroqApiKey" }
    if ($OllamaSidecar) {
        $envVars += "OLLAMA_HOST=http://ollama:11434"
    } elseif ($effectiveOllamaHost) {
      $envVars += "OLLAMA_HOST=$effectiveOllamaHost"
    }
    $envVars += "OPENCLAW_DISABLE_BONJOUR=true"
    $envVars += "NPM_CONFIG_RESOLUTION_MODE=highest"
    $envVars += "npm_config_resolution_mode=highest"

    if ($Npm) {
        $startupCmd = @(
            "umask 077",
            "find $HomeDir/.openclaw/plugin-runtime-deps -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
        "npm config set prefix `$`$HOME/.openclaw/npm-global",
        "export PATH=`$`$HOME/.openclaw/npm-global/bin:`$`$PATH",
        "mkdir -p `$`$HOME/.local/node_modules/.bin",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/mslearn ] || npm install -g @microsoft/learn-cli >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/context7-mcp ] || npm install -g @upstash/context7-mcp >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance ] || npm install -g mcp-finance >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/searxng-search ] || npm install -g searxng-search >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/devdocs-mcp ] || npm install -g devdocs-mcp >/dev/null 2>&1 || true",
        "if [ -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance ] && [ ! -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance-server ]; then ln -sf `$`$HOME/.openclaw/npm-global/bin/mcp-finance `$`$HOME/.openclaw/npm-global/bin/mcp-finance-server; fi",
        "for b in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do if [ -x `$`$HOME/.openclaw/npm-global/bin/`$`$b ]; then ln -sf `$`$HOME/.openclaw/npm-global/bin/`$`$b `$`$HOME/.local/node_modules/.bin/`$`$b; fi; done",
            "mkdir -p $HomeDir/.openclaw/workspace/memory",
            "mkdir -p $HomeDir/.cache/qmd/models",
            "mkdir -p `"`$`$GOPATH/bin`"",
            "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
            "mkdir -p `$`$HOME/.openclaw/compile-cache",
            "find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true",
            "find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true",
            "find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true",
            "export OPENCLAW_NO_RESPAWN=1",
            "openclaw gateway --allow-unconfigured --bind lan --port 18789"
        ) -join " && "
        $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/usr/local/lib/node_modules/openclaw/dist/extensions"
    } else {
        $startupCmd = @(
            "umask 077",
            "find $HomeDir/.openclaw/plugin-runtime-deps -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
        "npm config set prefix `$`$HOME/.openclaw/npm-global",
        "export PATH=`$`$HOME/.openclaw/npm-global/bin:`$`$PATH",
        "mkdir -p `$`$HOME/.local/node_modules/.bin",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/mslearn ] || npm install -g @microsoft/learn-cli >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/context7-mcp ] || npm install -g @upstash/context7-mcp >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance ] || npm install -g mcp-finance >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/searxng-search ] || npm install -g searxng-search >/dev/null 2>&1 || true",
        "[ -x `$`$HOME/.openclaw/npm-global/bin/devdocs-mcp ] || npm install -g devdocs-mcp >/dev/null 2>&1 || true",
        "if [ -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance ] && [ ! -x `$`$HOME/.openclaw/npm-global/bin/mcp-finance-server ]; then ln -sf `$`$HOME/.openclaw/npm-global/bin/mcp-finance `$`$HOME/.openclaw/npm-global/bin/mcp-finance-server; fi",
        "for b in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do if [ -x `$`$HOME/.openclaw/npm-global/bin/`$`$b ]; then ln -sf `$`$HOME/.openclaw/npm-global/bin/`$`$b `$`$HOME/.local/node_modules/.bin/`$`$b; fi; done",
            "chmod -R 755 /app/dist/extensions",
            "mkdir -p $HomeDir/.openclaw/workspace/memory",
            "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
            "mkdir -p `$`$HOME/.openclaw/compile-cache",
            "find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true",
            "find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true",
            "find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true",
            "export OPENCLAW_NO_RESPAWN=1",
            "node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789"
        ) -join " && "
        $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/app/dist/extensions"
    }

    if (-not $WslDataDir) {
      throw "WslDataDir is required to generate the OpenClaw data mount."
    }

    $openclawDataMount = $WslDataDir

    $envBlock = ($envVars | ForEach-Object { "      - $_" }) -join "`n"

    # Host port binding: loopback-only by default (gateway is token-protected but
    # not intended for LAN exposure). -LanAccess publishes on all interfaces (0.0.0.0).
    $bindPrefix = if ($LanAccess) { "" } else { "127.0.0.1:" }
    $ollamaProxyDependency = if ($needsWindowsOllamaProxy) {
      "      ollama-windows-proxy:`n        condition: service_healthy"
    } else {
      ""
    }

    $composeYaml = @"
networks:
  openclaw-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.240.0/24

volumes:
  redis-data:
    driver: local
  openclaw-runtime-deps:
    driver: local
  openclaw-compile-cache:
    driver: local

services:
  redis:
    image: redis:7-alpine
    container_name: ${ContainerName}-redis
    networks:
      - openclaw-net
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "${bindPrefix}${GatewayPort}:18789"
      - "${bindPrefix}${BridgePort}:18790"
      - "127.0.0.1:6379:6379"
    volumes:
      - redis-data:/data
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --dir
      - /data
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s

  openclaw:
    image: ${ImageName}:latest
    container_name: $ContainerName
    network_mode: "service:redis"
    depends_on:
      redis:
        condition: service_healthy
$ollamaProxyDependency
    environment:
$envBlock
    volumes:
      # Use the resolved Linux-side (ext4) path to preserve secure permissions.
      # Avoid /mnt/c/... because DrvFS can surface 0777 and trigger security checks.
      - $($openclawDataMount):${HomeDir}/.openclaw
      - openclaw-runtime-deps:${HomeDir}/.openclaw/plugin-runtime-deps
      - openclaw-compile-cache:${HomeDir}/.openclaw/compile-cache
    init: true
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 6G
        reservations:
          cpus: '2'
          memory: 4G
    command:
      - bash
      - -c
      - >-
        $startupCmd
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 300s

  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    networks:
      - openclaw-net
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "8080:8080"
    # SearXNG metasearch engine — reachable from openclaw at http://searxng:8080
    # (openclaw shares redis's netns on openclaw-net, so service DNS resolves).
    # settings.yml enables the JSON result format that openclaw's MCP server needs.
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  crw:
    image: ghcr.io/us/crw:latest
    container_name: openclaw-crw
    networks:
      - openclaw-net
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "3000:3000"
    environment:
      # LLM extraction via Ollama
      - CRW_EXTRACTION__LLM__PROVIDER=openai-compatible
      - CRW_EXTRACTION__LLM__BASE_URL=$ollamaBaseUrl
      - CRW_EXTRACTION__LLM__API_KEY=key
      - CRW_EXTRACTION__LLM__MODEL=qwen3:8b
      # Search via SearXNG
      - CRW_SEARCH__SEARXNG_URL=$searxngUrl
    # CRW (Code Ready Workspace) — collaborative development environment.
    # Reachable from openclaw at http://crw:3000 via the openclaw-net bridge.
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 1G
        reservations:
          cpus: '0.25'
          memory: 512M
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
"@

    if ($needsWindowsOllamaProxy) {
        $composeYaml += @"

  ollama-windows-proxy:
    image: ${ImageName}:latest
    container_name: ${ContainerName}-ollama-windows-proxy
    network_mode: host
    command:
      - node
      - -e
      - >-
        const net = require('node:net');
        net.createServer((client) => {
          const upstream = net.connect(11434, '127.0.0.1');
          client.pipe(upstream);
          upstream.pipe(client);
          const close = () => { client.destroy(); upstream.destroy(); };
          client.on('error', close);
          upstream.on('error', close);
        }).listen(11435, '0.0.0.0');
    init: true
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:11435/api/tags').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s
"@
    }

    if ($OllamaSidecar) {
        $composeYaml += @"

  ollama:
    image: ollama/ollama:latest
    container_name: ${ContainerName}-ollama
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
    networks:
      - openclaw-net
    volumes:
      - ./ollama-data:/root/.ollama
    ports:
      - "11434:11434"
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:11434/"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 10s
"@
    }

    return $composeYaml
}

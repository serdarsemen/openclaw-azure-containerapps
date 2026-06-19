# ---------------------------------------------------------------------------
# wsl-helpers.ps1 — Shared helpers for OpenClaw WSL deploy/update scripts
#
# Dot-source from deploy-openclaw-wsl.ps1 and update-openclaw-wsl.ps1:
#   . "$PSScriptRoot/wsl-helpers.ps1"
# ---------------------------------------------------------------------------

# Run a WSL command, merge stderr into the return value, throw on non-zero exit.
function Invoke-Wsl {
    param([string] $Command)
    $result = wsl bash -c $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command`n$result"
    }
    return $result
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
    'registry-1\.docker\.io'
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

        # Set OLLAMA_HOST to 0.0.0.0:11434 if not already set
        $currentHost = [System.Environment]::GetEnvironmentVariable('OLLAMA_HOST', 'User')
        if ($currentHost -ne '0.0.0.0:11434') {
            Write-Host "    Setting OLLAMA_HOST=0.0.0.0:11434 in user environment..." -ForegroundColor Gray
            [System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0:11434', 'User')
            $env:OLLAMA_HOST = '0.0.0.0:11434'
        }

        # Try to start the Ollama service
        Write-Host "    Starting Ollama service..." -ForegroundColor Gray
        try {
            Start-Service -Name "Ollama" -ErrorAction SilentlyContinue
        } catch {}

        # Alternative: start ollama CLI if service doesn't exist
        if (-not (Get-Service -Name "Ollama" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })) {
            Write-Host "    Ollama service not available, trying CLI start..." -ForegroundColor Gray
            Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue
        }

        # Wait for Ollama to become reachable
        Write-Host "    Waiting for Ollama to start (up to 15 seconds)..." -ForegroundColor Gray
        $maxAttempts = 15
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200) {
                    Write-Host "    Ollama started successfully" -ForegroundColor Green
                    return $true
                }
            } catch {}
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
    try {
        Write-Host "  Attempting to auto-start Ollama in WSL..." -ForegroundColor Gray

        # Check if Ollama is installed in WSL
        $ollamaCheck = wsl -- which ollama 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Ollama not found in WSL. Install with: wsl -- sudo apt-get install ollama" -ForegroundColor Yellow
            return $false
        }

        # Check and display version info
        Write-Host "  Checking Ollama version in WSL..." -ForegroundColor Gray
        try {
            $currentVersion = wsl -- bash -c "ollama --version" 2>$null
            if ($currentVersion) {
                Write-Host "    Current: $currentVersion" -ForegroundColor Gray
            }
        } catch {}
        $latestVersion = Get-LatestOllamaVersion
        if ($latestVersion) {
            Write-Host "    Latest available: $latestVersion" -ForegroundColor Gray
            Write-Host "    Tip: Update with: wsl -- sudo apt-get install --only-upgrade ollama" -ForegroundColor Gray
        }

        # Set OLLAMA_HOST in WSL environment and start service
        Write-Host "    Setting OLLAMA_HOST=0.0.0.0:11434 and starting Ollama in WSL..." -ForegroundColor Gray
        $startCmd = 'export OLLAMA_HOST=0.0.0.0:11434; '
        $startCmd += 'if command -v systemctl &>/dev/null; then '
        $startCmd += '  sudo systemctl start ollama; '
        $startCmd += 'else '
        $startCmd += '  nohup ollama serve >/dev/null 2>&1 &; '
        $startCmd += 'fi'

        wsl -- bash -c $startCmd 2>&1 | Out-Null

        # Wait for Ollama to become reachable
        Write-Host "    Waiting for Ollama to start (up to 15 seconds)..." -ForegroundColor Gray
        $maxAttempts = 15
        for ($i = 0; $i -lt $maxAttempts; $i++) {
            try {
                $check = wsl -- bash -c "curl -sf --connect-timeout 2 'http://localhost:11434' >/dev/null 2>&1 && echo OK || echo FAIL" 2>$null
                if ($check -match "OK") {
                    Write-Host "    Ollama started successfully in WSL" -ForegroundColor Green
                    return $true
                }
            } catch {}
            Start-Sleep -Seconds 1
        }
        Write-Host "    Ollama not responding after 15 seconds. Manual start may be required." -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "    Error starting Ollama in WSL: $_" -ForegroundColor Yellow
        return $false
    }
}

# Resolve -OllamaWindows / -OllamaWsl / -OllamaHost into a concrete URL and
# verify reachability. Returns @{ OllamaHost = '...'; Reachable = $bool }.
# Passes the resolved OllamaHost through unchanged when an explicit URL is given.
function Resolve-OllamaHost {
    param(
        [switch] $OllamaWindows,
        [switch] $OllamaWsl,
        [string] $OllamaHost = ""
    )

    if (-not ($OllamaWindows -or $OllamaWsl -or $OllamaHost)) {
        return @{ OllamaHost = ""; Reachable = $false }
    }

    Write-Host "`n=== Resolving Ollama host ===" -ForegroundColor Cyan
    Write-Host "  Note: this script does not auto-install or auto-start Ollama." -ForegroundColor Gray
    Write-Host "  Ollama runs only when explicitly requested via -Ollama / -OllamaWindows / -OllamaWsl / -OllamaHost." -ForegroundColor Gray

    $dockerOs = (Invoke-WslData "docker info --format '{{.OperatingSystem}}' 2>/dev/null").Trim()
    $isDockerDesktop = $dockerOs -match "Docker Desktop"
    if ($isDockerDesktop) {
        Write-Host "  Docker runtime: Docker Desktop (host.docker.internal -> Windows)" -ForegroundColor Gray
    } else {
        Write-Host "  Docker runtime: Docker Engine in WSL (host.docker.internal -> WSL)" -ForegroundColor Gray
    }

    if ($OllamaWindows) {
        if ($isDockerDesktop) {
            $OllamaHost = "http://host.docker.internal:11434"
            Write-Host "  Routing via host.docker.internal (Docker Desktop -> Windows)" -ForegroundColor Green
        } else {
            # Primary: default route gateway (most reliable for WSL2 -> Windows)
            $windowsIp = (Invoke-WslData "ip route show default 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p'").Trim()
            # Fallback: resolv.conf nameserver (works when DNS points at Windows host)
            if (-not $windowsIp) {
                $nsLine = (Invoke-WslData "grep -m1 nameserver /etc/resolv.conf").Trim()
                $windowsIp = ($nsLine -split '\s+')[-1]
            }
            # Validate: must be a private/link-local IP, not a public DNS like 8.8.8.8
            if (-not $windowsIp -or $windowsIp -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)') {
                throw "Detected IP '$windowsIp' does not look like a Windows host IP (got a public address). Use -OllamaHost http://<your-windows-lan-ip>:11434 instead."
            }
            $OllamaHost = "http://${windowsIp}:11434"
            Write-Host "  Detected Windows host IP from WSL: $windowsIp" -ForegroundColor Green
        }
        Write-Host "  Auto-starting Ollama on Windows..." -ForegroundColor Green
        $null = Start-OllamaWindows
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
        $null = Start-OllamaWsl
    }

    Write-Host "  Verifying Ollama connectivity at $OllamaHost ..." -ForegroundColor Gray
    $ollamaReachable = $false
    try {
        if ($OllamaHost -match 'host\.docker\.internal') {
            if ($OllamaWindows -and $isDockerDesktop) {
                $resp = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($resp.StatusCode -eq 200) { $ollamaReachable = $true }
            } else {
                $check = wsl bash -c "curl -sf --connect-timeout 3 'http://localhost:11434' >/dev/null 2>&1 && echo OK || echo FAIL" 2>$null
                if ($check -match "OK") { $ollamaReachable = $true }
            }
        } else {
            $check = wsl bash -c "curl -sf --connect-timeout 3 '$OllamaHost' >/dev/null 2>&1 && echo OK || echo FAIL" 2>$null
            if ($check -match "OK") { $ollamaReachable = $true }
        }
    } catch {}

    if ($ollamaReachable) {
        Write-Host "  Ollama connectivity verified" -ForegroundColor Green
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

# Verify CRW (Code Ready Workspace) is running and healthy in Docker.
# CRW typically starts quickly but this waits up to 30 seconds with TCP health checks.
# Returns $true if healthy, $false if container doesn't exist or fails health check.
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
    } elseif ($OllamaHost) {
        $envVars += "OLLAMA_HOST=$OllamaHost"
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
      - CRW_EXTRACTION__LLM__BASE_URL=http://host.docker.internal:11434/v1
      - CRW_EXTRACTION__LLM__API_KEY=key
      - CRW_EXTRACTION__LLM__MODEL=qwen3.5
      # Search via SearXNG
      - CRW_SEARCH__SEARXNG_URL=http://host.docker.internal:8080
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

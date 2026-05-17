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

# Run a WSL command, discard stderr (use for value capture), throw on non-zero exit.
function Invoke-WslData {
    param([string] $Command)
    $result = wsl bash -c $Command 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command"
    }
    return $result
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
            Write-Host "  Using host.docker.internal for Windows Ollama" -ForegroundColor Green
        } else {
            $windowsIp = (Invoke-WslData "grep -m1 nameserver /etc/resolv.conf | awk '{print `$2}'").Trim()
            if (-not $windowsIp) {
                throw "Could not detect Windows host IP from WSL. Use -OllamaHost http://<windows-ip>:11434 instead."
            }
            $OllamaHost = "http://${windowsIp}:11434"
            Write-Host "  Windows host IP: $windowsIp" -ForegroundColor Green
        }
        Write-Host "  NOTE: Ollama on Windows must listen on 0.0.0.0 (not 127.0.0.1)." -ForegroundColor Yellow
        Write-Host "  Set OLLAMA_HOST=0.0.0.0:11434 in Windows environment variables and restart Ollama." -ForegroundColor Yellow
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
        Write-Host "  NOTE: Ollama in WSL must listen on 0.0.0.0 (not 127.0.0.1)." -ForegroundColor Yellow
        Write-Host "  Set OLLAMA_HOST=0.0.0.0:11434 before starting Ollama in WSL." -ForegroundColor Yellow
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
        Write-Host "  Ollama: reachable" -ForegroundColor Green
    } else {
        $sourceLabel = if ($OllamaWindows) { "Windows" } elseif ($OllamaWsl) { "WSL" } else { "external host" }
        Write-Warning "Ollama not reachable — ensure Ollama is running on $sourceLabel and listening on 0.0.0.0:11434"
        Write-Host "  Will continue, but Ollama features won't work until it's reachable." -ForegroundColor Yellow
    }
    Write-Host "  OLLAMA_HOST=$OllamaHost" -ForegroundColor Green

    return @{ OllamaHost = $OllamaHost; Reachable = $ollamaReachable }
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
        [switch] $Npm
    )

    $envVars = @(
        "OPENCLAW_GATEWAY_TOKEN=$GatewayToken",
        "NODE_ENV=production",
        "HOME=$HomeDir",
        "TERM=xterm-256color",
        "REDIS_HOST=localhost",
        "REDIS_PORT=6379"
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
            "find $HomeDir/.openclaw/plugin-runtime-deps -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
            "npm config set prefix '~/.openclaw/npm-global'",
            "mkdir -p $HomeDir/.openclaw/workspace/memory",
            "mkdir -p $HomeDir/.cache/qmd/models",
            "mkdir -p `"`$`$GOPATH/bin`"",
            "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
            "mkdir -p `$`$HOME/.openclaw/compile-cache",
            "chmod 600 $HomeDir/.openclaw/agents/main/sessions/sessions.json 2>/dev/null || true",
            "export OPENCLAW_NO_RESPAWN=1",
            "openclaw gateway --allow-unconfigured --bind lan --port 18789"
        ) -join " && "
        $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/usr/local/lib/node_modules/openclaw/dist/extensions"
    } else {
        $startupCmd = @(
            "find $HomeDir/.openclaw/plugin-runtime-deps -maxdepth 2 -name '.openclaw-runtime-deps.lock' -type d -exec rm -rf {} + 2>/dev/null || true",
            "chmod -R 755 /app/dist/extensions",
            "mkdir -p $HomeDir/.openclaw/workspace/memory",
            "export NODE_COMPILE_CACHE=`$`$HOME/.openclaw/compile-cache",
            "mkdir -p `$`$HOME/.openclaw/compile-cache",
            "chmod 600 $HomeDir/.openclaw/agents/main/sessions/sessions.json 2>/dev/null || true",
            "export OPENCLAW_NO_RESPAWN=1",
            "node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789"
        ) -join " && "
        $envVars += "OPENCLAW_BUNDLED_PLUGINS_DIR=/app/dist/extensions"
    }

    $envBlock = ($envVars | ForEach-Object { "      - $_" }) -join "`n"

    $composeYaml = @"
networks:
  openclaw-net:
    driver: bridge

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
      - "${GatewayPort}:18789"
      - "${BridgePort}:18790"
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
      - ${WslDataDir}:${HomeDir}/.openclaw
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
"@

    if ($OllamaSidecar) {
        $composeYaml += @"

  ollama:
    image: ollama/ollama:latest
    container_name: ${ContainerName}-ollama
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

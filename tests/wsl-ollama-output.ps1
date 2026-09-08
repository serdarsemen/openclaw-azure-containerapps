$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'wsl-helpers.ps1')
$script:messages = @()
function Write-Host {
    param($Object, $ForegroundColor)
    $script:messages += [string]$Object
}
function Invoke-WslData {
    param([string] $Command)
    if ($Command -match 'docker info') { 'Docker Engine' }
    elseif ($Command -match 'ip route') { '192.168.1.1' }
    elseif ($Command -match 'nameserver') { 'nameserver 192.168.1.1' }
    else { throw "Unexpected command: $Command" }
}
function Get-NetIPAddress { param($AddressFamily, $InterfaceAlias, $ErrorAction) }
function Get-NetIPConfiguration {
    param($ErrorAction)
    [pscustomobject]@{ IPv4DefaultGateway = '192.168.1.1'; IPv4Address = [pscustomobject]@{ IPAddress = '192.168.1.190' } }
}
function Start-OllamaWindows { param([switch] $Upgrade) $true }
function Wait-OllamaEndpointFromWsl {
    param($Url, $MaxAttempts, $DelaySeconds)
    $Url -in @('http://127.0.0.1:11434', 'http://localhost:11434')
}
$result = Resolve-OllamaHost -OllamaWindows
$transcript = $script:messages -join "`n"
$failures = @()
if ($result.OllamaHost -ne 'http://host.docker.internal:11435' -or -not $result.Reachable) { $failures += 'Relay resolution changed' }
if ($transcript -match 'taskkill|setx|winget|does not auto-install|only when explicitly requested|keeping fallback') { $failures += 'Successful resolution prints unnecessary setup or premature fallback guidance' }
if ($transcript -notmatch 'relay.*(pending|after|startup)|(?:pending|after|startup).*relay') { $failures += 'Relay verification must be described as pending startup' }
if ($transcript -match 'Verifying Ollama connectivity at http://host.docker.internal:11435') { $failures += 'Transcript claims to probe the relay instead of the upstream endpoint' }
if ($transcript -notmatch 'Verifying.*http://localhost:11434.*WSL') { $failures += 'Transcript must identify the actual probe URL and WSL context' }
if ((Get-OllamaWindowsSetupLines) -notcontains '  $env:OLLAMA_HOST = "0.0.0.0:11434"') { $failures += 'Manual setup must update the current PowerShell environment' }

$script:messages = @()
function Wait-OllamaEndpointFromWsl { param($Url, $MaxAttempts, $DelaySeconds) $false }
$null = Resolve-OllamaHost -OllamaHost 'http://external.example:11434' -WarningAction SilentlyContinue
if (($script:messages -join "`n") -match '(?m)^\s*Auto-start was attempted') { $failures += 'External endpoint failure incorrectly claims auto-start' }

if ($failures.Count) { throw ($failures -join "`n") }
Write-Output 'Passed Ollama relay transcript, manual setup, and external failure checks.'
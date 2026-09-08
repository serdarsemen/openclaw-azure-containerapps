$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')
$script:attempts = 0
function wsl {
    $script:attempts++
    if ($script:attempts -eq 1) {
        $global:LASTEXITCODE = 1
        'connection reset by peer'
    } else {
        $global:LASTEXITCODE = 0
        'build complete'
    }
}
function Start-Sleep { param($Seconds) }
$script:messages = @()
function Write-Host { param($Object, $ForegroundColor) $script:messages += [string]$Object }
$null = Invoke-WslRetry -Command 'test build' -Stream
if ($script:attempts -ne 2 -or $script:messages -notcontains 'build complete') { throw 'Streaming retry failed' }
function wsl { $global:LASTEXITCODE = 1; 'non-transient build failure' }
$failed = $false
try { Invoke-WslRetry -Command 'test build' -Stream } catch { $failed = $true }
if (-not $failed) { throw 'Streaming build swallowed failure' }
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'deploy-openclaw-wsl.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Deployment parse errors' }
$text = $ast.Extent.Text
foreach ($required in @('prepare-wsl-build.sh', 'BuildNodeHeapMB', 'BuildTsdownHeapMB', '--progress=plain', 'OPENCLAW_DOCKER_BUILD_NODE_OPTIONS', 'OPENCLAW_DOCKER_BUILD_TSDOWN_MAX_OLD_SPACE_MB', 'Stopwatch', 'MemAvailable')) {
    if (-not $text.Contains($required)) { throw "Missing build integration: $required" }
}
if ($text.Contains("rm -rf '`$(`$SourceArchive.WslArchivePath)'")) { throw 'Deployment still deletes reusable source context' }
Write-Output 'PASS: streaming retries and failures, build options, timing, and context integration.'
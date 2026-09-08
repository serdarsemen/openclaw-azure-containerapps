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
$sourceBranch = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.ElseClause -and $node.ElseClause.Extent.Text.Contains('prepare-wsl-build.sh')
}, $true).ElseClause.Extent.Text
$sourceBuild = [scriptblock]::Create($sourceBranch.Substring(1, $sourceBranch.Length - 2))
function wsl {
    $script:nativeCalls += ,@($args)
    $global:LASTEXITCODE = 0
    if ($args[1] -eq 'wslpath') { '/mnt/c/custom source'; return }
    if ($script:failPreparation) { $global:LASTEXITCODE = 1; return }
    "/tmp/cache with spaces/user's-context"
}
function Invoke-WslData { '1048576' }
function Invoke-WslStream { param($Command) }
function Invoke-Wsl { param($Command) }
function Write-Warning { param($Message) $script:warnings += $Message }
function Invoke-WslRetry {
    param($Command, [switch]$Stream)
    if (-not $Stream) { throw 'Build did not enable streaming' }
    $script:buildCommands += $Command
    if ($script:failBuild) { throw 'fixture build failure' }
}
$WslScriptRoot = '/mnt/c/repo'
$ToolsDockerfile = 'images/Dockerfile.tools'
$ImageName = 'openclaw-source'
$totalSteps = 5
$BuildCacheDir = '/tmp/cache with spaces'
$BuildNodeHeapMB = 4096
$BuildTsdownHeapMB = 2048
$Tag = 'v-test'
foreach ($SourcePath in @('', '/tmp/user source', 'C:\custom source')) {
    $script:nativeCalls = @()
    $script:buildCommands = @()
    $script:warnings = @()
    & $sourceBuild
    $preparationCall = $script:nativeCalls[-1]
    $expectedSource = if ($SourcePath.StartsWith('C:')) { '/mnt/c/custom source' } else { $SourcePath }
    if ($preparationCall[3] -cne $expectedSource -or $preparationCall[4] -cne $Tag -or $preparationCall[5] -cne $BuildCacheDir) { throw 'Preparation arguments changed' }
    if ($script:buildCommands.Count -ne 2) { throw 'Expected base and tools builds' }
    if (-not $script:buildCommands[0].Contains('OPENCLAW_DOCKER_BUILD_NODE_OPTIONS=--max-old-space-size=4096') -or
        -not $script:buildCommands[0].Contains('OPENCLAW_DOCKER_BUILD_TSDOWN_MAX_OLD_SPACE_MB=2048')) { throw 'Heap arguments missing from base build' }
    if (-not $script:buildCommands[0].Contains("'/tmp/cache with spaces/user'`"'`"'s-context'")) { throw 'Context shell quoting failed' }
    if ($script:warnings.Count -ne 1) { throw 'Missing memory headroom warning' }
}
$SourcePath = ''
$BuildTsdownHeapMB = 0
$script:buildCommands = @()
& $sourceBuild
if ($script:buildCommands[0].Contains('OPENCLAW_DOCKER_BUILD_TSDOWN_MAX_OLD_SPACE_MB')) { throw 'Default tsdown heap should remain upstream-controlled' }
foreach ($failure in @('preparation', 'build')) {
    $script:failPreparation = $failure -eq 'preparation'
    $script:failBuild = $failure -eq 'build'
    $script:buildCommands = @()
    $script:messages = @()
    $failed = $false
    try { & $sourceBuild } catch { $failed = $true }
    if (-not $failed) { throw "$failure failure swallowed" }
    $expectedBuildCount = if ($failure -eq 'preparation') { 0 } else { 1 }
    if ($script:buildCommands.Count -ne $expectedBuildCount) { throw 'Continued building after failure' }
    if ($failure -eq 'build' -and -not ($script:messages -match 'Base build elapsed')) { throw 'Failure timing missing' }
}
Write-Output 'PASS: streaming retries/failures, deployment source paths, heap arguments, warning, timers, and failure propagation.'
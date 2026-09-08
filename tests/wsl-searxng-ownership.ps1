$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')
$failures = @()

foreach ($case in @(
    @{ Name = 'absent'; Exists = $false; Labels = @{}; Reject = $false },
    @{ Name = 'owned'; Exists = $true; Labels = @{ 'com.docker.compose.project' = 'test-project'; 'com.docker.compose.service' = 'searxng' }; Reject = $false },
    @{ Name = 'foreign'; Exists = $true; Labels = @{ 'com.docker.compose.project' = 'other'; 'com.docker.compose.service' = 'searxng' }; Reject = $true },
    @{ Name = 'unlabeled'; Exists = $true; Labels = @{}; Reject = $true },
    @{ Name = 'wrong-service'; Exists = $true; Labels = @{ 'com.docker.compose.project' = 'test-project'; 'com.docker.compose.service' = 'other' }; Reject = $true },
    @{ Name = 'inspection-failed'; Exists = $true; Labels = @{}; Reject = $true; FailInspect = $true },
    @{ Name = 'missing-project'; Exists = $true; Labels = @{}; Reject = $true; MissingProject = $true }
)) {
    $script:commands = @()
    function Invoke-WslData {
        param([string] $Command)
        $script:commands += $Command
        if ($Command -match 'container ls') {
            if ($case.Exists) { 'abcdef123456' }
        } elseif ($Command -match 'config --format json') {
            if ($case.MissingProject) { '{}' } else { '{"name":"test-project","services":{"openclaw":{"environment":{"NPM_CONFIG_RESOLUTION_MODE":"highest","npm_config_resolution_mode":"highest"}}}}' }
        } elseif ($Command -match 'inspect') {
            if ($case.FailInspect) { throw 'Simulated inspection failure' }
            $case.Labels | ConvertTo-Json -Compress
        } else { throw "Unexpected command: $Command" }
    }
    $rejected = $false
    try { Assert-OpenClawSearxngOwnership -WslComposePath '/test/compose.yaml' -WslDataDir '/test/data' } catch { $rejected = $true }
    if ($rejected -ne $case.Reject) { $failures += "Unexpected result for $($case.Name)" }
    if ($script:commands -match 'docker (rm|stop|kill)|compose .* down') { $failures += 'Ownership check performed a destructive action' }
}

foreach ($fileName in @('deploy-openclaw-wsl.ps1', 'update-openclaw-wsl.ps1')) {
    $parseTokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $fileName), [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { $failures += "$fileName has parse errors" }
    $check = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-OpenClawSearxngOwnership' }, $true)
    $down = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.Extent.Text -match 'down --remove-orphans' }, $true)
    if (-not $check -or -not $down -or $check.Extent.StartOffset -gt $down.Extent.StartOffset) { $failures += "$fileName must check ownership before shutdown" }
    if ($ast.Extent.Text -match 'docker rm -f searxng') { $failures += "$fileName still force-removes searxng" }
    if ($down) {
        $statement = $down
        while ($statement.Parent -ne $ast.EndBlock) { $statement = $statement.Parent }
        function Invoke-Wsl { throw 'Simulated shutdown failure' }
        $WslDataDir = '/test/data'
        $WslComposePath = '/test/compose.yaml'
        $rejected = $false
        try { Invoke-Expression $statement.Extent.Text } catch { $rejected = $true }
        if (-not $rejected) { $failures += "$fileName swallowed shutdown failure" }
    }
}

if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'Passed 7 ownership cases and deploy/update shutdown guards.' -ForegroundColor Green
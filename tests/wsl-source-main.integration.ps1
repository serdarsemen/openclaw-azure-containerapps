$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('openclaw-git-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture

function Invoke-FixtureGit {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git command failed' }
}

try {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'deploy-openclaw-wsl.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw 'Deployment script has parser errors' }
    $checkout = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains('$sourceChanges = git status --porcelain') }, $true)
    if (-not $checkout) { throw 'Source checkout block not found' }
    $checkoutBlock = [scriptblock]::Create($checkout.Extent.Text)
    $remote = Join-Path $fixture 'remote'
    $clone = Join-Path $fixture 'clone'
    Invoke-FixtureGit init --initial-branch=main $remote
    Invoke-FixtureGit -C $remote -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m 'Fixture initial'
    Invoke-FixtureGit -C $remote tag old-release
    Invoke-FixtureGit clone $remote $clone
    Invoke-FixtureGit -C $clone checkout old-release
    Invoke-FixtureGit -C $remote -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m 'Fixture newer main'
    $expected = Invoke-FixtureGit -C $remote rev-parse main
    $Tag = 'old-release'
    Push-Location $clone
    & $checkoutBlock
    $actual = Invoke-FixtureGit -C $clone rev-parse HEAD
    $branch = Invoke-FixtureGit -C $clone symbolic-ref --short HEAD
    if ($actual -ne $expected -or $branch -ne 'main') { throw 'Did not move from detached tag to latest remote main' }

    Invoke-FixtureGit -C $clone -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m 'Fixture local-only commit'
    $localCommit = Invoke-FixtureGit -C $clone rev-parse HEAD
    $failure = ''
    Push-Location $clone
    try { & $checkoutBlock } catch { $failure = $_.Exception.Message }
    if ($failure -notmatch 'Local main contains commits') { throw 'Local-only commits were not rejected' }
    if ((Invoke-FixtureGit -C $clone rev-parse HEAD) -ne $localCommit) { throw 'Local commit was overwritten' }

    $null = New-Item -ItemType File -Path (Join-Path $clone 'local-edit.txt')
    $failure = ''
    Push-Location $clone
    try { & $checkoutBlock } catch { $failure = $_.Exception.Message }
    if ($failure -notmatch 'Source checkout has local changes') { throw 'Dirty checkout was not rejected' }
    Write-Host 'Detached-tag recovery, latest remote main, and local-change protection passed'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
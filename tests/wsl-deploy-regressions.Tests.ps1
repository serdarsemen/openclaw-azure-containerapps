$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')
$deploySource = Get-Content (Join-Path $repoRoot 'deploy-openclaw-wsl.ps1') -Raw

Describe 'WSL deploy regressions' {
    It 'always selects remote main for source deployments instead of a release tag' {
        $deploySource.Contains('[string] $Tag           = ""') | Should Be $true
        $deploySource.Contains('git checkout $Tag') | Should Be $false
        $deploySource.Contains('git fetch --prune origin +refs/heads/main:refs/remotes/origin/main') | Should Be $true
        $deploySource.Contains('git checkout main') | Should Be $true
        $deploySource.Contains('git merge --ff-only origin/main') | Should Be $true
        $deploySource.Contains('$sourceCommit -ne $remoteCommit') | Should Be $true
    }

    It 'creates the logs mountpoint before validating read-only staging data' {
        $setup = "mkdir -p '`$WslStagePath/state' '`$WslStagePath/logs'"
        $deploySource.Contains($setup) | Should Be $true
        ($deploySource.IndexOf($setup) -lt $deploySource.IndexOf('Test-OpenClawCandidateConfig -CandidateImage')) | Should Be $true
    }

    It 'can validate private staging data owned by a different WSL user' {
        $script:validationCommands = @()
        Mock Invoke-WslData { if ($Command -eq 'id -u') { '1001' } else { '1002' } }
        Mock Invoke-Wsl { $script:validationCommands += $Command }
        Test-OpenClawCandidateConfig -CandidateImage 'fixture' -WslDataDir '/tmp/private' -HomeDir '/home/node' -MatchHostUser
        $script:validationCommands.Count | Should Be 2
        $script:validationCommands[0] | Should Match '--user 1001:1002'
        $script:validationCommands[1] | Should Match 'tmpfs .*uid=1001,gid=1002'
    }
    It 'allows candidate validation before SQLite has been initialized' {
        $validator = (Get-Command Test-OpenClawCandidateConfig).ScriptBlock.ToString()
        $validator.Contains('if [ -f /source/state/openclaw.sqlite ]; then') | Should Be $true
    }

    It 'requires an exact successful readiness response' {
        $deploySource.Contains('$LASTEXITCODE -eq 0 -and (($check -join "").Trim() -eq "READY")') | Should Be $true
    }

    It 'does not accept NOT_READY from the actual readiness function' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($deploySource, [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-OpenClawReady' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function wsl { $global:LASTEXITCODE = 0; 'NOT_READY' }
        function Start-Sleep { throw 'polling continued' }
        function Test-IgnorableUpdateNoiseLine { $false }
        $ContainerName = 'fixture'
        $failure = ''
        try { $null = Wait-OpenClawReady -TimeoutSec 10 } catch { $failure = $_.Exception.Message }
        $failure | Should Be 'polling continued'
    }

    It 'preserves the configured model instead of overwriting its primary value' {
        $deploySource.Contains('$config.agents.defaults.model | Add-Member -NotePropertyName primary') | Should Be $false
        $deploySource.Contains('if (-not $config.agents.defaults.model)') | Should Be $true
    }

    It 'never hard-resets the caller source checkout' {
        $deploySource.Contains('git reset --hard') | Should Be $false
        $deploySource.Contains('git merge --ff-only origin/main') | Should Be $true
    }

    It 'makes deploy-time compaction opt-in' {
        $deploySource.Contains('[switch] $CompactState') | Should Be $true
        $deploySource.Contains('-Compact:$CompactState') | Should Be $true
    }

    It 'builds the npm tools layer as the candidate' {
        $deploySource.Contains('Build-OpenClawNpmCandidate') | Should Be $true
        $script:buildCommands = @()
        Mock Invoke-WslRetry { $script:buildCommands += $Command }
        Build-OpenClawNpmCandidate -WslBuildContext '/tmp/base' -ImageName 'test-npm' -WslToolsDockerfile '/tmp/images/Dockerfile.npmtools' -WslToolsContext '/tmp/images' -RebuildTools | Should Be 'test-npm:candidate'
        $script:buildCommands.Count | Should Be 2
        $script:buildCommands[0] | Should Match 'candidate-base'
        $script:buildCommands[1] | Should Match "--no-cache .*--build-arg BASE_IMAGE='test-npm:candidate-base'.*Dockerfile.npmtools"
    }
}
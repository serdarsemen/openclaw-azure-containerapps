$repoRoot = Split-Path $PSScriptRoot -Parent
$helpers = Join-Path $repoRoot 'wsl-deploy-helpers.ps1'
if (Test-Path $helpers) { . $helpers }

Describe 'WSL deployment transaction' {
    BeforeEach {
        $configPath = Join-Path $TestDrive 'openclaw.json'
        $composePath = Join-Path $TestDrive 'compose.yaml'
        $candidateConfig = Join-Path $TestDrive 'candidate.json'
        $candidateCompose = Join-Path $TestDrive 'candidate.yaml'
        Set-Content $configPath 'old config'
        Set-Content $composePath 'old compose'
        Set-Content $candidateConfig 'new config'
        Set-Content $candidateCompose 'new compose'
        $script:events = @()
        $parameters = @{
            ConfigPath = $configPath
            ComposePath = $composePath
            CandidateConfigPath = $candidateConfig
            CandidateComposePath = $candidateCompose
            ExpectedConfigHash = (Get-FileHash $configPath).Hash
            Validate = { $script:events += 'validate' }
            Stop = { $script:events += 'stop' }
            BackupState = { $script:events += 'backup'; 'snapshot' }
            RestoreState = { param($snapshot) $script:events += "restore:$snapshot" }
            Start = { $script:events += 'start' }
            Rollback = { $script:events += 'rollback' }
        }
    }

    It 'validates before stopping and applies both staged files' {
        Invoke-OpenClawDeploymentTransaction @parameters
        ($script:events -join ',') | Should Be 'validate,stop,backup,start'
        (Get-Content $configPath -Raw).Trim() | Should Be 'new config'
        (Get-Content $composePath -Raw).Trim() | Should Be 'new compose'
    }

    It 'does not mutate live files or stop the gateway when validation fails' {
        $parameters.Validate = { throw 'invalid candidate' }
        $failure = $null
        try { Invoke-OpenClawDeploymentTransaction @parameters } catch { $failure = $_ }
        ($null -ne $failure) | Should Be $true
        $script:events.Count | Should Be 0
        (Get-Content $configPath -Raw).Trim() | Should Be 'old config'
        (Get-Content $composePath -Raw).Trim() | Should Be 'old compose'
    }

    It 'restores configuration compose and state before rolling back a failed start' {
        $parameters.Start = { $script:events += 'start'; throw 'candidate unhealthy' }
        $failure = $null
        try { Invoke-OpenClawDeploymentTransaction @parameters } catch { $failure = $_ }
        ($null -ne $failure) | Should Be $true
        ($script:events -join ',') | Should Be 'validate,stop,backup,start,stop,restore:snapshot,rollback'
        (Get-Content $configPath -Raw).Trim() | Should Be 'old config'
        (Get-Content $composePath -Raw).Trim() | Should Be 'old compose'
    }

    It 'removes new live files after a failed first deployment' {
        Remove-Item $configPath, $composePath
        $parameters.ExpectedConfigHash = ''
        $parameters.Start = { throw 'candidate unhealthy' }
        $failure = $null
        try { Invoke-OpenClawDeploymentTransaction @parameters } catch { $failure = $_ }
        ($null -ne $failure) | Should Be $true
        Test-Path $configPath | Should Be $false
        Test-Path $composePath | Should Be $false
    }

    It 'rejects a configuration changed while building without overwriting it' {
        Set-Content $configPath 'user changed config'
        $failure = $null
        try { Invoke-OpenClawDeploymentTransaction @parameters } catch { $failure = $_ }
        ($null -ne $failure) | Should Be $true
        (Get-Content $configPath -Raw).Trim() | Should Be 'user changed config'
        ($script:events -contains 'start') | Should Be $false
    }

    It 'restores files but leaves the gateway stopped if state restoration fails' {
        $parameters.Start = { throw 'candidate unhealthy' }
        $parameters.RestoreState = { throw 'state copy failed' }
        $failure = $null
        try { Invoke-OpenClawDeploymentTransaction @parameters } catch { $failure = $_ }
        ($null -ne $failure) | Should Be $true
        (Get-Content $configPath -Raw).Trim() | Should Be 'old config'
        (Get-Content $composePath -Raw).Trim() | Should Be 'old compose'
        ($script:events -contains 'rollback') | Should Be $false
        Test-Path (Join-Path $TestDrive 'recovery/compose.yaml') | Should Be $true
    }

    It 'resolves relative paths using the PowerShell location' {
        Push-Location $TestDrive
        try {
            $parameters.ConfigPath = 'openclaw.json'
            $parameters.ComposePath = 'compose.yaml'
            $parameters.CandidateConfigPath = 'candidate.json'
            $parameters.CandidateComposePath = 'candidate.yaml'
            Invoke-OpenClawDeploymentTransaction @parameters
            (Get-Content 'openclaw.json' -Raw).Trim() | Should Be 'new config'
        } finally { Pop-Location }
    }
}
$repoRoot = Split-Path $PSScriptRoot -Parent

function wsl {
    & wsl.exe @args
}

. (Join-Path $repoRoot 'wsl-helpers.ps1')

Describe "Invoke-OpenClawConfigRepair" {
    BeforeEach {
        $script:validationCalls = 0
        $script:validationError = 'Config invalid: retired setting'
        Mock Write-Host {}
        Mock Invoke-WslStream {}
        Mock wsl {
            $script:validationCalls++
            if ($script:validationCalls -eq 1) {
                $global:LASTEXITCODE = 1
                return $script:validationError
            }
            $global:LASTEXITCODE = 0
            return 'Config valid'
        }
    }

    It "does not run doctor for a config read failure" {
        $script:validationError = 'read failed: SQLite read-only worker cannot verify Gateway ownership from this process'

        {
            Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'
        } | Should Throw 'gateway recover-lock'

        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
        $script:validationCalls | Should Be 1
    }

    It "preserves non-ownership read errors without attempting config repair" {
        $script:validationError = 'read failed: EACCES permission denied'

        {
            Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'
        } | Should Throw 'permission denied'

        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
    }

    It "recognizes ownership failures without the read failed prefix" {
        $script:validationError = 'SQLite worker cannot verify Gateway ownership from this process'

        {
            Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'
        } | Should Throw 'config repair was not attempted'

        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
    }

    It "reports a read failure after doctor as unreadable rather than invalid settings" {
        Mock wsl {
            $script:validationCalls++
            $global:LASTEXITCODE = 1
            if ($script:validationCalls -eq 1) { return 'Config invalid: retired setting' }
            return 'read failed: cannot verify Gateway ownership'
        }

        {
            Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'
        } | Should Throw 'Could not read /data/openclaw.json after doctor'

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It
    }

    It "returns immediately when config is valid" {
        Mock wsl { $global:LASTEXITCODE = 0; 'Config valid' }

        Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
    }

    It "still repairs actual invalid settings and validates again" {
        Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match 'node openclaw.mjs doctor --fix --non-interactive'
        }
        $script:validationCalls | Should Be 2
    }

    It "reports validation output when settings remain invalid" {
        Mock wsl { $global:LASTEXITCODE = 1; 'Config invalid: unknown key testKey' }

        {
            Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-source' -HomeDir '/home/node'
        } | Should Throw 'testKey'
    }

    It "uses the npm CLI for npm config repair" {
        Invoke-OpenClawConfigRepair -WslDataDir '/data' -ImageName 'openclaw-npm' -HomeDir '/home/openclaw' -Npm

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match "-lc 'openclaw doctor --fix --non-interactive'"
        }
    }
}

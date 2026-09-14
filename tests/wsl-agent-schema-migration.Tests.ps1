$repoRoot = Split-Path $PSScriptRoot -Parent

function wsl {
    & wsl.exe @args
}

. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Invoke-OpenClawAgentSchemaMigration" {
    BeforeEach {
        $script:schemaChecks = 0
        Mock Write-Host {}
        Mock Invoke-WslData {
            $script:schemaChecks++
            if ($script:schemaChecks -eq 1) { return @('19', '20') }
            return @('20', '20')
        }
        Mock Invoke-WslStream {}
    }

    It "runs doctor once when a schema 19 agent database exists" {
        Invoke-OpenClawAgentSchemaMigration `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-source' `
            -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match 'doctor --fix --non-interactive'
        }
        $script:schemaChecks | Should Be 2
    }

    It "skips doctor when all agent databases already use another schema" {
        Mock Invoke-WslData { return @('20', '20') }

        Invoke-OpenClawAgentSchemaMigration `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-source' `
            -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
    }

    It "fails if schema 19 remains after doctor repair" {
        Mock Invoke-WslData { return @('19') }

        $failure = $null
        try {
            Invoke-OpenClawAgentSchemaMigration `
                -WslDataDir '/home/test/.openclaw-data' `
                -ImageName 'openclaw-source' `
                -HomeDir '/home/node'
        } catch {
            $failure = $_.Exception.Message
        }

        $failure | Should Match 'schema 19'
    }
}
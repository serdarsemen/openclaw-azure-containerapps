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
            return @('21', '21')
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

    It "runs doctor when only schema 20 agent databases exist" {
        Mock Invoke-WslData {
            $script:schemaChecks++
            if ($script:schemaChecks -eq 1) { return @('20', '20') }
            return @('21', '21')
        }

        Invoke-OpenClawAgentSchemaMigration `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-source' `
            -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match 'doctor --fix --non-interactive'
        }
        $script:schemaChecks | Should Be 2
    }

    It "skips doctor when all agent databases already use schema 21" {
        Mock Invoke-WslData { return @('21', '21') }

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

    It "fails if schema 20 remains after doctor repair" {
        Mock Invoke-WslData { return @('20') }

        $failure = $null
        try {
            Invoke-OpenClawAgentSchemaMigration `
                -WslDataDir '/home/test/.openclaw-data' `
                -ImageName 'openclaw-source' `
                -HomeDir '/home/node'
        } catch {
            $failure = $_.Exception.Message
        }

        $failure | Should Match 'schema 20'
    }

    It "runs the migration before startup in deploy and update scripts" {
        foreach ($scriptName in @('deploy-openclaw-wsl.ps1', 'update-openclaw-wsl.ps1')) {
            $content = Get-Content (Join-Path $repoRoot $scriptName) -Raw
            $migrationPosition = $content.IndexOf('Invoke-OpenClawAgentSchemaMigration')
            $startupPosition = $content.IndexOf('Invoke-WslWithNetworkPoolRecovery -Context "docker compose up"')

            $migrationPosition | Should BeGreaterThan -1
            $startupPosition | Should BeGreaterThan $migrationPosition
        }
    }
}
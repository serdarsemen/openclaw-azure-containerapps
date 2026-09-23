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

    It "uses node openclaw.mjs for the source variant doctor command" {
        Invoke-OpenClawAgentSchemaMigration `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-source' `
            -HomeDir '/home/node'

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match "-lc 'node openclaw\.mjs doctor --fix --non-interactive'"
        }
    }

    It "uses the global openclaw CLI for the npm variant doctor command" {
        Invoke-OpenClawAgentSchemaMigration `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-npm' `
            -HomeDir '/home/openclaw' `
            -Npm

        Assert-MockCalled Invoke-WslStream 1 -Exactly -Scope It -ParameterFilter {
            $Command -match "-lc 'openclaw doctor --fix --non-interactive'" -and $Command -notmatch 'openclaw\.mjs'
        }
    }

    It "passes the npm switch from deploy and update scripts" {
        foreach ($scriptName in @('deploy-openclaw-wsl.ps1', 'update-openclaw-wsl.ps1')) {
            $content = Get-Content (Join-Path $repoRoot $scriptName) -Raw
            $content | Should Match 'Invoke-OpenClawAgentSchemaMigration\s+`\s+-WslDataDir \$WslDataDir\s+`\s+-ImageName \$ImageName\s+`\s+-HomeDir \$HomeDir\s+`\s+-Npm:\$Npm'
        }
    }
}

Describe "Get-OpenClawAgentDatabaseSchemaVersions" {
    BeforeEach {
        Mock Write-Host {}
    }

    It "reads schema versions with python3 from the OpenClaw image instead of the WSL distro" {
        Mock Invoke-WslData { return @('21', ' 20 ') }

        $versions = Get-OpenClawAgentDatabaseSchemaVersions `
            -WslDataDir '/home/test/.openclaw-data' `
            -ImageName 'openclaw-source'

        ($versions -join ',') | Should Be '21,20'
        Assert-MockCalled Invoke-WslData 1 -Exactly -Scope It -ParameterFilter {
            $Command -match "docker run --rm -v '/home/test/\.openclaw-data/agents:/agents' --entrypoint python3 'openclaw-source:latest'" -and
            $Command -notmatch '-exec python3'
        }
    }

    It "fails instead of reporting no databases when a schema read fails" {
        Mock Invoke-WslData { throw "WSL command failed (exit 1): docker run" }

        $failure = $null
        try {
            Get-OpenClawAgentDatabaseSchemaVersions `
                -WslDataDir '/home/test/.openclaw-data' `
                -ImageName 'openclaw-source'
        } catch {
            $failure = $_.Exception.Message
        }

        $failure | Should Match 'Could not read agent database schema versions'
    }

    It "blocks the migration when schema detection fails" {
        Mock Invoke-WslData { throw "WSL command failed (exit 1): docker run" }
        Mock Invoke-WslStream {}

        $failure = $null
        try {
            Invoke-OpenClawAgentSchemaMigration `
                -WslDataDir '/home/test/.openclaw-data' `
                -ImageName 'openclaw-source' `
                -HomeDir '/home/node'
        } catch {
            $failure = $_.Exception.Message
        }

        $failure | Should Match 'Could not read agent database schema versions'
        Assert-MockCalled Invoke-WslStream 0 -Exactly -Scope It
    }
}
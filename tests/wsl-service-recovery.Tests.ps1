$repoRoot = Split-Path $PSScriptRoot -Parent

function wsl {
    & wsl.exe @args
}

. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Invoke-Wsl service recovery" {
    BeforeEach {
        $script:bashAttempts = 0

        Mock wsl {
            if ($args[0] -eq '--shutdown') {
                $global:LASTEXITCODE = 0
                return
            }

            $script:bashAttempts++
            if ($script:bashAttempts -eq 1) {
                $global:LASTEXITCODE = -1
                return 'Wsl/Service/0x8007274c'
            }

            $global:LASTEXITCODE = 0
            return 'removed'
        }
        Mock Start-Sleep {}
        Mock Write-Host {}
    }

    It "restarts WSL before retrying a service-level socket failure" {
        Invoke-Wsl "docker rmi openclaw-source:base 2>/dev/null || true" | Should Be 'removed'

        Assert-MockCalled wsl 1 -ParameterFilter { $args[0] -eq '--shutdown' }
        $script:bashAttempts | Should Be 2
    }
}

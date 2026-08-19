$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "upgrade-ollama-wsl.ps1"

function wsl {
    & wsl.exe @args
}

. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Test-OllamaUpgradeRequired" {
    It "requires an upgrade when the latest version is newer" {
        Test-OllamaUpgradeRequired -CurrentVersion "0.31.0" -LatestVersion "0.32.14" | Should Be $true
    }

    It "skips the upgrade when versions match" {
        Test-OllamaUpgradeRequired -CurrentVersion "0.32.14" -LatestVersion "0.32.14" | Should Be $false
    }

    It "does not downgrade a newer installed version" {
        Test-OllamaUpgradeRequired -CurrentVersion "0.33.0" -LatestVersion "0.32.14" | Should Be $false
    }

    It "requires an upgrade when forced" {
        Test-OllamaUpgradeRequired -CurrentVersion "0.32.14" -LatestVersion "0.32.14" -Force | Should Be $true
    }
}

Describe "Start-OllamaWsl automatic upgrade" {
    BeforeEach {
        Mock wsl {
            $global:LASTEXITCODE = 0
            $command = $args -join " "

            if ($command -match 'which ollama') { return "/usr/local/bin/ollama" }
            if ($command -match 'ollama --version') { return "ollama version is 0.31.0" }
            if ($command -match 'ss -ltn') { return "OK" }
            if ($command -match 'ollama version') { return "ollama version is 0.32.14" }
        }
        Mock Get-LatestOllamaVersion { return "0.32.14" }
        Mock Start-Sleep {}
        Mock Write-Host {}
    }

    It "upgrades an outdated installation before startup" {
        Mock Update-OllamaWsl { return $true }

        Start-OllamaWsl | Should Be $true

        Assert-MockCalled Update-OllamaWsl 1 -ParameterFilter {
            $CurrentVersion -eq "0.31.0" -and
            $LatestVersion -eq "0.32.14" -and
            -not $Force
        }
    }

    It "stops when a required automatic upgrade fails" {
        Mock Update-OllamaWsl { return $false }

        { Start-OllamaWsl } | Should Throw "Required Ollama upgrade failed in WSL."
    }
}

Describe "upgrade-ollama-wsl.ps1" {
    It "uses the official installer and verifies the version change" {
        Test-Path $scriptPath | Should Be $true

        $script = Get-Content $scriptPath -Raw

        $script | Should Match ([regex]::Escape("wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'"))
        $script | Should Match '\$ErrorActionPreference\s*=\s*"Stop"'
        $script | Should Match '\$LASTEXITCODE\s*-ne\s*0'
        ([regex]::Matches($script, 'ollama --version')).Count | Should BeGreaterThan 1
    }
}
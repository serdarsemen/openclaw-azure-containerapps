$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "upgrade-ollama-wsl.ps1"

function wsl {
    & wsl.exe @args
}

function ollama {
    if ($args[0] -eq '--version') {
        return $script:MockOllamaVersionOutput
    }
    return ""
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

Describe "Start-OllamaWindows automatic upgrade" {
    BeforeEach {
        $script:MockOllamaVersionOutput = "ollama version is 0.31.0"

        Mock Get-Command {
            [pscustomobject]@{ Source = "C:\\Tools\\$Name.exe" }
        } -ParameterFilter {
            $Name -in @('ollama', 'winget')
        }
        Mock Get-LatestOllamaVersion { return "0.32.14" }
        Mock Update-OllamaWindows { return $true }
        Mock Start-Service {}
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Start-Process {}
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalAddress = '0.0.0.0' } }
        Mock Start-Sleep {}
        Mock Write-Host {}
    }

    It "upgrades an outdated Windows installation before startup" {
        Start-OllamaWindows | Should Be $true

        Assert-MockCalled Update-OllamaWindows 1 -ParameterFilter {
            $CurrentVersion -eq "0.31.0" -and
            $LatestVersion -eq "0.32.14" -and
            -not $Force
        }
    }

    It "stops when a required automatic Windows upgrade fails" {
        Mock Update-OllamaWindows { return $false }

        { Start-OllamaWindows } | Should Throw "Required Ollama upgrade failed on Windows."
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
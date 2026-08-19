$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot "upgrade-ollama-wsl.ps1"

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
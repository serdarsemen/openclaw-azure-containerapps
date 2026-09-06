$repoRoot = Split-Path $PSScriptRoot -Parent

Describe 'AKS deployment script syntax' {
    It 'parses without executing deployment commands' {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'deploy-openclaw-aks.ps1'),
            [ref]$tokens,
            [ref]$parseErrors
        )

        @($parseErrors).Count | Should Be 0
    }
}
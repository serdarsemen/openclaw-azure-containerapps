$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "ConvertTo-WslCommand" {
    It "normalizes Windows line endings before passing commands to Bash" {
        $command = "printf 'first'`r`nprintf 'second'`r`n"

        $normalized = ConvertTo-WslCommand -Command $command

        $normalized | Should Be "printf 'first'`nprintf 'second'`n"
        $normalized.Contains("`r") | Should Be $false
    }
}

Describe "Test-OpenClawCandidateConfig" {
    It "uses ephemeral writable logs with the read-only configuration mount" {
        $helpers = Get-Content (Join-Path $repoRoot "wsl-helpers.ps1") -Raw
        $expectedMounts = @'
-v '${WslDataDir}:${HomeDir}/.openclaw:ro' --tmpfs '${HomeDir}/.openclaw/logs:uid=1000,gid=1000'
'@

        $helpers | Should Match ([regex]::Escape($expectedMounts.Trim()))
    }
}
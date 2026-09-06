$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')

Describe 'WSL sidecar image refresh' {
    BeforeEach {
        $script:attemptedImages = @()
        $script:refreshWarnings = @()
        Mock Write-Warning { $script:refreshWarnings += $Message }
        Mock Invoke-WslRetry {
            $script:attemptedImages += $Command
            if ($Command -match 'redis:7-alpine') {
                throw 'http: server gave HTTP response to HTTPS client'
            }
        }
        Mock Invoke-WslData { 'sha256:cached' }
    }

    It 'still refreshes other images after a pull fails with a cached fallback' {
        Invoke-WslImageRefresh -Images @('redis:7-alpine', 'searxng/searxng:latest', 'ghcr.io/us/crw:latest')
        $script:attemptedImages.Count | Should Be 3
        ($script:attemptedImages -join ' ') | Should Match 'searxng/searxng:latest'
        ($script:attemptedImages -join ' ') | Should Match 'ghcr.io/us/crw:latest'
        ($script:refreshWarnings -join ' ') | Should Match 'cached'
        ($script:refreshWarnings -join ' ') | Should Match 'HTTPS'
    }

    It 'reports missing images after attempting every pull' {
        Mock Invoke-WslData { '' }
        $failure = ''
        try {
            Invoke-WslImageRefresh -Images @('redis:7-alpine', 'searxng/searxng:latest', 'ghcr.io/us/crw:latest')
        } catch { $failure = $_.Exception.Message }
        $script:attemptedImages.Count | Should Be 3
        $failure | Should Match 'redis:7-alpine'
        $failure | Should Match 'no cached image'
    }

    It 'does not claim cached fallback if the cache inspection fails' {
        Mock Invoke-WslData { throw 'daemon unavailable' }
        $failure = ''
        try { Invoke-WslImageRefresh -Images @('redis:7-alpine') } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'no cached image'
    }

    It 'does not inspect cached images after successful pulls' {
        Mock Invoke-WslRetry {}
        Invoke-WslImageRefresh -Images @('redis:7-alpine', 'searxng/searxng:latest', 'ghcr.io/us/crw:latest')
        Assert-MockCalled Invoke-WslData -Times 0 -Exactly -Scope It
        $script:refreshWarnings.Count | Should Be 0
    }

    It 'uses independent refresh in both WSL entry points' {
        foreach ($scriptName in @('deploy-openclaw-wsl.ps1', 'update-openclaw-wsl.ps1')) {
            $source = Get-Content (Join-Path $repoRoot $scriptName) -Raw
            $source.Contains("Invoke-WslImageRefresh -Images @('redis:7-alpine', 'searxng/searxng:latest', 'ghcr.io/us/crw:latest')") | Should Be $true
        }
    }
}
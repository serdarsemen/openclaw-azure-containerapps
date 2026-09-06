$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Bounded WSL health checks" {
    It "bounds HTTP response time as well as connection time" {
        Mock wsl { 'OK' }
        Test-OllamaEndpointFromWsl -Url 'http://localhost:11434' | Should Be $true
        Assert-MockCalled wsl -Times 1 -ParameterFilter { ($args -join ' ') -match '--max-time 2' }
    }

    It "polls readiness without repeating the audit" {
        Mock Test-OpenClawRuntimeState { $true }
        Wait-OpenClawContainerHealthy -ContainerName 'test' -MaxAttempts 2 | Should Be $true
        Assert-MockCalled Test-OpenClawRuntimeState -Times 1 -ParameterFilter { $SkipAudit }
        Assert-MockCalled Test-OpenClawRuntimeState -Times 1 -ParameterFilter { -not $SkipAudit }
    }

    It "bounds runtime inspection and audit commands" {
        Mock Invoke-WslData { 'running healthy 0' }
        Mock Invoke-Wsl {}
        Test-OpenClawRuntimeState -ContainerName 'test' | Should Be $true
        Assert-MockCalled Invoke-Wsl -Times 1 -ParameterFilter { $Command -match 'timeout .*docker exec' }
    }
}

Describe "WSL retry classification" {
    It "does not retry a missing npm package" {
        Test-WslTransientNetworkError 'npm ERR! E404 Not Found - GET https://registry.npmjs.org/missing-package' | Should Be $false
    }

    It "does not retry a missing image tag" {
        Test-WslTransientNetworkError 'failed to resolve registry-1.docker.io/library/node:missing: not found' | Should Be $false
    }

    It "does not retry authentication failures even with a network error in the log" {
        Test-WslTransientNetworkError 'registry.npmjs.org connection reset by peer; npm ERR! code E401 Unauthorized' | Should Be $false
    }

    It "still retries connection timeouts" {
        Test-WslTransientNetworkError 'UND_ERR_CONNECT_TIMEOUT fetching https://registry.npmjs.org/package' | Should Be $true
    }

    It "does not retry arbitrary WSL service errors" {
        Test-WslTransientNetworkError 'Wsl/Service/WSL_E_DISTRO_NOT_FOUND' | Should Be $false
    }
}
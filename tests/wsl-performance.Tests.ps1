$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Bounded WSL health checks" {
    It "retries a temporary audit failure within the deadline" {
        $script:auditAttempts = 0
        Mock Test-OpenClawRuntimeState {
            if ($SkipAudit) { return $true }
            $script:auditAttempts++
            return $script:auditAttempts -ge 2
        }
        Mock Start-Sleep {}
        Wait-OpenClawContainerHealthy -ContainerName 'test' -MaxAttempts 3 | Should Be $true
        $script:auditAttempts | Should Be 2
    }

    It "bounds HTTP response time as well as connection time" {
        (Get-Command Test-OllamaEndpointFromWsl).ScriptBlock.ToString() | Should Match '--max-time \$TimeoutSeconds'
    }

    It "polls readiness without repeating the audit" {
        Mock Test-OpenClawRuntimeState { $true }
        Wait-OpenClawContainerHealthy -ContainerName 'test' -MaxAttempts 2 | Should Be $true
        Assert-MockCalled Test-OpenClawRuntimeState -Times 1 -ParameterFilter { $SkipAudit }
        Assert-MockCalled Test-OpenClawRuntimeState -Times 1 -ParameterFilter { -not $SkipAudit }
    }

    It "bounds runtime inspection and audit commands" {
        . (Join-Path $repoRoot "wsl-helpers.ps1")
        $script:auditCommand = ''
        Mock Invoke-WslData {
            if ($Command -match 'State.Status') { 'running healthy 0' }
            elseif ($Command -match 'StartedAt') { '2026-09-06T00:00:00Z' }
        }
        Mock Invoke-Wsl { $script:auditCommand = $Command }
        Test-OpenClawRuntimeState -ContainerName 'test' | Should Be $true
        $script:auditCommand | Should Match 'timeout .*docker exec'
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
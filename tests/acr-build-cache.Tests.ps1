$repoRoot = Split-Path $PSScriptRoot -Parent
$helperPath = Join-Path $repoRoot 'acr-build-helpers.ps1'
if (Test-Path $helperPath) { . $helperPath }

Describe 'ACR content keys' {
    It 'is stable for unchanged inputs and changes with identity' {
        $first = Get-OpenClawBuildKey -Identity 'commit-a'
        $first | Should Be (Get-OpenClawBuildKey -Identity 'commit-a')
        $first | Should Not Be (Get-OpenClawBuildKey -Identity 'commit-b')
    }

    It 'includes build file contents' {
        $path = Join-Path $TestDrive 'Dockerfile'
        Set-Content $path 'FROM node:22-slim'
        $first = Get-OpenClawBuildKey -Identity 'commit-a' -Files @($path)
        Set-Content $path 'FROM node:24-slim'
        $first | Should Not Be (Get-OpenClawBuildKey -Identity 'commit-a' -Files @($path))
    }
}

Describe 'ACR cached builds' {
    It 'retags a cached digest instead of rebuilding' {
        Mock Get-AcrImageDigest { 'sha256:cached' }
        Mock Invoke-AcrBuildCommand {}
        Invoke-AcrCachedBuild -Registry 'test' -Image 'openclaw:tools-key' -Dockerfile 'images/Dockerfile.tools' -Context 'images' -AdditionalTag 'openclaw:latest'
        Assert-MockCalled Invoke-AcrBuildCommand -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'build' }
        Assert-MockCalled Invoke-AcrBuildCommand -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'import' -and $Arguments -contains 'test.azurecr.io/openclaw@sha256:cached' }
    }

    It 'forces a no-cache build on refresh' {
        Mock Get-AcrImageDigest { 'sha256:cached' }
        Mock Invoke-AcrBuildCommand {}
        Invoke-AcrCachedBuild -Registry 'test' -Image 'openclaw:base-key' -Dockerfile 'Dockerfile' -Context '.' -Refresh
        Assert-MockCalled Get-AcrImageDigest -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-AcrBuildCommand -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'build' -and $Arguments -contains '--no-cache' }
    }

    It 'builds and tags a cache miss' {
        Mock Get-AcrImageDigest { '' }
        Mock Invoke-AcrBuildCommand {}
        Invoke-AcrCachedBuild -Registry 'test' -Image 'openclaw:tools-key' -Dockerfile 'Dockerfile' -Context '.' -AdditionalTag 'openclaw:latest'
        Assert-MockCalled Invoke-AcrBuildCommand -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'build' -and $Arguments -contains 'openclaw:tools-key' -and $Arguments -contains 'openclaw:latest' }
    }
}

Describe 'ACR cache retention' {
    It 'keeps the active digest even when its cache tag is older' {
        Mock Get-AcrRepositoryTags {
            @(
                [pscustomobject]@{ name = 'tools-new'; digest = 'new' },
                [pscustomobject]@{ name = 'tools-active'; digest = 'active' },
                [pscustomobject]@{ name = 'tools-stale'; digest = 'stale' },
                [pscustomobject]@{ name = 'latest'; digest = 'active' }
            )
        }
        Mock Invoke-AcrBuildCommand {}
        Invoke-AcrBaseImageSweep -Registry 'test' -Repository 'openclaw' -KeepTagPrefix 'tools-' -Keep 1
        Assert-MockCalled Invoke-AcrBuildCommand -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments -contains 'openclaw:tools-stale' }
        Assert-MockCalled Invoke-AcrBuildCommand -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments -contains 'openclaw:tools-active' }
    }

    It 'protects the selected older base image' {
        Mock Get-AcrRepositoryTags {
            @(
                [pscustomobject]@{ name = 'base-new'; digest = 'new' },
                [pscustomobject]@{ name = 'base-selected'; digest = 'selected' }
            )
        }
        Mock Invoke-AcrBuildCommand {}
        Invoke-AcrBaseImageSweep -Registry 'test' -Repository 'openclaw' -KeepTagPrefix 'base-' -Keep 1 -ProtectedTags @('base-selected')
        Assert-MockCalled Invoke-AcrBuildCommand -Times 0 -Exactly -Scope It
    }
}
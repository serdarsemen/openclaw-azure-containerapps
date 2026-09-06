$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')
. (Join-Path $repoRoot 'source-helpers.ps1')

Describe 'Build fingerprints' {
    It 'is deterministic and changes with source or build input changes' {
        $first = Get-OpenClawBuildFingerprint -Inputs @('source', 'commit-a', 'tools-a')
        $first | Should Match '^[0-9a-f]{64}$'
        $first | Should Be (Get-OpenClawBuildFingerprint -Inputs @('source', 'commit-a', 'tools-a'))
        $first | Should Not Be (Get-OpenClawBuildFingerprint -Inputs @('source', 'commit-b', 'tools-a'))
        $first | Should Not Be (Get-OpenClawBuildFingerprint -Inputs @('source', 'commit-a', 'tools-b'))
    }

    It 'preserves boundaries between inputs' {
        Get-OpenClawBuildFingerprint -Inputs @("a`nb", 'c') | Should Not Be (Get-OpenClawBuildFingerprint -Inputs @('a', "b`nc"))
    }
}

Describe 'Image freshness' {
    BeforeEach {
        $fingerprint = 'a' * 64
        Mock Invoke-WslData { '{"io.openclaw.build-fingerprint":"' + ('a' * 64) + '"}' }
    }

    It 'reuses only an exact label match' {
        Test-OpenClawImageFresh -ImageName 'fixture' -Fingerprint $fingerprint | Should Be $true
        Test-OpenClawImageFresh -ImageName 'fixture' -Fingerprint ('b' * 64) | Should Be $false
    }

    It 'bypasses reuse for an explicit refresh without querying Docker' {
        Test-OpenClawImageFresh -ImageName 'fixture' -Fingerprint $fingerprint -ForceRefresh | Should Be $false
        Assert-MockCalled Invoke-WslData -Times 0 -Exactly -Scope It
    }

    It 'rebuilds images with no fingerprint label' {
        Mock Invoke-WslData { 'null' }
        Test-OpenClawImageFresh -ImageName 'fixture' -Fingerprint $fingerprint | Should Be $false
    }

    It 'rebuilds when inspection fails or returns malformed output' {
        Mock Invoke-WslData { throw 'image missing' }
        Test-OpenClawImageFresh -ImageName 'fixture' -Fingerprint $fingerprint | Should Be $false
    }

    It 'can check a tools image separately from the latest app image' {
        Test-OpenClawImageFresh -ImageName 'fixture' -Tag 'tools' -Fingerprint $fingerprint | Should Be $true
        Assert-MockCalled Invoke-WslData -Times 1 -Exactly -Scope It -ParameterFilter { $Command -match 'fixture:tools' }
    }
}

Describe 'Fingerprint-aware builds' {
    BeforeEach {
        $script:buildCommands = @()
        Mock Invoke-WslRetry { $script:buildCommands += $Command }
        Mock Invoke-Wsl {}
        Mock Invoke-WslData { 'sha256:existing-tools' }
        Mock Test-OpenClawImageFresh { $true }
        $fingerprint = 'a' * 64
        $toolsFingerprint = 'b' * 64
        $sourceParameters = @{
            WslBuildContext = '/tmp/source'
            ImageName = 'fixture-source'
            WslToolsDockerfile = '/tmp/images/Dockerfile.tools'
            WslToolsContext = '/tmp/images'
            WslOverlayDockerfile = '/tmp/images/Dockerfile.app-overlay'
            Fingerprint = $fingerprint
            ToolsFingerprint = $toolsFingerprint
        }
    }

    It 'labels the source candidate and reuses a matching tools foundation' {
        Build-OpenClawSourceCandidate @sourceParameters | Should Be 'fixture-source:candidate'
        $script:buildCommands.Count | Should Be 2
        $script:buildCommands[1] | Should Match "io.openclaw.build-fingerprint=$fingerprint"
    }

    It 'rebuilds and labels the tools foundation when its fingerprint changes' {
        Mock Test-OpenClawImageFresh { $false }
        $null = Build-OpenClawSourceCandidate @sourceParameters
        $script:buildCommands.Count | Should Be 3
        $script:buildCommands[1] | Should Match "io.openclaw.build-fingerprint=$toolsFingerprint"
        Assert-MockCalled Invoke-Wsl -Times 0 -Exactly -Scope It
    }

    It 'forces fresh base tools and overlay builds even if all labels match' {
        $null = Build-OpenClawSourceCandidate @sourceParameters -ForceRefresh
        $script:buildCommands.Count | Should Be 3
        foreach ($command in $script:buildCommands) {
            $command | Should Match '--no-cache'
        }
        $script:buildCommands[0] | Should Match '--pull'
        $script:buildCommands[1] | Should Not Match '--pull'
    }

    It 'labels the npm candidate and refreshes both stages on demand' {
        Build-OpenClawNpmCandidate -WslBuildContext '/tmp/npm' -ImageName 'fixture-npm' -WslToolsDockerfile '/tmp/images/Dockerfile.npmtools' -WslToolsContext '/tmp/images' -Fingerprint $fingerprint -ForceRefresh | Should Be 'fixture-npm:candidate'
        $script:buildCommands.Count | Should Be 2
        foreach ($command in $script:buildCommands) {
            $command | Should Match '--no-cache'
        }
        $script:buildCommands[0] | Should Match '--pull'
        $script:buildCommands[1] | Should Not Match '--pull'
        $script:buildCommands[1] | Should Match "io.openclaw.build-fingerprint=$fingerprint"
    }

    It 'clears inherited app fingerprints when a caller does not supply one' {
        $null = $sourceParameters.Remove('Fingerprint')
        $null = $sourceParameters.Remove('ToolsFingerprint')
        $null = Build-OpenClawSourceCandidate @sourceParameters
        $script:buildCommands[-1] | Should Match "--label 'io.openclaw.build-fingerprint='"
    }
}

Describe 'Deploy build selection' {
    BeforeEach {
        $source = Get-Content (Join-Path $repoRoot 'deploy-openclaw-wsl.ps1') -Raw
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        $build = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('$npmTag =') -and $node.Extent.Text.Contains('Sync-OpenClawSource') }, $true)
        $buildBlock = [scriptblock]::Create($build.Extent.Text.Replace('[System.IO.Path]::GetTempPath()', '$TestDrive'))
        $fixtureSource = Join-Path $TestDrive 'source'
        $null = New-Item -ItemType Directory -Path $fixtureSource -Force
        Set-Content (Join-Path $fixtureSource 'Dockerfile') 'FROM node:22-slim'
        $Npm = $false
        $totalSteps = 5
        $Tag = ''
        $ForceRefresh = $false
        $RebuildTools = $false
        $ImageName = 'fixture'
        $SourcePath = $fixtureSource
        $ToolsDockerfile = 'images/Dockerfile.tools'
        $WslScriptRoot = '/tmp/repo'
        $WslOverlayDockerfile = '/tmp/repo/images/Dockerfile.app-overlay'
        $buildInputs = @('fixture-build-inputs')
        $toolsInputs = @('fixture-tools-inputs')
        $script:skipDockerBuild = $true
        Mock Sync-OpenClawSource { [pscustomobject]@{ SourcePath = $fixtureSource; Commit = ('c' * 40) } }
        Mock Test-OpenClawImageFresh { return $script:skipDockerBuild -and -not $ForceRefresh }
        Mock Invoke-WslData { '/tmp/fixture' }
        Mock Invoke-Wsl {}
        Mock New-WslTransferArchive { [pscustomobject]@{ WslArchivePath = '/tmp/fixture.tar' } }
        Mock Expand-WslTransferArchive { [pscustomobject]@{ WslContextPath = '/tmp/fixture' } }
        Mock Set-OpenClawCronConcurrencyLimit {}
        Mock Set-OpenClawRestartDrainTimeout {}
        Mock Update-LocalBuildDockerfile {}
        Mock Build-OpenClawSourceCandidate { 'fixture:candidate' }
        Mock Build-OpenClawNpmCandidate { 'fixture:candidate' }
    }

    It 'skips source packaging and builds when the latest image matches' {
        & $buildBlock
        Assert-MockCalled Sync-OpenClawSource -Times 1 -Exactly -Scope It
        Assert-MockCalled New-WslTransferArchive -Times 0 -Exactly -Scope It
        Assert-MockCalled Build-OpenClawSourceCandidate -Times 0 -Exactly -Scope It
    }

    It 'passes both fingerprints and ForceRefresh through a source rebuild' {
        $ForceRefresh = $true
        & $buildBlock
        Assert-MockCalled New-WslTransferArchive -Times 1 -Exactly -Scope It
        Assert-MockCalled Build-OpenClawSourceCandidate -Times 1 -Exactly -Scope It -ParameterFilter { $ForceRefresh -and $Fingerprint.Length -eq 64 -and $ToolsFingerprint.Length -eq 64 }
    }

    It 'does not skip an explicit tools rebuild' {
        $RebuildTools = $true
        & $buildBlock
        Assert-MockCalled Build-OpenClawSourceCandidate -Times 1 -Exactly -Scope It -ParameterFilter { $RebuildTools }
    }

    It 'skips an unchanged pinned npm image' {
        $Npm = $true
        $Tag = 'v2026.6.8'
        & $buildBlock
        Assert-MockCalled Build-OpenClawNpmCandidate -Times 0 -Exactly -Scope It
    }

    It 'refreshes a floating npm tag rather than caching it indefinitely' {
        $Npm = $true
        $Tag = 'latest'
        & $buildBlock
        Assert-MockCalled Build-OpenClawNpmCandidate -Times 1 -Exactly -Scope It -ParameterFilter { $ForceRefresh -and $Fingerprint.Length -eq 64 }
    }
}
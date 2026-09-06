$repoRoot = Split-Path $PSScriptRoot -Parent
$helperPath = Join-Path $repoRoot 'source-helpers.ps1'
if (Test-Path $helperPath) { . $helperPath }

function Invoke-SourceFixtureGit {
    $output = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return $output
}

Describe 'Clean origin/main source checkout' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $remote = Join-Path $fixture 'origin'
        $checkout = Join-Path $fixture 'openclaw-repo'
        $null = Invoke-SourceFixtureGit init --initial-branch=main $remote
        Set-Content (Join-Path $remote 'source.txt') 'origin first'
        $null = Invoke-SourceFixtureGit -C $remote add source.txt
        $null = Invoke-SourceFixtureGit -C $remote -c user.name=Fixture -c user.email=fixture@example.invalid commit -m first
        $null = Invoke-SourceFixtureGit clone $remote $checkout
        Set-Content (Join-Path $remote 'source.txt') 'origin latest'
        $null = Invoke-SourceFixtureGit -C $remote add source.txt
        $null = Invoke-SourceFixtureGit -C $remote -c user.name=Fixture -c user.email=fixture@example.invalid commit -m latest
        $expected = (Invoke-SourceFixtureGit -C $remote rev-parse main) -join ''
    }

    It 'backs up all local work and displays a clean latest origin/main on branch main' {
        $null = Invoke-SourceFixtureGit -C $checkout -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m local-only
        $localCommit = (Invoke-SourceFixtureGit -C $checkout rev-parse HEAD) -join ''
        Set-Content (Join-Path $checkout 'source.txt') 'staged change'
        $null = Invoke-SourceFixtureGit -C $checkout add source.txt
        Set-Content (Join-Path $checkout 'source.txt') 'unstaged change'
        Set-Content (Join-Path $checkout 'untracked.txt') 'local file'
        $null = Invoke-SourceFixtureGit -C $checkout config fixture.setting preserved
        $originalStatus = (Invoke-SourceFixtureGit -C $checkout status --porcelain) -join "`n"

        $result = Sync-OpenClawSource -SourcePath $checkout

        $result.Commit | Should Be $expected
        (Invoke-SourceFixtureGit -C $checkout rev-parse HEAD) | Should Be $expected
        (Invoke-SourceFixtureGit -C $checkout branch --show-current) | Should Be 'main'
        (Invoke-SourceFixtureGit -C $checkout rev-parse --abbrev-ref '@{upstream}') | Should Be 'origin/main'
        ((Invoke-SourceFixtureGit -C $checkout status --porcelain) -join '') | Should Be ''
        (Get-Content (Join-Path $checkout 'source.txt') -Raw).Trim() | Should Be 'origin latest'
        Test-Path (Join-Path $checkout 'untracked.txt') | Should Be $false
        Test-Path $result.BackupPath | Should Be $true
        (Invoke-SourceFixtureGit -C $result.BackupPath rev-parse HEAD) | Should Be $localCommit
        ((Invoke-SourceFixtureGit -C $result.BackupPath status --porcelain) -join "`n") | Should Be $originalStatus
        (Get-Content (Join-Path $result.BackupPath 'source.txt') -Raw).Trim() | Should Be 'unstaged change'
        (Invoke-SourceFixtureGit -C $result.BackupPath show ':source.txt') | Should Be 'staged change'
        (Invoke-SourceFixtureGit -C $result.BackupPath config --get fixture.setting) | Should Be 'preserved'
    }

    It 'uses origin even if local main tracks a different upstream remote' {
        $other = Join-Path $fixture 'upstream'
        $null = Invoke-SourceFixtureGit clone $remote $other
        $null = Invoke-SourceFixtureGit -C $other -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -m upstream-only
        $null = Invoke-SourceFixtureGit -C $checkout remote add upstream $other
        $null = Invoke-SourceFixtureGit -C $checkout fetch upstream
        $null = Invoke-SourceFixtureGit -C $checkout branch --set-upstream-to=upstream/main main

        $result = Sync-OpenClawSource -SourcePath $checkout

        $result.Commit | Should Be $expected
        (Invoke-SourceFixtureGit -C $checkout config --get remote.origin.url) | Should Be $remote
        (Invoke-SourceFixtureGit -C $result.BackupPath config --get branch.main.remote) | Should Be 'upstream'
    }

    It 'leaves the existing checkout in place when the origin clone fails' {
        $null = Invoke-SourceFixtureGit -C $checkout remote set-url origin (Join-Path $fixture 'missing-remote')
        $original = (Invoke-SourceFixtureGit -C $checkout rev-parse HEAD) -join ''
        $failure = ''
        try { $null = Sync-OpenClawSource -SourcePath $checkout } catch { $failure = $_.Exception.Message }

        $failure | Should Match 'clone'
        (Invoke-SourceFixtureGit -C $checkout rev-parse HEAD) | Should Be $original
        @(Get-ChildItem $fixture -Directory -Filter '*.openclaw-backup-*').Count | Should Be 0
        @(Get-ChildItem $fixture -Directory -Filter '*.openclaw-staging-*').Count | Should Be 0
    }

    It 'creates a first checkout on main without a backup' {
        $newPath = Join-Path $fixture 'new-source'
        $result = Sync-OpenClawSource -SourcePath $newPath -RepositoryUrl $remote
        $result.Commit | Should Be $expected
        $result.BackupPath | Should Be ''
        (Invoke-SourceFixtureGit -C $newPath branch --show-current) | Should Be 'main'
    }

    It 'keeps earlier backups when synchronization runs again' {
        $first = Sync-OpenClawSource -SourcePath $checkout
        $second = Sync-OpenClawSource -SourcePath $checkout
        $second.BackupPath | Should Not Be $first.BackupPath
        Test-Path $first.BackupPath | Should Be $true
        Test-Path $second.BackupPath | Should Be $true
        $second.Commit | Should Be $expected
    }

    It 'refuses to move the deployment repository itself' {
        $failure = ''
        try { $null = Sync-OpenClawSource -SourcePath $repoRoot } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'deployment scripts themselves'
    }

    It 'rejects Windows aliases before trying to clone or move a checkout' {
        foreach ($alias in @("$checkout.", "\\?\$checkout")) {
            $failure = ''
            try { $null = Sync-OpenClawSource -SourcePath $alias } catch { $failure = $_.Exception.Message }
            $failure | Should Match 'canonical filesystem path'
        }
    }

    It 'refuses to move a checkout that owns linked worktrees' {
        $linked = Join-Path $fixture 'linked'
        $null = Invoke-SourceFixtureGit -C $checkout worktree add --detach $linked
        try {
            $failure = ''
            try { $null = Sync-OpenClawSource -SourcePath $checkout } catch { $failure = $_.Exception.Message }
            $failure | Should Match 'linked worktrees'
            (Invoke-SourceFixtureGit -C $linked rev-parse --is-inside-work-tree) | Should Be 'true'
            @(Get-ChildItem $fixture -Directory -Filter '*.openclaw-backup-*').Count | Should Be 0
        } finally {
            if (Test-Path -LiteralPath $linked) { Remove-Item -LiteralPath $linked -Recurse -Force }
        }
    }
}

Describe 'Source deployment integration' {
    It 'uses source sync in WSL and ACA and exports the verified commit' {
        foreach ($scriptName in @('deploy-openclaw-wsl.ps1', 'deploy-openclaw-ACA.ps1')) {
            $source = Get-Content (Join-Path $repoRoot $scriptName) -Raw
            $source.Contains('. "$PSScriptRoot/source-helpers.ps1"') | Should Be $true
            $source.Contains('Sync-OpenClawSource -SourcePath $ResolvedSourcePath') | Should Be $true
            $source.Contains('$sourceCommit = $sourceSync.Commit') | Should Be $true
            $source.Contains('git checkout') | Should Be $false
            $source.Contains('git pull') | Should Be $false
            $source.Contains('git reset') | Should Be $false
            if ($scriptName -eq 'deploy-openclaw-wsl.ps1') {
                $source.Contains('-Revision $sourceCommit') | Should Be $true
            } else {
                $source.Contains('archive --format=zip --output $ArchivePath $sourceCommit') | Should Be $true
            }
        }
    }
}
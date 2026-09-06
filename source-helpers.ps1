function Copy-OpenClawSourceEntry {
    param([string] $Source, [string] $Destination)

    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
}

function Install-OpenClawSourceContents {
    param([string] $SourcePath, [string] $StagingPath)

    $originalEntries = @(Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop)
    $candidateEntries = @(Get-ChildItem -LiteralPath $StagingPath -Force -ErrorAction Stop)
    try {
        foreach ($entry in $originalEntries) {
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
        }
        foreach ($entry in $candidateEntries) {
            Copy-OpenClawSourceEntry -Source $entry.FullName -Destination (Join-Path $SourcePath $entry.Name)
        }
    } catch {
        throw "Could not overwrite source contents: $($_.Exception.Message) '$SourcePath' may be partially overwritten. No local backup was created. Close tools or terminals holding files and check permissions. The complete clean origin/main checkout is retained at: $StagingPath"
    }
}

function Sync-OpenClawSource {
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [string] $RepositoryUrl = 'https://github.com/openclaw/openclaw.git'
    )

    $pathText = $SourcePath.Replace('/', '\')
    $aliasedComponents = @($pathText -split '\\' | Where-Object { $_ -notin '.', '..' -and ($_ -match '[. ]$') })
    if ($pathText -match '^\\\\[?.]\\' -or $aliasedComponents.Count -gt 0) {
        throw 'SourcePath must use a canonical filesystem path without device prefixes or trailing dots/spaces.'
    }
    $SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath).TrimEnd('\', '/')
    if ($SourcePath -eq [IO.Path]::GetPathRoot($SourcePath).TrimEnd('\', '/')) {
        throw 'SourcePath must be a checkout directory, not a filesystem root.'
    }
    $ancestorPath = $SourcePath
    while ($ancestorPath) {
        if (Test-Path -LiteralPath $ancestorPath) {
            $ancestor = Get-Item -LiteralPath $ancestorPath -Force
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'SourcePath must use a canonical filesystem path without symlinks or junctions.'
            }
        }
        $ancestorPath = Split-Path $ancestorPath -Parent
    }
    $scriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
    if ($scriptRoot -eq $SourcePath -or $scriptRoot.StartsWith($SourcePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourcePath cannot contain the deployment scripts themselves.'
    }

    $hadSource = Test-Path -LiteralPath $SourcePath
    if ($hadSource) {
        $source = Get-Item -LiteralPath $SourcePath -Force
        if (-not $source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-Path -LiteralPath (Join-Path $SourcePath '.git') -PathType Container)) {
            throw 'SourcePath must be a standalone Git checkout, not a linked worktree, symlink, or other directory.'
        }
        $gitDirectory = Get-Item -LiteralPath (Join-Path $SourcePath '.git') -Force
        if ($gitDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'SourcePath must use a standalone Git directory, not a symlink or junction.'
        }
        $worktrees = git -C $SourcePath worktree list --porcelain
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect linked worktrees; existing files were not changed.' }
        if (@($worktrees | Where-Object { $_ -match '^worktree ' }).Count -gt 1) {
            throw 'SourcePath owns linked worktrees. Use a separate standalone checkout; existing files were not changed.'
        }
        $origin = git -C $SourcePath remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $origin) { throw 'Could not read the source checkout origin remote; existing files were not changed.' }
        $RepositoryUrl = ($origin -join '').Trim()
        if (-not [IO.Path]::IsPathRooted($RepositoryUrl) -and $RepositoryUrl -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://' -and $RepositoryUrl -notmatch '^[^/\\]+:.+') {
            $RepositoryUrl = [IO.Path]::GetFullPath((Join-Path $SourcePath $RepositoryUrl))
        }
    }

    $suffix = (Get-Date -Format 'yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
    $stagingPath = "$SourcePath.openclaw-staging-$suffix"
    $preserveStaging = $false
    $parentPath = Split-Path $SourcePath -Parent
    $null = New-Item -ItemType Directory -Path $parentPath -Force
    try {
        Write-Host '  Cloning the origin/main tip (depth 1, no tags) before replacing local source...' -ForegroundColor Gray
        git clone --branch main --single-branch --depth 1 --no-tags --no-local -- $RepositoryUrl $stagingPath | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Source clone failed; existing files were not changed.' }
        $commit = git -C $stagingPath rev-parse --verify HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Could not verify the cloned source commit.' }
        $remoteCommit = git -C $stagingPath rev-parse --verify 'refs/remotes/origin/main^{commit}'
        if ($LASTEXITCODE -ne 0 -or $commit -ne $remoteCommit) { throw 'Cloned source does not match origin/main.' }
        $branch = git -C $stagingPath symbolic-ref --short HEAD
        if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') { throw 'Cloned source is not on main.' }

        if ($hadSource) {
            $preserveStaging = $true
            Write-Host '  Overwriting local source with origin/main. Local commits, edits, untracked/ignored files, and Git configuration will be discarded without a backup.' -ForegroundColor Yellow
            Install-OpenClawSourceContents -SourcePath $SourcePath -StagingPath $stagingPath
        } else {
            [IO.Directory]::Move($stagingPath, $SourcePath)
        }
        $preserveStaging = $false

        Write-Host "  Source checkout is on main at $commit (origin/main)." -ForegroundColor Green
        return [pscustomobject]@{ SourcePath = $SourcePath; Commit = ($commit -join '').Trim(); BackupPath = '' }
    } finally {
        if (-not $preserveStaging -and (Test-Path -LiteralPath $stagingPath)) { Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop }
    }
}
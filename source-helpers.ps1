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
    $backupPath = ''
    $parentPath = Split-Path $SourcePath -Parent
    $null = New-Item -ItemType Directory -Path $parentPath -Force
    try {
        Write-Host '  Cloning a clean origin/main checkout before replacing local source...' -ForegroundColor Gray
        git clone --branch main --single-branch --no-hardlinks -- $RepositoryUrl $stagingPath | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Source clone failed; existing files were not changed.' }
        $commit = git -C $stagingPath rev-parse --verify HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Could not verify the cloned source commit.' }
        $remoteCommit = git -C $stagingPath rev-parse --verify 'refs/remotes/origin/main^{commit}'
        if ($LASTEXITCODE -ne 0 -or $commit -ne $remoteCommit) { throw 'Cloned source does not match origin/main.' }
        $branch = git -C $stagingPath symbolic-ref --short HEAD
        if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') { throw 'Cloned source is not on main.' }

        if ($hadSource) {
            $backupPath = "$SourcePath.openclaw-backup-$suffix"
            [IO.Directory]::Move($SourcePath, $backupPath)
            Write-Host "  Original checkout preserved at: $backupPath" -ForegroundColor Yellow
        }
        try {
            [IO.Directory]::Move($stagingPath, $SourcePath)
        } catch {
            $promotionFailure = $_
            if ($backupPath -and -not (Test-Path -LiteralPath $SourcePath)) {
                try { [IO.Directory]::Move($backupPath, $SourcePath) } catch {
                    throw "Could not install or restore the source checkout. Original checkout remains at: $backupPath"
                }
            }
            throw "Could not install the fresh source checkout: $($promotionFailure.Exception.Message)"
        }

        Write-Host "  Source checkout is on main at $commit (origin/main)." -ForegroundColor Green
        return [pscustomobject]@{ SourcePath = $SourcePath; Commit = ($commit -join '').Trim(); BackupPath = $backupPath }
    } finally {
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop }
    }
}
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
    } else {
        Write-Host '  Initializing source repository for origin/main...' -ForegroundColor Gray
        git init --initial-branch=main -- $SourcePath | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize source repository.' }
        git -C $SourcePath remote add origin $RepositoryUrl
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the source origin remote.' }
    }

    Write-Host '  Fetching latest origin/main into the existing repository (no clone)...' -ForegroundColor Gray
    $fetchOptions = if ($hadSource) { @() } else { @('--depth', '1') }
    git -C $SourcePath fetch --no-tags @fetchOptions origin '+refs/heads/main:refs/remotes/origin/main' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Source fetch failed; local files and HEAD were not changed.' }
    $commit = git -C $SourcePath rev-parse --verify 'refs/remotes/origin/main^{commit}'
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve fetched origin/main; local files and HEAD were not changed.' }

    Write-Host '  Updating local main to origin/main. Local edits and local-only files are discarded without a backup; no local code is merged.' -ForegroundColor Yellow
    $previousAskYesNo = [Environment]::GetEnvironmentVariable('GIT_ASK_YESNO', 'Process')
    try {
        $env:GIT_ASK_YESNO = 'false'
        git -C $SourcePath checkout --quiet --force -B main $commit | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not force local main to the fetched commit.' }
        git -C $SourcePath reset --hard $commit | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not reset tracked source files.' }
        git -C $SourcePath clean -ffdx | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove local-only source files.' }
        git -C $SourcePath branch --set-upstream-to=origin/main main | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Could not set main to track origin/main.' }
        $head = git -C $SourcePath rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $head -ne $commit) { throw 'Source HEAD does not match the fetched origin/main commit.' }
        $status = git -C $SourcePath status --porcelain --untracked-files=all
        if ($LASTEXITCODE -ne 0 -or $status) { throw 'Source working tree is not clean after the update.' }
    } catch {
        throw "Source checkout may be partially updated: $($_.Exception.Message) No backup was created. Close tools or terminals holding files inside '$SourcePath', check permissions, and retry."
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_ASK_YESNO', $previousAskYesNo, 'Process')
    }

    Write-Host "  Source checkout is on main at $commit (origin/main); existing Git objects were reused." -ForegroundColor Green
    return [pscustomobject]@{ SourcePath = $SourcePath; Commit = ($commit -join '').Trim(); BackupPath = '' }
}
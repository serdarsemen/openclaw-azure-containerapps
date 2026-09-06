function Write-OpenClawAtomicFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if ($Path -match '^\\\\(?:wsl\.localhost|wsl\$)\\(?<distribution>[^\\]+)\\(?<relativePath>.+)$') {
            $distribution = $Matches.distribution
            $linuxPath = '/' + $Matches.relativePath.Replace('\', '/')
            $linuxTemporaryPath = $linuxPath + $temporaryPath.Substring($Path.Length)
            if (Test-Path -LiteralPath $Path) {
                wsl --distribution $distribution --exec chmod --reference=$linuxPath -- $linuxTemporaryPath
            } else {
                wsl --distribution $distribution --exec chmod 600 -- $linuxTemporaryPath
            }
            if ($LASTEXITCODE -ne 0) { throw 'Could not set permissions on the staged WSL file' }
            wsl --distribution $distribution --exec mv -f -T -- $linuxTemporaryPath $linuxPath
            if ($LASTEXITCODE -ne 0) { throw 'Could not atomically rename the staged WSL file' }
        } elseif (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temporaryPath, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Invoke-OpenClawDeploymentTransaction {
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [string] $ComposePath,
        [Parameter(Mandatory)] [string] $CandidateConfigPath,
        [Parameter(Mandatory)] [string] $CandidateComposePath,
        [AllowEmptyString()] [string] $ExpectedConfigHash,
        [Parameter(Mandatory)] [scriptblock] $Validate,
        [Parameter(Mandatory)] [scriptblock] $Stop,
        [Parameter(Mandatory)] [scriptblock] $BackupState,
        [Parameter(Mandatory)] [scriptblock] $RestoreState,
        [Parameter(Mandatory)] [scriptblock] $Start,
        [Parameter(Mandatory)] [scriptblock] $Rollback
    )

    $ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    $ComposePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ComposePath)
    $CandidateConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CandidateConfigPath)
    $CandidateComposePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CandidateComposePath)
    $recoveryPath = Join-Path (Split-Path $CandidateConfigPath -Parent) 'recovery'
    $originalFiles = @{}
    $originalHashes = @{}
    foreach ($path in @($ConfigPath, $ComposePath)) {
        $originalFiles[$path] = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllBytes($path) } else { $null }
        $originalHashes[$path] = if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path).Hash } else { '' }
    }
    if ($originalHashes[$ConfigPath] -ne $ExpectedConfigHash) {
        throw 'Configuration changed while preparing deployment. Retry with the current configuration.'
    }

    & $Validate
    $stopped = $false
    $filesApplied = $false
    $snapshot = $null
    try {
        $stopped = $true
        & $Stop
        foreach ($path in @($ConfigPath, $ComposePath)) {
            $currentHash = if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path).Hash } else { '' }
            if ($currentHash -ne $originalHashes[$path]) { throw "Deployment file changed during validation: $path" }
        }
        $snapshot = & $BackupState
        $null = New-Item -ItemType Directory -Path $recoveryPath -Force
        foreach ($path in @($ConfigPath, $ComposePath)) {
            if ($null -ne $originalFiles[$path]) {
                [System.IO.File]::WriteAllBytes((Join-Path $recoveryPath (Split-Path $path -Leaf)), $originalFiles[$path])
            }
        }
        $filesApplied = $true
        Write-OpenClawAtomicFile -Path $ConfigPath -Bytes ([System.IO.File]::ReadAllBytes($CandidateConfigPath))
        Write-OpenClawAtomicFile -Path $ComposePath -Bytes ([System.IO.File]::ReadAllBytes($CandidateComposePath))
        & $Start
    } catch {
        $deploymentFailure = $_
        $recoveryErrors = @()
        try {
            if ($filesApplied) {
                & $Stop
                try { & $RestoreState $snapshot } catch { $recoveryErrors += $_.Exception.Message }
                foreach ($path in @($ConfigPath, $ComposePath)) {
                    try {
                    if ($null -eq $originalFiles[$path]) {
                        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                    } else {
                        Write-OpenClawAtomicFile -Path $path -Bytes $originalFiles[$path]
                    }
                    } catch { $recoveryErrors += $_.Exception.Message }
                }
            }
            if ($stopped -and $recoveryErrors.Count -eq 0) { & $Rollback }
        } catch {
            $recoveryErrors += $_.Exception.Message
        }
        if ($recoveryErrors.Count -gt 0) {
            throw "Deployment failed: $($deploymentFailure.Exception.Message). Rollback also failed: $($recoveryErrors -join '; '). State snapshot: $snapshot. Original files: $recoveryPath"
        }
        throw $deploymentFailure
    }
}
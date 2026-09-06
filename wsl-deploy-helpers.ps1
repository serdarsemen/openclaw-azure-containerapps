function Write-OpenClawAtomicFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if (Test-Path -LiteralPath $Path) {
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
        $filesApplied = $true
        Write-OpenClawAtomicFile -Path $ConfigPath -Bytes ([System.IO.File]::ReadAllBytes($CandidateConfigPath))
        Write-OpenClawAtomicFile -Path $ComposePath -Bytes ([System.IO.File]::ReadAllBytes($CandidateComposePath))
        & $Start
    } catch {
        $deploymentFailure = $_
        try {
            if ($filesApplied) {
                & $Stop
                & $RestoreState $snapshot
                foreach ($path in @($ConfigPath, $ComposePath)) {
                    if ($null -eq $originalFiles[$path]) {
                        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                    } else {
                        Write-OpenClawAtomicFile -Path $path -Bytes $originalFiles[$path]
                    }
                }
            }
            if ($stopped) { & $Rollback }
        } catch {
            throw "Deployment failed: $($deploymentFailure.Exception.Message). Rollback also failed: $($_.Exception.Message). State snapshot: $snapshot"
        }
        throw $deploymentFailure
    }
}
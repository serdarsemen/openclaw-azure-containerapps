param([string] $Distribution = 'Debian')

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'wsl-deploy-helpers.ps1')

$linuxDirectory = ((wsl --distribution $Distribution --exec mktemp -d /tmp/openclaw-atomic-XXXXXXXX) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $linuxDirectory -notmatch '^/tmp/openclaw-atomic-[A-Za-z0-9]+$') { throw 'Could not create isolated WSL fixture' }
try {
    $windowsDirectory = ((wsl --distribution $Distribution --exec wslpath -w $linuxDirectory) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve WSL fixture path' }
    $path = Join-Path $windowsDirectory "config with 'spaces'.json"
    $original = [Text.Encoding]::UTF8.GetBytes('original configuration')
    $candidate = [Text.Encoding]::UTF8.GetBytes('candidate configuration')
    Write-OpenClawAtomicFile -Path $path -Bytes $original
    Write-OpenClawAtomicFile -Path $path -Bytes $candidate
    if ([IO.File]::ReadAllText($path) -ne 'candidate configuration') { throw 'Replacement failed' }
    Write-OpenClawAtomicFile -Path $path -Bytes $original
    if ([IO.File]::ReadAllText($path) -ne 'original configuration') { throw 'Rollback replacement failed' }
    $mode = ((wsl --distribution $Distribution --exec stat -c %a "$linuxDirectory/config with 'spaces'.json") -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $mode -ne '600') { throw "Unexpected file permissions: $mode" }
    if (@(Get-ChildItem -LiteralPath $windowsDirectory -Filter '*.tmp').Count -ne 0) { throw 'Temporary files were not cleaned up' }
    Write-Host 'WSL atomic creation, replacement, rollback, permissions, and cleanup passed'
} finally {
    wsl --distribution $Distribution --exec rm -rf -- $linuxDirectory
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not remove fixture $linuxDirectory" }
}
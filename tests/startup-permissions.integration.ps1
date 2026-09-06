$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'startup-helpers.ps1')

$testHome = ((wsl --exec mktemp -d /tmp/openclaw-permissions-XXXXXXXX) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $testHome -notmatch '^/tmp/openclaw-permissions-[A-Za-z0-9]+$') {
    throw 'Could not create an isolated WSL test directory'
}
try {
    $permissions = New-OpenClawPermissionCommand -HomeDir $testHome
    $dataDir = "$testHome/.openclaw"
    $testScript = @"
set -eu
mkdir -p '$dataDir/agents/test' '$dataDir/workspace'
touch '$dataDir/agents/test/auth-first.json'
chmod 755 '$dataDir' '$dataDir/agents' '$dataDir/agents/test'
chmod 644 '$dataDir/agents/test/auth-first.json'
( $permissions )
test -f '$dataDir/.permissions-v1'
test "`$(stat -c %a '$dataDir')" = 700
test "`$(stat -c %a '$dataDir/agents/test/auth-first.json')" = 600
mkdir '$dataDir/workspace/not-rescanned'
chmod 755 '$dataDir/workspace/not-rescanned'
touch '$dataDir/agents/test/auth-second.json'
chmod 644 '$dataDir/agents/test/auth-second.json'
( $permissions )
test "`$(stat -c %a '$dataDir/agents/test/auth-second.json')" = 600
test "`$(stat -c %a '$dataDir/workspace/not-rescanned')" = 755
printf 'Permission migration and targeted second-run checks passed\n'
"@
    wsl --exec timeout -k 1 20 sh -c ($testScript -replace "`r", '')
    if ($LASTEXITCODE -ne 0) { throw 'Permission integration check failed' }
} finally {
    wsl --exec rm -rf -- $testHome
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not clean temporary directory $testHome" }
}
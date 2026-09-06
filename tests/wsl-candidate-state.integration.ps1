$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'wsl-helpers.ps1')

$fixture = ((wsl --exec mktemp -d /tmp/openclaw-candidate-XXXXXXXX) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $fixture -notmatch '^/tmp/openclaw-candidate-[A-Za-z0-9]+$') { throw 'Could not create isolated fixture' }
try {
    $script:commands = @()
    function Invoke-Wsl { param($Command) $script:commands += $Command }
    Test-OpenClawCandidateConfig -CandidateImage 'fixture' -WslDataDir "$fixture/source" -HomeDir "$fixture/home"
    $command = $script:commands[1]
    if ($command -notmatch "-lc '(.*)'$") { throw 'Could not extract candidate validation shell' }
    $shell = $Matches[1].Replace('/source/', "$fixture/source/").Replace('openclaw security audit --json >/dev/null', 'true')
    $exercise = @"
set -eu
mkdir -p '$fixture/source' '$fixture/home/.openclaw'
printf '{}' > '$fixture/source/openclaw.json'
$shell
test -f '$fixture/home/.openclaw/openclaw.json'
test ! -f '$fixture/home/.openclaw/state/openclaw.sqlite'
mkdir -p '$fixture/source/state'
printf 'database-fixture' > '$fixture/source/state/openclaw.sqlite'
printf 'wal-fixture' > '$fixture/source/state/openclaw.sqlite-wal'
$shell
cmp '$fixture/source/state/openclaw.sqlite' '$fixture/home/.openclaw/state/openclaw.sqlite'
cmp '$fixture/source/state/openclaw.sqlite-wal' '$fixture/home/.openclaw/state/openclaw.sqlite-wal'
printf 'Fresh and existing candidate-state setup passed\n'
"@
    wsl --exec timeout -k 1 15 sh -c ($exercise -replace "`r", '')
    if ($LASTEXITCODE -ne 0) { throw 'Candidate-state integration failed' }
} finally {
    wsl --exec rm -rf -- $fixture
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not clean fixture $fixture" }
}
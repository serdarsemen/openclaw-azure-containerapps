$repoRoot = Split-Path $PSScriptRoot -Parent
$helperPath = Join-Path $repoRoot 'startup-helpers.ps1'
if (Test-Path $helperPath) { . $helperPath }

Describe 'Startup permissions' {
    It 'guards the full scan with a versioned migration marker' {
        $command = New-OpenClawPermissionCommand -HomeDir '/home/node'
        $command | Should Match 'if \[ ! -f .*/\.permissions-v1'
        $command | Should Match '! -perm 700'
        $command | Should Match '! -perm 600'
        $command | Should Match 'auth-\*\.json'
        $command | Should Match 'sessions\.json'
    }

    It 'retains targeted credential checks after migration' {
        $command = New-OpenClawPermissionCommand -HomeDir '/home/openclaw'
        $command | Should Match '/credentials'
        $command | Should Match '/agents'
        $command | Should Match '/identity'
        $command | Should Match '/devices'
        $command | Should Match '-prune'
    }
}

Describe 'Update maintenance' {
    It 'only compacts SQLite when explicitly requested' {
        $source = Get-Content (Join-Path $repoRoot 'update-openclaw-wsl.ps1') -Raw
        $source | Should Match '\[switch\]\s*\$CompactState'
        $source | Should Match '-Compact:\$CompactState'
    }
}
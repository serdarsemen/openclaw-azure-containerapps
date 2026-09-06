$repoRoot = Split-Path $PSScriptRoot -Parent
$helperPath = Join-Path $repoRoot 'startup-helpers.ps1'
if (Test-Path $helperPath) { . $helperPath }

Describe 'Startup permissions' {
    It 'excludes only the restart monitor diagnostics from the full migration' {
        $command = New-OpenClawPermissionCommand -HomeDir '/home/node'
        $command | Should Match "-path '/home/node/.openclaw/logs/restarts' -prune -o"
    }

    It 'creates restart diagnostics with private permissions' {
        $monitor = Get-Content (Join-Path $repoRoot 'scripts/openclaw-restart-monitor.sh') -Raw
        $monitor | Should Match '(?m)^umask 077$'
    }

    It 'does not swallow failures or short-circuit the sensitive checks' {
        $command = New-OpenClawPermissionCommand -HomeDir '/home/node'
        $command.EndsWith('|| true') | Should Be $false
        $command | Should Match 'permission_status'
    }
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
function New-OpenClawPermissionCommand {
    param([Parameter(Mandatory)] [ValidatePattern('^/[A-Za-z0-9_/-]+$')] [string] $HomeDir)

    $dataDir = "$HomeDir/.openclaw"
    $marker = "$dataDir/.permissions-v1"
    $permissions = "\( -type d ! -perm 700 -exec chmod 700 {} + \) -o \( -type f \( -name 'auth-*.json' -o -name 'sessions.json' -o -name 'openclaw.json' \) ! -perm 600 -exec chmod 600 {} + \)"
    $commands = @(
        "(if [ ! -f '$marker' ]; then find '$dataDir' -path '$dataDir/logs/restarts' -prune -o $permissions && (touch '$marker' && chmod 600 '$marker' || printf 'Permission marker could not be saved\n' >&2); fi)",
        "find '$dataDir' -maxdepth 1 $permissions"
    )
    foreach ($directory in @('credentials', 'identity', 'devices', 'agents')) {
        $path = "$dataDir/$directory"
        $commands += "(if [ -d '$path' ]; then find '$path' \( -name node_modules -o -name .git -o -name compile-cache \) -prune -o $permissions; fi)"
    }
    return '( permission_status=0; ' + (($commands | ForEach-Object { "( $_ ) || permission_status=1" }) -join '; ') + '; exit "$permission_status" )'
}
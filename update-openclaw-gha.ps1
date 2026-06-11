# ---------------------------------------------------------------------------
# update-openclaw-gha.ps1 — Update the OpenClaw GitHub Actions runtime
#
# Counterpart to update-openclaw-wsl.ps1 for the serverless runtime. Preserves
# everything already configured and only changes what you pass explicitly:
#
#   - Secrets (Groq key, gateway token, Telegram) are left untouched unless a
#     new value is supplied (gh cannot read existing secret values, so omitting
#     a parameter simply leaves the stored secret in place).
#   - Variables (drive mode, sidecar toggles) are only updated when specified.
#   - The seed archive is rebuilt from your local data dir and pushed (unless
#     -SkipSeed), refreshing the bootstrap state used on the next cache miss.
#   - A fresh workflow run is triggered (unless -NoTrigger).
#
# Note: OpenClaw itself updates every tick — the workflow runs `npm i -g
# openclaw@latest` on each run — so there is no image to rebuild. The seed only
# affects a *cache miss*; to force the runtime to adopt a refreshed seed, pass
# -ResetState to clear the cached ~/.openclaw state first.
#
# Prerequisites: deployed via deploy-openclaw-gha.ps1; gh authenticated; git/tar.
#
# Parameters:
#   -Repo <owner/name>      target repo (default: auto-detected via gh)
#   -DataDir <path>         OpenClaw data dir to re-seed from (default: ./openclaw-data)
#   -SeedPath <path>        seed archive path (default: ./seed/openclaw-seed.tar.gz)
#   -GroqApiKey <key>       rotate the GROQ_API_KEY secret
#   -TelegramBotToken <t>   rotate the TELEGRAM_BOT_TOKEN secret
#   -TelegramChatId <id>    rotate the TELEGRAM_CHAT_ID secret
#   -GatewayToken <token>   rotate the OPENCLAW_GATEWAY_TOKEN secret
#   -DriveMode <mode>       change OPENCLAW_GHA_DRIVE (manual|scheduler)
#   -EnableRedis            set OPENCLAW_ENABLE_REDIS=true
#   -DisableRedis           set OPENCLAW_ENABLE_REDIS=false
#   -EnableSearXNG          set OPENCLAW_ENABLE_SEARXNG=true
#   -DisableSearXNG         set OPENCLAW_ENABLE_SEARXNG=false
#   -SkipSeed               do not rebuild/push the seed archive
#   -NoPush                 rebuild the seed but do not commit/push it
#   -ResetState             delete the cached ~/.openclaw state (forces re-seed)
#   -NoTrigger              do not trigger a workflow run after updating
#   -Watch                  stream the triggered run to completion
#
# Usage:
#   .\update-openclaw-gha.ps1                                  # re-seed + run
#   .\update-openclaw-gha.ps1 -GroqApiKey gsk_...              # rotate Groq key
#   .\update-openclaw-gha.ps1 -DriveMode scheduler             # switch drive mode
#   .\update-openclaw-gha.ps1 -DisableSearXNG                  # turn off SearXNG
#   .\update-openclaw-gha.ps1 -ResetState                      # adopt a fresh seed
#   .\update-openclaw-gha.ps1 -SkipSeed -NoTrigger             # vars/secrets only
# ---------------------------------------------------------------------------
param(
    [string] $Repo                  = "",
    [string] $DataDir               = "openclaw-data",
    [string] $SeedPath              = "seed/openclaw-seed.tar.gz",
    [string] $GroqApiKey            = "",
    [string] $TelegramBotToken      = "",
    [string] $TelegramChatId        = "",
    [string] $GatewayToken          = "",
    [ValidateSet("manual", "scheduler")]
    [string] $DriveMode             = "",
    [switch] $EnableRedis,
    [switch] $DisableRedis,
    [switch] $EnableSearXNG,
    [switch] $DisableSearXNG,
    [switch] $SkipSeed,
    [switch] $NoPush,
    [switch] $ResetState,
    [switch] $NoTrigger,
    [switch] $Watch
)

$ErrorActionPreference = "Stop"

if ($EnableRedis   -and $DisableRedis)   { throw "Pass only one of -EnableRedis / -DisableRedis." }
if ($EnableSearXNG -and $DisableSearXNG) { throw "Pass only one of -EnableSearXNG / -DisableSearXNG." }

# Load shared gh-CLI helpers (Test-GhCli, Resolve-GhRepo, Set-RepoSecret,
# Set-RepoVariable, New-OpenClawSeedArchive, Publish-SeedArchive, Invoke-WorkflowRun).
. "$PSScriptRoot/gha-helpers.ps1"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan
Test-GhCli
$Repo = Resolve-GhRepo -Repo $Repo

# Verify the runtime was deployed (the workflow must exist on the repo).
$wf = gh workflow list --repo $Repo 2>$null | Select-String -SimpleMatch "OpenClaw Runtime"
if (-not $wf) {
    throw "Workflow 'OpenClaw Runtime' not found on $Repo. Run deploy-openclaw-gha.ps1 first."
}
Write-Host "  Workflow 'OpenClaw Runtime': found" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 1: Rotate secrets (only those explicitly supplied)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 1: Secrets (rotate on demand) ===" -ForegroundColor Cyan
Set-RepoSecret -Name "OPENCLAW_GATEWAY_TOKEN" -Value $GatewayToken     -Repo $Repo
Set-RepoSecret -Name "GROQ_API_KEY"           -Value $GroqApiKey       -Repo $Repo
Set-RepoSecret -Name "TELEGRAM_BOT_TOKEN"     -Value $TelegramBotToken -Repo $Repo
Set-RepoSecret -Name "TELEGRAM_CHAT_ID"       -Value $TelegramChatId   -Repo $Repo
if (-not ($GatewayToken -or $GroqApiKey -or $TelegramBotToken -or $TelegramChatId)) {
    Write-Host "  No secret overrides passed — existing secrets preserved." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 2: Update variables (only those explicitly supplied)
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 2: Variables ===" -ForegroundColor Cyan
Set-RepoVariable -Name "OPENCLAW_GHA_DRIVE" -Value $DriveMode -Repo $Repo
if ($EnableRedis)    { Set-RepoVariable -Name "OPENCLAW_ENABLE_REDIS"   -Value "true"  -Repo $Repo }
if ($DisableRedis)   { Set-RepoVariable -Name "OPENCLAW_ENABLE_REDIS"   -Value "false" -Repo $Repo }
if ($EnableSearXNG)  { Set-RepoVariable -Name "OPENCLAW_ENABLE_SEARXNG" -Value "true"  -Repo $Repo }
if ($DisableSearXNG) { Set-RepoVariable -Name "OPENCLAW_ENABLE_SEARXNG" -Value "false" -Repo $Repo }
if (-not ($DriveMode -or $EnableRedis -or $DisableRedis -or $EnableSearXNG -or $DisableSearXNG)) {
    Write-Host "  No variable changes passed — existing variables preserved." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 3: Rebuild and push the seed archive
# ---------------------------------------------------------------------------
if (-not $SkipSeed) {
    Write-Host "`n=== Step 3: Refresh seed archive ===" -ForegroundColor Cyan
    $built = New-OpenClawSeedArchive -DataDir $DataDir -SeedPath $SeedPath
    if ($built -and -not $NoPush) {
        Publish-SeedArchive -SeedPath $SeedPath -Message "Update OpenClaw seed"
    } elseif ($built) {
        Write-Host "  Seed rebuilt (not pushed — -NoPush set)." -ForegroundColor Gray
    }
} else {
    Write-Host "`n=== Step 3: Seed archive (skipped) ===" -ForegroundColor Cyan
    Write-Host "  -SkipSeed set — seed left unchanged." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 4: Optionally clear the cached state so a refreshed seed takes effect
# ---------------------------------------------------------------------------
if ($ResetState) {
    Write-Host "`n=== Step 4: Reset cached state ===" -ForegroundColor Cyan
    Write-Host "  Deleting Actions caches with key prefix 'openclaw-state'..." -ForegroundColor Gray
    $caches = gh cache list --repo $Repo --key "openclaw-state" --json id,key 2>$null | ConvertFrom-Json
    if (-not $caches) {
        Write-Host "  No matching caches found." -ForegroundColor Gray
    } else {
        foreach ($c in $caches) {
            gh cache delete $c.id --repo $Repo 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Deleted cache: $($c.key)" -ForegroundColor Green
            } else {
                Write-Warning "  Failed to delete cache: $($c.key)"
            }
        }
        Write-Host "  Next run will re-seed ~/.openclaw from the seed archive." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Step 5: Trigger a fresh run
# ---------------------------------------------------------------------------
if (-not $NoTrigger) {
    Write-Host "`n=== Step 5: Trigger run ===" -ForegroundColor Cyan
    Invoke-WorkflowRun -Repo $Repo -DriveInput $DriveMode -Watch:$Watch
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Update complete ===" -ForegroundColor Green
Write-Host "  Repo:     $Repo" -ForegroundColor Gray
Write-Host "  Workflow: .github/workflows/openclaw-runtime.yml (every 15 min)" -ForegroundColor Gray
if ($NoTrigger) {
    Write-Host "  Trigger a run when ready: gh workflow run 'OpenClaw Runtime' --repo $Repo" -ForegroundColor Gray
}
if ($GatewayToken) {
    Write-Host "`n  New gateway token (store securely): $GatewayToken" -ForegroundColor Yellow
}

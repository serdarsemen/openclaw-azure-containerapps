# ---------------------------------------------------------------------------
# deploy-openclaw-gha.ps1 — Deploy OpenClaw as a serverless GitHub Actions runtime
#
# The GitHub Actions runtime (.github/workflows/openclaw-runtime.yml) replaces
# the long-lived WSL/ACA/AKS Gateway with a cron tick that runs every 15 minutes
# on a free Ubuntu runner. There is no image to build and no container to run —
# "deploying" means wiring up the repository and kicking off the first run:
#
#   1. Sets the repository secrets the workflow consumes (Groq key, gateway
#      token, Telegram bot token/chat id).
#   2. Sets repository variables (drive mode, seed path, Redis/SearXNG toggles).
#   3. Builds a seed archive (seed/openclaw-seed.tar.gz) from a local OpenClaw
#      data directory so the first run starts from your existing state
#      (config, skills, memory, sessions, cron jobs).
#   4. Optionally commits + pushes the seed and triggers the first run.
#
# State persists between runs via the Actions cache (see the workflow). The seed
# archive only bootstraps the *first* run (cache miss); after that the cache wins.
# The Redis and SearXNG sidecars run automatically on the runner (parity with the
# WSL runtime) and can be toggled with -DisableRedis / -DisableSearXNG.
#
# SECURITY: the seed archive and the Actions cache can contain credentials and
# session data. Only use a PRIVATE repository.
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated: gh auth login
#   - git on PATH, run from inside the cloned repo (or pass -Repo owner/name)
#   - tar on PATH (ships with Windows 10/11 and all Linux/macOS)
#
# Parameters:
#   -Repo <owner/name>      target repo (default: auto-detected via gh)
#   -DataDir <path>         OpenClaw data dir to seed from (default: ./openclaw-data)
#   -SeedPath <path>        output seed archive (default: ./seed/openclaw-seed.tar.gz)
#   -GroqApiKey <key>       set the GROQ_API_KEY secret
#   -TelegramBotToken <t>   set the TELEGRAM_BOT_TOKEN secret
#   -TelegramChatId <id>    set the TELEGRAM_CHAT_ID secret
#   -GatewayToken <token>   set a fixed OPENCLAW_GATEWAY_TOKEN secret
#   -GenerateGatewayToken   generate a 256-bit gateway token and set it
#   -DriveMode <mode>       set OPENCLAW_GHA_DRIVE variable (manual|scheduler)
#   -DisableRedis           set OPENCLAW_ENABLE_REDIS=false (default: sidecar on)
#   -DisableSearXNG         set OPENCLAW_ENABLE_SEARXNG=false (default: sidecar on)
#   -SkipSeed               do not build a seed archive
#   -PushSeed               git add -f / commit / push the seed archive
#   -Trigger                trigger the first workflow run after setup
#   -Watch                  with -Trigger, stream the run to completion
#
# Usage:
#   .\deploy-openclaw-gha.ps1 -GenerateGatewayToken -GroqApiKey gsk_... `
#       -TelegramBotToken 123:abc -TelegramChatId 2093604311 -PushSeed -Trigger
#   .\deploy-openclaw-gha.ps1 -SkipSeed -DriveMode scheduler
#   .\deploy-openclaw-gha.ps1 -DataDir .\openclaw-data -Repo me/openclaw-gha
# ---------------------------------------------------------------------------
param(
    [string] $Repo                  = "",
    [string] $DataDir               = "openclaw-data",
    [string] $SeedPath              = "seed/openclaw-seed.tar.gz",
    [string] $GroqApiKey            = "",
    [string] $TelegramBotToken      = "",
    [string] $TelegramChatId        = "",
    [string] $GatewayToken          = "",
    [switch] $GenerateGatewayToken,
    [ValidateSet("manual", "scheduler")]
    [string] $DriveMode             = "",
    [switch] $DisableRedis,
    [switch] $DisableSearXNG,
    [switch] $SkipSeed,
    [switch] $PushSeed,
    [switch] $Trigger,
    [switch] $Watch
)

$ErrorActionPreference = "Stop"

# Load shared gh-CLI helpers (Test-GhCli, Resolve-GhRepo, Test-GhRepoPrivacy,
# Set-RepoSecret, Set-RepoVariable, New-GatewayToken, New-OpenClawSeedArchive,
# Publish-SeedArchive, Invoke-WorkflowRun).
. "$PSScriptRoot/gha-helpers.ps1"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan
Test-GhCli
$Repo = Resolve-GhRepo -Repo $Repo
Test-GhRepoPrivacy -Repo $Repo

# ---------------------------------------------------------------------------
# Step 1: Gateway token
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 1: Gateway token ===" -ForegroundColor Cyan
if ($GenerateGatewayToken -and -not $GatewayToken) {
    $GatewayToken = New-GatewayToken
    Write-Host "  Generated 256-bit gateway token: $GatewayToken" -ForegroundColor Yellow
}
Set-RepoSecret -Name "OPENCLAW_GATEWAY_TOKEN" -Value $GatewayToken -Repo $Repo
if (-not $GatewayToken) {
    Write-Host "  (no gateway token set — the workflow will auto-generate one per run)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 2: API keys and Telegram notification secrets
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 2: Secrets ===" -ForegroundColor Cyan
Set-RepoSecret -Name "GROQ_API_KEY"       -Value $GroqApiKey       -Repo $Repo
Set-RepoSecret -Name "TELEGRAM_BOT_TOKEN" -Value $TelegramBotToken -Repo $Repo
Set-RepoSecret -Name "TELEGRAM_CHAT_ID"   -Value $TelegramChatId   -Repo $Repo

# ---------------------------------------------------------------------------
# Step 3: Repository variables
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3: Variables ===" -ForegroundColor Cyan
Set-RepoVariable -Name "OPENCLAW_GHA_DRIVE" -Value $DriveMode -Repo $Repo
Set-RepoVariable -Name "OPENCLAW_SEED_PATH" -Value $(if ($SeedPath -ne "seed/openclaw-seed.tar.gz") { $SeedPath } else { "" }) -Repo $Repo
# Sidecars default to on (the workflow uses `vars.X || 'true'`); only set the
# variable when the user wants to turn one off.
if ($DisableRedis)    { Set-RepoVariable -Name "OPENCLAW_ENABLE_REDIS"   -Value "false" -Repo $Repo }
if ($DisableSearXNG)  { Set-RepoVariable -Name "OPENCLAW_ENABLE_SEARXNG" -Value "false" -Repo $Repo }

# ---------------------------------------------------------------------------
# Step 4: Build seed archive from a local data directory
# ---------------------------------------------------------------------------
if (-not $SkipSeed) {
    Write-Host "`n=== Step 4: Seed archive ===" -ForegroundColor Cyan
    $built = New-OpenClawSeedArchive -DataDir $DataDir -SeedPath $SeedPath
    if ($built -and $PushSeed) {
        Publish-SeedArchive -SeedPath $SeedPath -Message "Add OpenClaw seed"
    } elseif ($built) {
        Write-Host "  Commit it into your PRIVATE repo (or re-run with -PushSeed):" -ForegroundColor Gray
        Write-Host "    git add -f $SeedPath && git commit -m 'Add OpenClaw seed' && git push" -ForegroundColor Gray
    }
} else {
    Write-Host "`n=== Step 4: Seed archive (skipped) ===" -ForegroundColor Cyan
    Write-Host "  -SkipSeed set — the first run will start from a fresh state." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 5: Trigger the first run
# ---------------------------------------------------------------------------
if ($Trigger) {
    Write-Host "`n=== Step 5: Trigger first run ===" -ForegroundColor Cyan
    Invoke-WorkflowRun -Repo $Repo -DriveInput $DriveMode -Watch:$Watch
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Deployment complete ===" -ForegroundColor Green
Write-Host "  Repo:      $Repo" -ForegroundColor Gray
Write-Host "  Workflow:  .github/workflows/openclaw-runtime.yml (every 15 min)" -ForegroundColor Gray
Write-Host "  Sidecars:  Redis $([string]::Format('{0}', $(if ($DisableRedis) { 'disabled' } else { 'enabled' }))), SearXNG $([string]::Format('{0}', $(if ($DisableSearXNG) { 'disabled' } else { 'enabled' })))" -ForegroundColor Gray
if (-not $Trigger) {
    Write-Host "  Next:" -ForegroundColor Gray
    Write-Host "    - Ensure the workflow is on your DEFAULT branch (schedules only run there)." -ForegroundColor Gray
    if (-not $PushSeed -and -not $SkipSeed) {
        Write-Host "    - Push the seed (private repo): git add -f $SeedPath && git commit -m seed && git push" -ForegroundColor Gray
    }
    Write-Host "    - Trigger a first run: gh workflow run 'OpenClaw Runtime' --repo $Repo" -ForegroundColor Gray
    Write-Host "    - Watch it:            gh run watch --repo $Repo" -ForegroundColor Gray
}
if ($GatewayToken) {
    Write-Host "`n  Gateway token (store securely): $GatewayToken" -ForegroundColor Yellow
}

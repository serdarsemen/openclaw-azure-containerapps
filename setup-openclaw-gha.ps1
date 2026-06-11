# ---------------------------------------------------------------------------
# setup-openclaw-gha.ps1 — Configure the OpenClaw GitHub Actions runtime
#
# The GitHub Actions runtime (.github/workflows/openclaw-runtime.yml) replaces
# the long-lived WSL/ACA/AKS Gateway with a serverless cron tick that runs every
# 15 minutes on a free Ubuntu runner. This script wires it up:
#
#   1. Sets the repository secrets the workflow consumes (Groq key, gateway
#      token, Telegram bot token/chat id).
#   2. Optionally builds a seed archive (seed/openclaw-seed.tar.gz) from a local
#      OpenClaw data directory so the first run starts from your existing state
#      (config, skills, memory, sessions, cron jobs).
#   3. Optionally sets repository variables (drive mode, seed path).
#
# State persists between runs via the Actions cache (see the workflow). The seed
# archive only bootstraps the *first* run (cache miss); after that the cache wins.
#
# SECURITY: the seed archive and the Actions cache can contain credentials and
# session data. Only commit seed/openclaw-seed.tar.gz to a PRIVATE repository.
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated: gh auth login
#   - Run from inside the cloned repo (or pass -Repo owner/name)
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
#   -SkipSeed               do not build a seed archive
#
# Usage:
#   .\setup-openclaw-gha.ps1 -GenerateGatewayToken -GroqApiKey gsk_... `
#       -TelegramBotToken 123:abc -TelegramChatId 2093604311
#   .\setup-openclaw-gha.ps1 -SkipSeed -DriveMode scheduler
#   .\setup-openclaw-gha.ps1 -DataDir .\openclaw-data -Repo me/openclaw-gha
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
    [switch] $SkipSeed
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host "`n=== Pre-flight checks ===" -ForegroundColor Cyan

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found. Install it from https://cli.github.com/ and run 'gh auth login'."
}
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated. Run: gh auth login" }
Write-Host "  gh: OK" -ForegroundColor Green

# Resolve the target repository
if (-not $Repo) {
    $Repo = (gh repo view --json nameWithOwner -q ".nameWithOwner" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $Repo) {
        throw "Could not auto-detect the repository. Pass -Repo owner/name."
    }
}
Write-Host "  Repo: $Repo" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Helper: set a repository secret (skips when value is empty)
# ---------------------------------------------------------------------------
function Set-RepoSecret {
    param([string] $Name, [string] $Value)
    if (-not $Value) { return }
    $Value | gh secret set $Name --repo $Repo --body -
    if ($LASTEXITCODE -ne 0) { throw "Failed to set secret $Name" }
    Write-Host "  secret set: $Name" -ForegroundColor Green
}

function Set-RepoVariable {
    param([string] $Name, [string] $Value)
    if (-not $Value) { return }
    gh variable set $Name --repo $Repo --body $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set variable $Name" }
    Write-Host "  variable set: $Name = $Value" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 1: Gateway token
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 1: Gateway token ===" -ForegroundColor Cyan
if ($GenerateGatewayToken -and -not $GatewayToken) {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $GatewayToken = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    Write-Host "  Generated 256-bit gateway token: $GatewayToken" -ForegroundColor Yellow
}
Set-RepoSecret -Name "OPENCLAW_GATEWAY_TOKEN" -Value $GatewayToken
if (-not $GatewayToken) {
    Write-Host "  (no gateway token set — the workflow will auto-generate one per run)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 2: API keys and Telegram notification secrets
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 2: Secrets ===" -ForegroundColor Cyan
Set-RepoSecret -Name "GROQ_API_KEY"       -Value $GroqApiKey
Set-RepoSecret -Name "TELEGRAM_BOT_TOKEN" -Value $TelegramBotToken
Set-RepoSecret -Name "TELEGRAM_CHAT_ID"   -Value $TelegramChatId

# ---------------------------------------------------------------------------
# Step 3: Repository variables
# ---------------------------------------------------------------------------
Write-Host "`n=== Step 3: Variables ===" -ForegroundColor Cyan
Set-RepoVariable -Name "OPENCLAW_GHA_DRIVE" -Value $DriveMode
Set-RepoVariable -Name "OPENCLAW_SEED_PATH" -Value $(if ($SeedPath -ne "seed/openclaw-seed.tar.gz") { $SeedPath } else { "" })

# ---------------------------------------------------------------------------
# Step 4: Build seed archive from a local data directory
# ---------------------------------------------------------------------------
if (-not $SkipSeed) {
    Write-Host "`n=== Step 4: Seed archive ===" -ForegroundColor Cyan
    if (-not (Test-Path $DataDir)) {
        Write-Host "  Data dir '$DataDir' not found — skipping seed build." -ForegroundColor Yellow
        Write-Host "  Pass -DataDir <path> (e.g. a WSL backup) or -SkipSeed to silence this." -ForegroundColor Gray
    } else {
        $seedDir = Split-Path -Parent $SeedPath
        if ($seedDir -and -not (Test-Path $seedDir)) {
            New-Item -ItemType Directory -Path $seedDir | Out-Null
        }

        # Exclude volatile / runtime-only paths that should not seed CI state.
        $excludes = @(
            "--exclude=./logs",
            "--exclude=./delivery-queue",
            "--exclude=./session-delivery-queue",
            "--exclude=./appendonlydir",
            "--exclude=./dump.rdb",
            "--exclude=./*.tmp",
            "--exclude=./*.bak",
            "--exclude=./openclaw.json.clobbered.*"
        )

        Write-Host "  Building seed archive from '$DataDir'..." -ForegroundColor Gray
        # Archive the *contents* of $DataDir at the top level so the workflow can
        # extract with: tar xzf seed.tar.gz -C ~/.openclaw
        & tar -czf $SeedPath @excludes -C $DataDir .
        if ($LASTEXITCODE -ne 0) { throw "tar failed to build seed archive" }

        $size = "{0:N1} MB" -f ((Get-Item $SeedPath).Length / 1MB)
        Write-Host "  Seed archive created: $SeedPath ($size)" -ForegroundColor Green
        Write-Host "  ⚠  This archive may contain credentials/sessions." -ForegroundColor Yellow
        Write-Host "     Commit it ONLY in a private repo:" -ForegroundColor Yellow
        Write-Host "       git add -f $SeedPath && git commit -m 'Add OpenClaw seed' && git push" -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "  Repo:      $Repo" -ForegroundColor Gray
Write-Host "  Workflow:  .github/workflows/openclaw-runtime.yml (every 15 min)" -ForegroundColor Gray
Write-Host "  Next:" -ForegroundColor Gray
Write-Host "    - Ensure the workflow is on your DEFAULT branch (schedules only run there)." -ForegroundColor Gray
Write-Host "    - Trigger a first run: gh workflow run 'OpenClaw Runtime' --repo $Repo" -ForegroundColor Gray
Write-Host "    - Watch it:           gh run watch --repo $Repo" -ForegroundColor Gray
if ($GatewayToken) {
    Write-Host "`n  Gateway token (store securely): $GatewayToken" -ForegroundColor Yellow
}

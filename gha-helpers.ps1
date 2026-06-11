# ---------------------------------------------------------------------------
# gha-helpers.ps1 — Shared helpers for the OpenClaw GitHub Actions runtime
#
# Dot-sourced by deploy-openclaw-gha.ps1 and update-openclaw-gha.ps1. Mirrors
# the role wsl-helpers.ps1 plays for the WSL runtime: a single source of truth
# for the gh-CLI plumbing both scripts share (preflight, repo resolution,
# secret/variable management, seed archive build, commit/push, run trigger).
#
# Requires: GitHub CLI (gh) authenticated, git, and tar (ships with Win 10/11).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Confirm the GitHub CLI is installed and authenticated.
# ---------------------------------------------------------------------------
function Test-GhCli {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install it from https://cli.github.com/ and run 'gh auth login'."
    }
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI is not authenticated. Run: gh auth login" }
    Write-Host "  gh: OK" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Resolve the target repository (owner/name). Auto-detects via gh when blank.
# ---------------------------------------------------------------------------
function Resolve-GhRepo {
    param([string] $Repo)
    if (-not $Repo) {
        $Repo = (gh repo view --json nameWithOwner -q ".nameWithOwner" 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $Repo) {
            throw "Could not auto-detect the repository. Pass -Repo owner/name."
        }
    }
    Write-Host "  Repo: $Repo" -ForegroundColor Green
    return $Repo
}

# ---------------------------------------------------------------------------
# Warn if the repository is public — the seed archive and Actions cache can
# contain credentials and session data, so the runtime is private-repo only.
# ---------------------------------------------------------------------------
function Test-GhRepoPrivacy {
    param([string] $Repo)
    $visibility = (gh repo view $Repo --json visibility -q ".visibility" 2>$null)
    if ($visibility -and $visibility -ne "PRIVATE") {
        Write-Warning "Repository '$Repo' is $visibility. The seed archive and Actions cache can contain credentials/sessions — use a PRIVATE repo."
    } elseif ($visibility -eq "PRIVATE") {
        Write-Host "  Visibility: PRIVATE" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Set a repository secret (skips silently when the value is empty).
# ---------------------------------------------------------------------------
function Set-RepoSecret {
    param([string] $Name, [string] $Value, [string] $Repo)
    if (-not $Value) { return }
    $Value | gh secret set $Name --repo $Repo --body -
    if ($LASTEXITCODE -ne 0) { throw "Failed to set secret $Name" }
    Write-Host "  secret set: $Name" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Set a repository variable (skips silently when the value is empty).
# ---------------------------------------------------------------------------
function Set-RepoVariable {
    param([string] $Name, [string] $Value, [string] $Repo)
    if ($null -eq $Value -or $Value -eq "") { return }
    gh variable set $Name --repo $Repo --body $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set variable $Name" }
    Write-Host "  variable set: $Name = $Value" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Generate a 256-bit (32-byte) hex gateway token.
# ---------------------------------------------------------------------------
function New-GatewayToken {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

# ---------------------------------------------------------------------------
# Build the seed archive (seed/openclaw-seed.tar.gz) from a local data dir.
# Archives the *contents* of $DataDir at the top level so the workflow can
# extract with: tar xzf seed.tar.gz -C ~/.openclaw. Volatile/runtime-only
# paths are excluded so CI never seeds stale queues or Redis dumps.
# ---------------------------------------------------------------------------
function New-OpenClawSeedArchive {
    param([string] $DataDir, [string] $SeedPath)

    if (-not (Test-Path $DataDir)) {
        Write-Host "  Data dir '$DataDir' not found — skipping seed build." -ForegroundColor Yellow
        Write-Host "  Pass -DataDir <path> (e.g. a WSL backup) or -SkipSeed to silence this." -ForegroundColor Gray
        return $false
    }

    $seedDir = Split-Path -Parent $SeedPath
    if ($seedDir -and -not (Test-Path $seedDir)) {
        New-Item -ItemType Directory -Path $seedDir | Out-Null
    }

    $excludes = @(
        "--exclude=./logs",
        "--exclude=./delivery-queue",
        "--exclude=./session-delivery-queue",
        "--exclude=./appendonlydir",
        "--exclude=./redis-data",
        "--exclude=./dump.rdb",
        "--exclude=./*.tmp",
        "--exclude=./*.bak",
        "--exclude=./openclaw.json.clobbered.*"
    )

    Write-Host "  Building seed archive from '$DataDir'..." -ForegroundColor Gray
    & tar -czf $SeedPath @excludes -C $DataDir .
    if ($LASTEXITCODE -ne 0) { throw "tar failed to build seed archive" }

    $size = "{0:N1} MB" -f ((Get-Item $SeedPath).Length / 1MB)
    Write-Host "  Seed archive created: $SeedPath ($size)" -ForegroundColor Green
    Write-Host "  WARNING: this archive may contain credentials/sessions." -ForegroundColor Yellow
    Write-Host "           Commit it ONLY in a private repo." -ForegroundColor Yellow
    return $true
}

# ---------------------------------------------------------------------------
# Force-add, commit, and push the seed archive (seed/ is gitignored). Private
# repos only. Skips the commit when there is nothing staged.
# ---------------------------------------------------------------------------
function Publish-SeedArchive {
    param([string] $SeedPath, [string] $Message = "Update OpenClaw seed")

    if (-not (Test-Path $SeedPath)) {
        Write-Warning "Seed archive '$SeedPath' not found — nothing to push."
        return
    }
    git add -f $SeedPath
    if ($LASTEXITCODE -ne 0) { throw "git add failed for $SeedPath" }

    # Scope the staged-change check and the commit to the seed path only, so any
    # unrelated files the user already staged are never swept into this commit.
    git diff --cached --quiet -- $SeedPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Seed archive unchanged — nothing to commit." -ForegroundColor Gray
    } else {
        git commit -m $Message -- $SeedPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
        Write-Host "  Seed committed: $Message" -ForegroundColor Green
    }

    git push origin HEAD
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }
    Write-Host "  Pushed to origin." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Trigger the runtime workflow (and optionally watch it to completion).
# ---------------------------------------------------------------------------
function Invoke-WorkflowRun {
    param(
        [string] $Repo,
        [string] $WorkflowName = "OpenClaw Runtime",
        [string] $DriveInput   = "",
        [switch] $Watch
    )
    $ghArgs = @("workflow", "run", $WorkflowName, "--repo", $Repo)
    if ($DriveInput) { $ghArgs += @("-f", "drive=$DriveInput") }

    gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw "Failed to trigger workflow '$WorkflowName'. Is it on the default branch?" }
    Write-Host "  Triggered workflow: $WorkflowName" -ForegroundColor Green

    if ($Watch) {
        Write-Host "  Resolving the triggered run..." -ForegroundColor Gray
        Start-Sleep -Seconds 4   # give GitHub a moment to register the queued run
        $runId = gh run list --repo $Repo --workflow $WorkflowName --limit 1 --json databaseId -q '.[0].databaseId' 2>$null
        if ($runId) {
            Write-Host "  Watching run $runId (Ctrl+C to stop watching; the run continues)..." -ForegroundColor Gray
            gh run watch $runId --repo $Repo --exit-status
        } else {
            Write-Warning "Could not resolve the run id to watch. Check: gh run list --repo $Repo"
        }
    }
}

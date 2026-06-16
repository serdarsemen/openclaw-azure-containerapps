# OpenClaw Migration: WSL Docker → GitHub Actions

Migrate a running OpenClaw instance from a local **WSL Docker** deployment to a serverless **GitHub Actions** runtime, preserving configuration, skills, workspace files, memory, sessions, and cron jobs.

Instead of keeping a Gateway container running 24/7 on your machine, GitHub spins up a fresh Ubuntu runner **every 15 minutes**, restores the previous OpenClaw state from the Actions cache, fires any cron jobs that are due, saves the updated state back, and shuts down — typically in 2-3 minutes. Zero infrastructure cost, zero maintenance overhead.

## Architecture Comparison

| Aspect | WSL Docker (Source) | GitHub Actions (Target) |
|---|---|---|
| Process model | Long-lived Gateway container | Ephemeral 15-minute cron tick |
| State storage | Local `openclaw-data/` bind mount | Actions cache (`~/.openclaw`), seeded once |
| Container image | Locally built via `deploy-openclaw-wsl.ps1` | `npm i -g openclaw` on the runner |
| Cron execution | In-Gateway scheduler (always running) | `openclaw cron run --due` per tick |
| Redis sidecar | Yes | Yes (`redis:7-alpine`, AOF persisted in the cache) |
| SearXNG sidecar | Yes | Yes (`searxng/searxng:latest`, fed `searxng/settings.yml`) |
| Ollama | Sidecar or host | Not available — use cloud models / Groq fallbacks |
| Secrets | `docker-compose-wsl.yaml` env | GitHub repository secrets |
| Notifications | OpenClaw channels | OpenClaw channels + workflow-level Telegram step |
| Cost | Your machine, on 24/7 | Free (public repos) / included minutes (private) |

> **Heads-up — model availability.** GitHub-hosted runners have no GPU and no Ollama. Any cron job whose primary model is `ollama/*` must have a cloud `fallbacks` entry (e.g. `optillm/groq/...`, `github-copilot/...`) or it will be skipped. GitHub Copilot device auth is carried over inside the seed/cache.

## Prerequisites

- A **private** GitHub repository (the seed archive and cache can contain credentials).
- [GitHub CLI](https://cli.github.com/) installed and authenticated: `gh auth login`.
- `tar` on PATH (ships with Windows 10/11).
- A running WSL OpenClaw instance to migrate from (or a `openclaw-data/` directory).

## Step 1 — Create a Backup from the WSL Container

Use OpenClaw's own backup to capture a clean, restorable snapshot:

```powershell
# Full backup — config, credentials, workspace, skills, sessions, memory, cron
wsl docker exec openclaw openclaw backup create --output /home/node/.openclaw/ --verify

# Note the archive filename
wsl docker exec openclaw bash -c "ls -lh /home/node/.openclaw/openclaw-backup-*.tar.gz"
```

Alternatively, you can seed directly from the local `openclaw-data/` bind-mount directory that the WSL deploy script already maintains — skip to Step 3 and point `-DataDir` at it.

## Step 2 — Extract the Backup Locally (optional)

If you created a backup archive, extract it into a staging folder so the seed contains a clean `~/.openclaw` tree:

```powershell
$Stage = "openclaw-data"   # or any folder
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
wsl docker cp openclaw:/home/node/.openclaw/openclaw-backup.tar.gz ./openclaw-backup.tar.gz
tar xzf .\openclaw-backup.tar.gz -C $Stage
```

## Step 3 — Adjust Configuration for GitHub Actions

The WSL config may reference local-only endpoints (Ollama, Redis). Edit `openclaw-data/openclaw.json`:

```powershell
$configPath = Join-Path "openclaw-data" "openclaw.json"
$config = Get-Content $configPath -Raw

# GitHub-hosted runners have no Ollama — point any local Ollama URL at a no-op so
# preflight marks those models unreachable and cron falls back to cloud models.
$config = $config -replace 'http://(host\.docker\.internal|ollama|192\.168\.[0-9.]+):11434', 'http://127.0.0.1:11434'

$config | Set-Content $configPath -Encoding utf8
```

Make sure each cron job in `openclaw-data/cron/jobs.json` has a cloud model or `fallbacks` entry that works without Ollama/Redis.

## Step 4 — Configure Secrets and Build the Seed

The `deploy-openclaw-gha.ps1` helper sets repository secrets/variables and builds the seed archive from your data directory:

```powershell
.\deploy-openclaw-gha.ps1 `
    -Repo me/openclaw-gha `
    -DataDir .\openclaw-data `
    -GenerateGatewayToken `
    -GroqApiKey gsk_... `
    -TelegramBotToken 123456:ABC-DEF `
    -TelegramChatId 2093604311
```

This:
- sets `OPENCLAW_GATEWAY_TOKEN`, `GROQ_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` secrets,
- builds `seed/openclaw-seed.tar.gz` from `openclaw-data/` (excluding logs, queues, and Redis dumps).

## Step 5 — Commit the Workflow and Seed (private repo only)

The workflow only runs from the repository's **default branch**, so push it there:

```powershell
git add .github/workflows/openclaw-runtime.yml .github/scripts/run-openclaw-cron.sh deploy-openclaw-gha.ps1 update-openclaw-gha.ps1 gha-helpers.ps1
git add -f seed/openclaw-seed.tar.gz   # seed/ is gitignored — force-add into a PRIVATE repo only
git commit -m "Add OpenClaw GitHub Actions runtime + seed"
git push origin HEAD
```

> If you do **not** want to commit credentials, skip the seed and let the first run start fresh, then re-authenticate GitHub Copilot and recreate cron jobs against that instance. The cache will retain that state afterward.

## Step 6 — Trigger and Verify

```powershell
# Manually trigger the first run (the schedule then takes over every 15 min)
gh workflow run "OpenClaw Runtime" --repo me/openclaw-gha

# Watch it
gh run watch --repo me/openclaw-gha

# Inspect logs of the latest run
gh run view --log --repo me/openclaw-gha
```

A healthy tick logs `Gateway is healthy.`, fires due jobs, prints `Cron tick complete.`, and (if Telegram is configured) sends a status message. The first run extracts the seed; subsequent runs restore from the Actions cache.

## How State Persists

- Each run restores `~/.openclaw` from the most recent `openclaw-state-*` cache entry, then saves a fresh entry at the end (rolling cache key).
- On a cache miss (first run, or after a 7-day eviction), the workflow extracts `seed/openclaw-seed.tar.gz` if present.
- GitHub evicts least-recently-used caches when the repo exceeds **10 GB**, and caches untouched for **7 days** are removed. Keep the seed committed so a cache miss can always rebootstrap.

## Drive Modes

The cron tick supports two strategies (set via the `OPENCLAW_GHA_DRIVE` repo variable or the `workflow_dispatch` input):

- **`manual`** (default) — disables the periodic scheduler (`OPENCLAW_SKIP_CRON=1`) and fires due jobs explicitly with `openclaw cron run <id> --due --wait`. Deterministic, no duplicate firing.
- **`scheduler`** — lets the in-Gateway scheduler fire due jobs on its own and keeps the Gateway alive for `OPENCLAW_GHA_DWELL_SECONDS` (default 180s) before shutting down. Use this if `cron run` does not execute in your build.

## Sidecars (Redis & SearXNG)

The workflow starts the same companion services as the WSL Docker runtime, using Docker on the runner:

- **Redis** (`redis:7-alpine`) on `127.0.0.1:6379`. The host-side OpenClaw process reads `REDIS_HOST=127.0.0.1` / `REDIS_PORT=6379` (exported by the workflow). Its append-only file is mounted under the cached `~/.openclaw/redis-data`, so queue/state survives between ticks.
- **SearXNG** (`searxng/searxng:latest`) on `:8080`, fed `searxng/settings.yml` (JSON format enabled) from the checked-out repo. The seeded `searxng-search` MCP config reaches it at `http://172.17.0.1:8080` (the docker0 gateway, also reachable from the host process).

Both are on by default and can be disabled with repository variables:

| Variable | Default | Effect |
|---|---|---|
| `OPENCLAW_ENABLE_REDIS` | `true` | Set `false` to skip the Redis sidecar |
| `OPENCLAW_ENABLE_SEARXNG` | `true` | Set `false` to skip the SearXNG sidecar |

> `searxng/settings.yml` is committed in the repo (not gitignored), so SearXNG works without any extra setup. Sidecars are torn down at the end of every run (gracefully, so Redis flushes its AOF before the cache is saved).

## Updating

OpenClaw itself self-updates every tick — the workflow runs `npm i -g openclaw@latest` on each run — so there is no image to rebuild. Use `update-openclaw-gha.ps1` for day-2 changes (it preserves everything you do not pass explicitly):

```powershell
.\update-openclaw-gha.ps1                          # rebuild + push seed, then trigger a run
.\update-openclaw-gha.ps1 -GroqApiKey gsk_newkey   # rotate a secret
.\update-openclaw-gha.ps1 -DriveMode scheduler     # switch drive mode
.\update-openclaw-gha.ps1 -DisableSearXNG          # toggle a sidecar off
.\update-openclaw-gha.ps1 -ResetState              # clear the cache so a fresh seed is adopted
.\update-openclaw-gha.ps1 -SkipSeed -NoTrigger     # change vars/secrets only
```

Because the Actions cache wins after the first run, a refreshed seed only takes effect on a cache miss — pass `-ResetState` to delete the `openclaw-state-*` caches and force the next run to re-seed from the archive.

## Caveats

- **Schedule precision.** GitHub may delay `schedule` triggers under load; `*/15` is best-effort, not guaranteed-exact. Runs can also be skipped during incidents.
- **Default branch only.** Scheduled triggers ignore non-default branches.
- **No always-on channels.** WhatsApp/Telegram *listeners* that need a live Gateway won't receive inbound messages between ticks. Outbound cron deliveries still work.
- **Concurrency.** The workflow uses a `concurrency` group so ticks never overlap and corrupt shared state.
- **Private repo.** Treat the seed and cache as sensitive — keep the repository private.

## Rollback

To return to WSL, your `openclaw-data/` directory is unchanged. Just redeploy:

```powershell
.\deploy-openclaw-wsl.ps1 -OllamaWindows
```

If you use `-OllamaWindows`, make sure Ollama is already running on Windows and listening on `0.0.0.0:11434` (the script does not auto-start native Ollama).

Then disable the schedule by removing the `schedule:` trigger from the workflow (or deleting `.github/workflows/openclaw-runtime.yml`).

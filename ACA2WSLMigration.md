# OpenClaw Migration: Azure Container Apps → WSL

Migrate a running OpenClaw instance from Azure Container Apps (ACA) to a local WSL Docker deployment, preserving all configuration, skills, workspace files, memory, and sessions.

## Architecture Comparison

| Aspect | ACA (Source) | WSL (Target) |
|---|---|---|
| State storage | NFS Azure File share (`openclaw-state`) mounted at `$HOME/.openclaw` | Local `openclaw-data/` folder mounted at `$HOME/.openclaw` |
| Container image | ACR-hosted `openclaw:latest` + tools layer | Locally built via `deploy-openclaw-wsl.ps1` |
| Redis | Sidecar container | Sidecar container |
| CRW | Sidecar container | Sidecar container |
| SearXNG | — | Sidecar container (metasearch backend) |
| Ollama | Separate Container App (`ca-ollama`) on internal DNS | Sidecar container (`-Ollama` flag) or explicitly selected native/external host (`-OllamaWindows`, `-OllamaWsl`, `-OllamaHost`) |
| Gateway access | External ingress on port 18789 | `localhost:18789` |

## Prerequisites

- WSL 2 with Docker Engine installed (`wsl sudo service docker start`)
- Azure CLI logged in (`az login`)
- This repo cloned locally with `openclaw-repo/` populated

## Step 1 — Identify ACA Resource Names

```powershell
$ResourceGroup = "rg-openclaw"       # adjust if using npm variant (rg-openclawnpm)
$AppName       = "ca-openclaw"       # adjust if using npm variant (ca-openclawnpm)
$DeploymentName = "main"             # "mainnpm" for npm variant

# Get the storage account name from Bicep outputs
$StorageAccount = az deployment group show `
    --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.storageAccountName.value" -o tsv

# Get the environment name
$EnvName = (az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.managedEnvironmentId" -o tsv).Split("/")[-1]

Write-Host "Storage: $StorageAccount  Environment: $EnvName"
```

## Step 2 — Create Backup from ACA Container

### Option A — Use `openclaw backup` inside the running container (recommended)

Open a console session into the running ACA container:

```powershell
az containerapp exec --name $AppName --resource-group $ResourceGroup --command bash
```

Inside the container:

```bash
# Full backup — config, credentials, workspace, skills, sessions, memory
openclaw backup create --output /home/node/.openclaw/ --verify

# Note the archive filename (e.g., openclaw-backup-2026-04-21T120000.tar.gz)
ls -lh /home/node/.openclaw/openclaw-backup-*.tar.gz
```

### Option B — Direct NFS share copy (if exec is unavailable)

Mount or access the NFS file share directly. The share is:
- Storage account: `stopenclaw<unique-hash>` (the `$StorageAccount` value from Step 1)
- Share name: `openclaw-state`
- Contains the entire `~/.openclaw/` tree

```powershell
# List share contents to verify
az storage file list --account-name $StorageAccount --share-name openclaw-state `
    --output table --auth-mode login
```

## Step 3 — Download Backup to Local Machine

### From Option A (backup archive)

```powershell
# Copy the archive out of the container via the NFS share
# The backup archive is at: <share>/openclaw-backup-*.tar.gz
$BackupFile = "openclaw-backup.tar.gz"

az storage file download --account-name $StorageAccount `
    --share-name openclaw-state --path $BackupFile `
    --dest ./tmp/$BackupFile --auth-mode login
```

### From Option B (full directory)

```powershell
# Download the entire share contents recursively
az storage file download-batch --account-name $StorageAccount `
    --source openclaw-state --destination ./tmp/aca-state `
    --auth-mode login
```

## Step 4 — Prepare the WSL Data Directory

```powershell
# Create the local data directory (deploy script default: ./openclaw-data/)
$DataDir = Join-Path $PSScriptRoot "openclaw-data"
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir }
```

### From Option A (backup archive)

```powershell
# Extract the backup archive into the data directory
Copy-Item ./tmp/openclaw-backup.tar.gz $DataDir/
wsl tar xzf openclaw-data/openclaw-backup.tar.gz -C openclaw-data/
Remove-Item $DataDir/openclaw-backup.tar.gz
```

### From Option B (full directory)

```powershell
# Copy downloaded state into the data directory
Copy-Item -Recurse ./tmp/aca-state/* $DataDir/
```

### Verify Key Files Exist

```powershell
# These files must be present for a working restore
$required = @(
    "openclaw.json",
    "workspace/AGENTS.md"
)
foreach ($f in $required) {
    $path = Join-Path $DataDir $f
    if (Test-Path $path) {
        Write-Host "  OK: $f" -ForegroundColor Green
    } else {
        Write-Host "  MISSING: $f" -ForegroundColor Red
    }
}

# Show all top-level contents
Get-ChildItem $DataDir | Format-Table Name, LastWriteTime, Length
```

## Step 5 — Adjust Configuration for WSL

The ACA config may reference Azure-internal endpoints. Update `openclaw.json`:

```powershell
$configPath = Join-Path $DataDir "openclaw.json"
$config = Get-Content $configPath -Raw

# Replace ACA Ollama internal FQDN with WSL-appropriate address
# ACA uses: http://ca-ollama.internal.<env-domain>
# WSL with -Ollama sidecar uses: http://ollama:11434
# WSL with -OllamaHost uses: http://host.docker.internal:11434
$config = $config -replace 'http://ca-ollama[^"]*', 'http://host.docker.internal:11434'

$config | Set-Content $configPath -Encoding utf8
Write-Host "Updated Ollama URL in openclaw.json" -ForegroundColor Green
```

> **Note:** If using the `-Ollama` sidecar flag in WSL, replace with `http://ollama:11434` instead.

> **Important:** WSL scripts do not auto-install or auto-start native Ollama. If using `-OllamaWindows`, `-OllamaWsl`, or `-OllamaHost`, start Ollama manually first and ensure it listens on `0.0.0.0:11434`.

## Step 6 — Deploy to WSL

```powershell
# Source build with external Ollama (running on Windows host)
.\deploy-openclaw-wsl.ps1 -OllamaHost http://host.docker.internal:11434

# Or: source build with Ollama on Windows host (auto-detect host IP)
# Native Ollama must already be running on Windows and listening on 0.0.0.0:11434
.\deploy-openclaw-wsl.ps1 -OllamaWindows

# Or: source build with Ollama sidecar
.\deploy-openclaw-wsl.ps1 -Ollama

# Or: npm variant with external Ollama
.\deploy-openclaw-wsl.ps1 -Npm -OllamaHost http://host.docker.internal:11434
```

The deploy script detects the existing `openclaw-data/` directory and preserves its contents. The existing `openclaw.json`, workspace, skills, memory, and sessions will be loaded by the new container on startup.

## Step 7 — Verify Migration

```powershell
# Check the container is running
wsl docker ps --filter name=openclaw

# Verify config was loaded
wsl docker exec openclaw-wsl openclaw config get gateway.controlUi

# Check workspace files are present
wsl docker exec openclaw-wsl ls -la /home/node/.openclaw/workspace/

# Verify skills
wsl docker exec openclaw-wsl openclaw skills list

# Open the Control UI
Start-Process "http://localhost:18789"
```

## Step 8 — Post-Migration Cleanup

After confirming everything works:

1. **Gateway token** — the deploy script generates a new token. If you want to keep the ACA token, copy it from the ACA secrets before migration:
   ```powershell
   # Read current token from ACA (before teardown)
   az containerapp show --name $AppName --resource-group $ResourceGroup `
       --query "properties.template.containers[0].env[?name=='OPENCLAW_GATEWAY_TOKEN'].value" -o tsv
   ```

2. **Model API keys** — keys stored in `openclaw.json` auth profiles transfer automatically. Verify providers work in the Control UI.

3. **Ollama models** — models are NOT included in the OpenClaw backup. If migrating from `ca-ollama`, you need to re-pull models:
   ```powershell
   # If using sidecar
   wsl docker exec openclaw-wsl-ollama ollama pull <model-name>

   # If using host Ollama
   ollama pull <model-name>
   ```

4. **Teardown ACA (optional)** — only after confirming the WSL instance is fully functional:
   ```powershell
   # WARNING: Irreversible — removes all Azure resources
   az group delete --name $ResourceGroup --yes --no-wait
   ```

## What Transfers Automatically

| Data | Transfers? | Location |
|---|---|---|
| `openclaw.json` (all config) | Yes | `openclaw-data/openclaw.json` |
| Auth profiles & API keys | Yes | Inside `openclaw.json` |
| Model definitions | Yes | Inside `openclaw.json` |
| AGENTS.md, SOUL.md, USER.md | Yes | `openclaw-data/workspace/` |
| Daily memory files | Yes | `openclaw-data/workspace/memory/` |
| Workspace skills | Yes | `openclaw-data/workspace/skills/` |
| Managed skills (ClawHub) | Yes | `openclaw-data/skills/` |
| Session transcripts | Yes | `openclaw-data/agents/` |
| Gateway token | No | New token generated by deploy script |
| Ollama models | No | Must re-pull on target |
| Container image layers | No | Rebuilt locally in WSL |

## Troubleshooting

| Issue | Fix |
|---|---|
| `openclaw.json` validation error on startup | ACA config may have fields the local version doesn't expect. Run `openclaw configure` inside the container to regenerate. |
| Skills not loading | Check `openclaw-data/workspace/skills/` and `openclaw-data/skills/` exist and have content. |
| Memory files missing | Verify `openclaw-data/workspace/memory/` contains `YYYY-MM-DD.md` files. |
| Ollama connection refused | Ensure Ollama is running: `ollama serve` (host) or check `-Ollama` sidecar logs: `wsl docker logs openclaw-wsl-ollama`. |
| Permission denied on data files | Fix ownership: `wsl sudo chown -R 1000:1000 openclaw-data/` (node user UID). |
| Docker not starting in WSL | Run `wsl sudo service docker start` or re-run the deploy script (auto-starts Docker). |

# Copilot Instructions — OpenClaw on Azure Container Apps

## Project overview

This repo deploys [OpenClaw](https://github.com/openclaw/openclaw) to Azure Container Apps using Bicep for infrastructure and PowerShell scripts for image build + app configuration. The deployment uses NFS-backed persistent storage, a Redis sidecar for state/queues, and GitHub Copilot as the primary LLM provider. Ollama (for local model inference) deploys separately via `deploy-ollama.ps1`.

## Repository structure

- `bicep/` — Infrastructure as Code (Bicep templates + parameter files)
  - `main.bicep` / `main.bicepparam` — Source-build variant (deployment name: `main`)
  - `mainnpm.bicep` / `mainnpm.bicepparam` — npm-install variant (deployment name: `mainnpm`)
- `images/` — Dockerfiles for extended tool images (`Dockerfile.tools`, `Dockerfile.npmtools`)
- `deploy-openclaw.ps1` / `deploy-openclawnpm.ps1` — First-time deploy scripts
- `update-openclaw.ps1` / `update-openclawnpm.ps1` — Update scripts (preserve tokens/config)
- `openclaw-repo/` — Cloned OpenClaw source (gitignored, populated at deploy time)

## Bicep conventions

- Follow Azure Cloud Adoption Framework (CAF) naming: `rg-`, `vnet-`, `snet-`, `cae-`, `ca-`, `law-`, `pep-`, `acr`, `st`.
- Use `uniqueString(resourceGroup().id)` for globally unique names (ACR, Storage). Never hardcode globally unique names.
- All resources deploy to a single resource group and region (`swedencentral` default).
- NFS is used instead of SMB because some Azure tenants enforce `allowSharedKeyAccess: false`, which blocks SMB mounts. NFS authenticates via private endpoint network rules.
- Bicep deploys a placeholder container first (Microsoft ACA quickstart image); the deploy script then swaps in the real OpenClaw image.

## PowerShell script conventions

- Scripts auto-discover resource names from Bicep deployment outputs (`az deployment group show --query`). Never hardcode resource names.
- Use `$ErrorActionPreference = "Stop"` at the top of every script.
- Check `$LASTEXITCODE` after every `az` CLI call and `throw` on failure.
- Gateway tokens are 256-bit cryptographic random values generated via `[System.Security.Cryptography.RandomNumberGenerator]`.
- Update scripts preserve existing secrets, environment variables, NFS volume mounts, and probes by reading them from the running app before generating the YAML update template.
- YAML templates for `az containerapp update` are written to temp files and cleaned up in `finally` blocks.

## Container image build

- Images build remotely via `az acr build` — no local Docker required.
- Two-step build: base OpenClaw image from source Dockerfile, then a tools layer (`Dockerfile.tools`) adding Go, GitHub CLI, Gemini CLI, and GoG CLI.
- ACR Tasks uses the classic Docker builder, so BuildKit `--mount=type=cache` directives must be stripped from the Dockerfile before building. The scripts handle this automatically.
- Set `$env:PYTHONIOENCODING = "utf-8"` before ACR builds to avoid encoding issues in Azure CLI output.

## Python ML Stack (Dockerfile.tools and Dockerfile.npmtools)

- **Installation order is critical** to prevent numpy version conflicts:
  1. scipy/statsmodels install first (they have strict numpy requirements: scipy==1.14.1, statsmodels==0.14.6)
  2. Keep pinned ML/test packages aligned across both Dockerfiles (scikit-learn==1.9.0, matplotlib==3.11.0, mplfinance==0.12.10b0, pytest-timeout==2.4.0)
  3. PyTorch installs last and adapts to the existing numpy environment
  4. This ordering prevents `numpy.testing` broken and torch import failures
- **Library preservation**: Cleanup patterns are intentionally conservative (`-maxdepth 2 -type d -name "tests"`) to avoid removing torch shared objects
- **Torch verification**: After install, verify with `python3 -c "import torch; import torch.utils.data"` to catch broken installations early

## Container Apps constraints

- Consumption tier limits: 4 vCPU / 8 GiB total per app (across all containers).
- The Redis sidecar uses 0.25 vCPU / 0.5 GiB; OpenClaw gets the remainder (default 3.75 vCPU / 7.5 GiB).
- Always validate that total CPU + memory across all containers stays within tier limits.
- Scale: `minReplicas: 1`, `maxReplicas: 1` (single-instance gateway).
- Use TCP probes for OpenClaw startup/liveness (port 18789) and Redis (port 6379).

## Ollama Startup Scripts

Five portable startup scripts automate Ollama setup + qwen3.5 model pull across all 5 deployment environments:

- **`start-ollama-qwen.ps1`** (WSL 2) — Kills any existing Ollama bound to loopback, restarts with `OLLAMA_HOST=0.0.0.0:11434`, verifies Docker connectivity, pulls qwen3.5
- **`start-ollama-windows.ps1`** (Windows native) — Starts Ollama on the Windows host (GitHub Actions, native dev machines)
- **`start-ollama-aca.ps1`** (Azure Container Apps) — Deploys Ollama as a standalone Container App with external ingress
- **`start-ollama-aks.ps1`** (Azure Kubernetes) — Deploys Ollama as a Kubernetes pod + service with liveness probes
- **`start-ollama-gha.ps1`** (GitHub Actions/Codespaces) — Cross-platform startup (auto-detects Linux/Windows/macOS, platform-specific installation)

**Key features:**
- 3-step process: start Ollama → wait for readiness (30-second timeout) → pull qwen3.5 model
- All scripts output step headers (Cyan), success messages (Green), and errors (Red)
- WSL variant includes Docker connectivity verification to catch loopback-only binding early
- Manual workaround guidance if auto-start fails
- See `OLLAMA_STARTUP_SCRIPTS_GUIDE.ps1` for comprehensive documentation and use cases

## Security best practices

- Never log or echo secrets (gateway tokens, ACR passwords) to stdout in plain text except in the final summary block.
- Store secrets as Container App secrets and reference them via `secretRef` in environment variables.
- Use private endpoints for storage access — no public blob/file endpoints.
- `allowInsecureAuth` is enabled for initial setup convenience; recommend device pairing for production hardening.
- Run `node openclaw.mjs security audit` after deployment to verify security posture.

## Code style

- PowerShell: use `Write-Host` with `-ForegroundColor` for progress output (Cyan for headers, Green for success, Gray for substeps, Yellow for tokens/warnings).
- Bicep: include descriptive `@description()` decorators on all parameters. Add a file-level comment block explaining purpose and usage.
- Dockerfiles: pin tool versions explicitly (e.g., `go1.24.1`, `gh_2.72.0`). Add header comments documenting all installed tools.
- Use heredoc-style YAML (`@"..."@`) in PowerShell for Container App update templates. Escape `$` as `` `$ `` inside heredocs when referencing shell variables at container runtime.

## Common tasks

- **Adding a new tool to the image**: Edit `images/Dockerfile.tools`. Pin the version. Add a comment in the header listing the new tool.
- **Changing default resources**: Update the `param` block in `deploy-openclaw.ps1` and the Ollama budget calculation. Verify total stays under 4 vCPU / 8 GiB.
- **Adding a new environment variable**: Add it to both the deploy and update scripts' YAML templates to ensure it persists across updates.
- **Adding a new Bicep parameter**: Add the param with `@description()`, add it to the `.bicepparam` file, and document it in the README.
- **Starting Ollama for a specific deployment**: Use the appropriate startup script: `start-ollama-qwen.ps1` (WSL), `start-ollama-aca.ps1` (Azure), etc. Scripts handle binding to 0.0.0.0 and verify connectivity.
- **Fixing numpy.testing or torch import errors**: Verify installation order in Dockerfile — scipy/statsmodels must install before PyTorch. PyTorch adapts to the existing numpy environment and prevents version conflicts.

## Do not

- Do not use SMB for storage mounts — use NFS with private endpoints.
- Do not hardcode resource names that must be globally unique — use `uniqueString()`.
- Do not use `--no-wait` on `az containerapp update` — the scripts need to verify the revision reaches Running state.
- Do not skip the Dockerfile patching step (stripping `--mount=type=cache`) for ACR builds.
- Do not add `docker` or `docker-compose` commands — all builds go through `az acr build`.
- Do not store secrets in environment variables directly — use Container App secrets with `secretRef`.
- Do not reverse the Python package installation order in Dockerfiles — scipy/statsmodels first, then PyTorch last. Reversing this causes numpy version conflicts that break torch library imports.
- Do not use aggressive cleanup patterns for test directories in Dockerfile — use `-maxdepth 2 -type d -name "test*"` instead of `-name "test*" -prune` to avoid removing torch shared object libraries.

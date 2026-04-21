# Deploy & Update OpenClaw on Azure Container Apps

Guide deployment and update workflows for OpenClaw on Azure Container Apps.

## When to Use

- User asks to deploy OpenClaw to Azure
- User asks to update/upgrade the running OpenClaw instance
- User wants to rebuild the container image
- User asks about deploy vs update script differences
- User asks about the deploy variants (source-build vs npm)

## Deployment Variants

| | Source-build (`deploy-openclaw.ps1`) | npm (`deploy-openclawnpm.ps1`) | Combined (`deploy-openclaw-ACA.ps1`) |
|---|---|---|---|
| Bicep template | `main.bicep` (deployment: `main`) | `mainnpm.bicep` (deployment: `mainnpm`) | Both (use `-Npm` switch) |
| Build method | Clone repo + Dockerfile | Inline Dockerfile + `npm i -g openclaw` | Both |
| Containers | OpenClaw + Ollama | OpenClaw + Redis + Ollama | Both |
| Default resources | 3 vCPU/6GiB + 1/2 (Ollama) | 2.75 vCPU/5.5GiB + 0.25/0.5 (Redis) + 1/2 (Ollama) | Variant-dependent |
| Home directory | `/home/node` | `/home/openclaw` | Variant-dependent |
| Tools layer | `Dockerfile.tools` | `Dockerfile.npmtools` | Variant-dependent |

## Deployment Steps (First Time)

1. **Create resource group**: `az group create --name rg-openclaw --location swedencentral`
2. **Deploy Bicep infrastructure**: `az deployment group create --resource-group rg-openclaw --template-file bicep/main.bicep --parameters bicep/main.bicepparam`
3. **Run deploy script**: `.\deploy-openclaw.ps1 -ResourceGroup rg-openclaw`
4. **Authenticate GitHub Copilot**: `az containerapp exec` then `node openclaw.mjs models auth login-github-copilot`

## Update Steps (Existing Deployment)

1. `.\update-openclaw.ps1 -ResourceGroup rg-openclaw` — pulls latest source, rebuilds image, updates app
2. Optionally pin a tag: `.\update-openclaw.ps1 -ResourceGroup rg-openclaw -Tag v2026.2.15`

Update scripts preserve:
- Gateway token (read from existing Container App secrets)
- NFS volume mounts and data at `/home/node/.openclaw`
- Environment variables and probes
- OpenClaw config and auth state

## Image Build Process

Two-step remote build via `az acr build` (no local Docker needed):

1. **Base image**: Patch Dockerfile (strip `--mount=type=cache` for ACR Tasks compatibility), build from OpenClaw source
2. **Tools layer**: Layer `Dockerfile.tools` on top, adding Go, GitHub CLI, Gemini CLI, GoG CLI

Critical: set `$env:PYTHONIOENCODING = "utf-8"` before ACR builds to avoid encoding crashes on Windows.

## Resource Limits

Consumption tier maximum: **4 vCPU / 8 GiB** total per app (all containers combined).

Always validate: `OpenClaw CPU + Ollama CPU (1.0) <= 4.0` and `OpenClaw Mem + Ollama Mem (2Gi) <= 8Gi`.

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Could not discover ACR or App name` | Wrong resource group or Bicep not deployed | Verify `az deployment group show --name main --resource-group <RG>` works |
| `Base image build failed` | Dockerfile syntax or ACR quota | Check ACR build logs with `az acr task logs` |
| `Container App update failed` | YAML syntax or resource limit exceeded | Validate YAML and check total CPU/memory |
| `Container did not reach Running state` | Image crash, probe failure, or NFS mount issue | Check `az containerapp logs show --tail 60` |

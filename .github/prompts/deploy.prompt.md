---
description: "Deploy OpenClaw to Azure Container Apps from scratch"
agent: "agent"
---

# Deploy OpenClaw to Azure Container Apps

Guide me through a full deployment of OpenClaw to Azure Container Apps.

## Prerequisites Check

1. Verify Azure CLI is installed: `az version`
2. Verify logged in: `az account show`
3. Verify resource providers are registered:
   - `Microsoft.App`
   - `Microsoft.ContainerRegistry`
   - `Microsoft.Storage`
   - `Microsoft.OperationalInsights`
   - `Microsoft.ManagedIdentity`

## Steps

1. **Create resource group** in `swedencentral` (or user-specified region)
2. **Deploy Bicep infrastructure** using `bicep/main.bicep` and `bicep/main.bicepparam`
3. **Wait for deployment** and verify the placeholder container is running
4. **Run deploy script** `.\deploy-openclaw.ps1 -ResourceGroup <rg>`
5. **Authenticate GitHub Copilot** via `az containerapp exec` and device flow
6. **Verify deployment** — check FQDN, revision state, and logs
7. **Print Control UI URL** with gateway token

After deployment, remind the user to:
- Run `node openclaw.mjs security audit` inside the container
- Consider enabling device pairing for production hardening
- Save the gateway token securely

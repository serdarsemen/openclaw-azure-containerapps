---
description: "Update an existing OpenClaw deployment to latest version"
agent: "agent"
---

# Update OpenClaw Deployment

Guide me through updating an existing OpenClaw deployment to the latest version.

## Pre-flight

1. Confirm the resource group name (default: `rg-openclaw`)
2. Verify the deployment exists: `az deployment group show --resource-group <rg> --name main`
3. Check current revision and image: `az containerapp show --name ca-openclaw --resource-group <rg> --query "{revision:properties.latestRevisionName, image:properties.template.containers[0].image}" -o table`

## Update

Run the appropriate update script:

- **Source-build variant**: `.\update-openclaw.ps1 -ResourceGroup <rg>`
- **Pin to a specific tag**: `.\update-openclaw.ps1 -ResourceGroup <rg> -Tag v2026.x.x`
- **npm variant**: `.\update-openclawnpm.ps1 -ResourceGroup <rg>`

The update script will:
1. Pull latest OpenClaw source (or checkout pinned tag)
2. Rebuild the container image remotely in ACR (~6 min)
3. Update the Container App via YAML (preserves secrets, env vars, NFS mounts, probes)

## Post-update

1. Verify new revision is running: `az containerapp revision list --name ca-openclaw --resource-group <rg> -o table`
2. Check logs for errors: `az containerapp logs show --name ca-openclaw --resource-group <rg> --tail 30`
3. Open Control UI and verify connectivity

Gateway token, config, and data on NFS are preserved across updates.

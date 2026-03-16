# Bicep Infrastructure for OpenClaw

Guide authoring and modifying Bicep templates for the OpenClaw Azure Container Apps deployment.

## When to Use

- User asks to modify infrastructure (VNet, storage, ACR, Container Apps Environment)
- User wants to add a new Bicep parameter or resource
- User asks about naming conventions or resource configuration
- User wants to understand the architecture

## Architecture

```
Resource Group (rg-openclaw)
├── VNet (vnet-openclaw, 10.1.0.0/26)
│   ├── Subnet: snet-aca   (10.1.0.0/27)  — delegated to Microsoft.App/environments
│   └── Subnet: snet-pe    (10.1.0.32/28) — private endpoint for storage
├── Storage Account (Premium FileStorage, NFS)
│   └── File Share: openclaw-state (100 GiB, NFS protocol)
├── Private Endpoint (pep-storage) + Private DNS Zone
├── Container Registry (Basic SKU, admin auth)
├── Log Analytics Workspace (law-openclaw)
├── Container Apps Environment (cae-openclaw)
│   └── NFS Storage Mount (openclawstorage)
└── Container App (ca-openclaw) — placeholder, swapped by deploy script
```

## Naming Conventions (CAF)

| Resource | Prefix | Example |
|----------|--------|---------|
| Resource group | `rg-` | `rg-openclaw` |
| Virtual network | `vnet-` | `vnet-openclaw` |
| Subnet | `snet-` | `snet-aca`, `snet-pe` |
| Container Apps Environment | `cae-` | `cae-openclaw` |
| Container App | `ca-` | `ca-openclaw` |
| Log Analytics | `law-` | `law-openclaw` |
| Private endpoint | `pep-` | `pep-storage` |
| Container Registry | `acr` | `acropenclaw{hash}` |
| Storage Account | `st` | `stopenclaw{hash}` |

Globally unique names (ACR, Storage) use `uniqueString(resourceGroup().id)` — deterministic, idempotent per resource group.

## Key Design Decisions

### NFS over SMB
Some Azure tenants enforce `allowSharedKeyAccess: false`, which silently breaks SMB mounts. NFS authenticates via network rules through the private endpoint, bypassing this restriction entirely.

### Two-Phase Deployment
Bicep deploys a placeholder container (`mcr.microsoft.com/k8se/quickstart:latest`) to verify infrastructure works (HTTPS, networking, DNS). The deploy script then swaps in the real OpenClaw image. This separates infrastructure failures from application failures.

### Storage Configuration
- Premium FileStorage with `Premium_LRS` (required for NFS)
- `supportsHttpsTrafficOnly: false` because NFS uses TCP port 2049
- `enabledProtocols: 'NFS'` on the file share
- Private endpoint + DNS zone for secure access within VNet
- Minimum share quota: 100 GiB (Premium FileStorage minimum)

## Rules for Modifying Bicep

1. **Every parameter** must have `@description()` decorator
2. **Never hardcode** globally unique names — use `uniqueString(resourceGroup().id)`
3. **Add outputs** for any resource name that deploy/update scripts need to discover
4. **Keep `dependsOn`** for DNS zone group before NFS storage mount — DNS must resolve first
5. **Template variants** must stay in sync: changes to `main.bicep` should be reflected in `mainnpm.bicep` where applicable
6. **Update `.bicepparam`** files when adding new parameters

## Outputs

Both Bicep templates expose these outputs for script auto-discovery:

```bicep
output acrName string = acr.name
output appName string = containerApp.name
output appUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
```

Scripts read these via: `az deployment group show --name main --query "properties.outputs.acrName.value"`

using 'mainnpm.bicep'

// ---------------------------------------------------------------------------
// OpenClaw on Azure — Deployment Parameters
//
// Just deploy — no names to pick. ACR and Storage names are auto-generated
// by the Bicep template using uniqueString() for global uniqueness.
//
// Usage:
//   az group create --name rg-openclaw --location swedencentral
//   az deployment group create --resource-group rg-openclaw \
//     --template-file bicep/main.bicep --parameters bicep/main.bicepparam
//
// After deploy, get the ACR name from outputs:
//   az deployment group show --resource-group rg-openclaw --name main \
//     --query "properties.outputs" -o json
// ---------------------------------------------------------------------------

param location = 'swedencentral'

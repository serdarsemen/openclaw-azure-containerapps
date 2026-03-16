# Troubleshooting OpenClaw on Azure Container Apps

Guide diagnosing and fixing issues with the OpenClaw Azure Container Apps deployment.

## When to Use

- Container is crash-looping or not starting
- NFS mount failures
- Image build or pull failures
- Connectivity or ingress issues
- Update script errors

## Diagnostic Commands

### Container Status
```powershell
# Current revision and state
az containerapp show --name ca-openclaw --resource-group rg-openclaw `
  --query "{fqdn:properties.configuration.ingress.fqdn, revision:properties.latestRevisionName, state:properties.provisioningState}" -o table

# Revision running state
$rev = az containerapp show --name ca-openclaw --resource-group rg-openclaw `
  --query "properties.latestRevisionName" -o tsv
az containerapp revision show --name ca-openclaw --revision $rev --resource-group rg-openclaw `
  --query "properties.runningState" -o tsv
```

### Logs
```powershell
# Recent console logs
az containerapp logs show --name ca-openclaw --resource-group rg-openclaw --tail 60

# System logs (startup failures, probe failures)
az containerapp logs show --name ca-openclaw --resource-group rg-openclaw --tail 60 --type system

# Ollama sidecar logs
az containerapp logs show --name ca-openclaw --resource-group rg-openclaw --tail 30 --container ollama
```

### Revision History
```powershell
az containerapp revision list --name ca-openclaw --resource-group rg-openclaw -o table
```

### Interactive Shell
```powershell
# Exec into OpenClaw container
az containerapp exec --name ca-openclaw --resource-group rg-openclaw

# Exec into Ollama sidecar
az containerapp exec --name ca-openclaw --resource-group rg-openclaw --container ollama
```

## Common Issues

### Container Crash Loop

**Symptoms**: Revision state is `Failed` or repeatedly restarting.

**Diagnosis**:
```powershell
az containerapp logs show --name ca-openclaw --resource-group rg-openclaw --tail 100 --type system
```

**Common causes**:
1. **Missing gateway token** — verify: `az containerapp secret list --name ca-openclaw --resource-group rg-openclaw -o table`
2. **NFS mount failure** — check private endpoint and DNS resolution
3. **Exceeded resource limits** — total CPU/memory across containers must be <= 4 vCPU / 8 GiB
4. **Image pull failure** — verify ACR credentials: `az acr login --name <acr> --expose-token`

### NFS Mount Failure

**Symptoms**: Container starts but `/home/node/.openclaw` is empty or mount error in logs.

**Diagnosis**:
```powershell
# Verify storage mount exists on environment
$envName = "cae-openclaw"
az containerapp env storage list --name $envName --resource-group rg-openclaw -o table

# Verify private endpoint health
az network private-endpoint show --name pep-storage --resource-group rg-openclaw `
  --query "privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status" -o tsv

# Verify DNS resolution
az network private-dns zone show --resource-group rg-openclaw `
  --name "privatelink.file.core.windows.net" --query "numberOfRecordSets" -o tsv
```

**Fixes**:
- Ensure DNS zone group exists and links to VNet
- Verify storage account NFS share exists: `az storage share-rm list --storage-account <name> -o table`
- Re-create the environment storage mount if needed

### Image Build Failure

**Symptoms**: `az acr build` exits with non-zero code.

**Common causes**:
1. **BuildKit directives not stripped** — the patching step must run before building
2. **ACR quota exceeded** — Basic tier has limited storage; prune old images
3. **Network timeout** — retry; ACR Tasks occasionally have transient failures
4. **Source Dockerfile changed** — upstream OpenClaw may add new `--mount` directives; the regex handles known patterns

**Debugging**:
```powershell
# View recent ACR build logs
az acr task logs --registry <acr> --run-id <run-id>

# List images and tags
az acr repository list --name <acr> -o table
az acr repository show-tags --name <acr> --repository openclaw -o table
```

### Ingress / HTTPS Issues

**Symptoms**: Control UI not reachable, 502 errors, TLS issues.

**Diagnosis**:
```powershell
# Verify ingress configuration
az containerapp show --name ca-openclaw --resource-group rg-openclaw `
  --query "properties.configuration.ingress" -o json

# Check FQDN resolves
az containerapp show --name ca-openclaw --resource-group rg-openclaw `
  --query "properties.configuration.ingress.fqdn" -o tsv
```

**Fixes**:
- Ensure `targetPort: 18789` matches the gateway `--port` flag
- Ensure `external: true` for public access
- Container Apps manages TLS automatically — don't configure certificates manually

### Update Script Fails to Read Secrets

**Symptoms**: `Could not read existing gateway-token secret`

**Cause**: The secret may have been deleted or the app redeployed without it.

**Fix**: Re-run the full deploy script (`deploy-openclaw.ps1`) which generates a new token.

### Ollama Not Responding

**Symptoms**: Ollama models unavailable, `OLLAMA_HOST` connection refused.

**Diagnosis**:
```powershell
# Check if Ollama container is running
az containerapp logs show --name ca-openclaw --resource-group rg-openclaw --container ollama --tail 20

# Exec into OpenClaw and test connectivity
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
curl http://localhost:11434/api/tags
```

**Fixes**:
- Verify Ollama container has resources allocated (1.0 vCPU / 2 GiB)
- Ollama liveness probe checks HTTP GET on port 11434 — if failing, the container restarts
- Model downloads require sufficient NFS space (check share quota)

## Useful Log Analytics (KQL) Queries

```kusto
// Container startup failures in the last hour
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-openclaw"
| where Log_s contains "error" or Log_s contains "fatal" or Log_s contains "ENOENT"
| project TimeGenerated, ContainerName_s, Log_s
| order by TimeGenerated desc

// Revision lifecycle events
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-openclaw"
| where Type_s == "Normal" or Type_s == "Warning"
| project TimeGenerated, Type_s, Reason_s, Log_s
| order by TimeGenerated desc
```

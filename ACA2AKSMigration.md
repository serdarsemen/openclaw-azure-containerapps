# OpenClaw Migration: Azure Container Apps → Azure Kubernetes Service (AKS)

Migrate a running OpenClaw instance from Azure Container Apps (ACA) to Azure Kubernetes Service (AKS), preserving all configuration, skills, workspace files, memory, and sessions. Ollama runs as a **separate pod** (its own `Deployment` + `Service`) in the same namespace so OpenClaw reaches it via in-cluster DNS (`http://ollama:11434`).

## Recent changes (June 2026)

- Preferred AKS path now uses `deploy-openclaw-aks.ps1` / `update-openclaw-aks.ps1` for day-0 and day-2 operations.
- Ollama on AKS remains opt-in (`-Ollama`) and deploys as a dedicated pod/service instead of a sidecar.
- Update workflow now rolls out OpenClaw by image digest for deterministic revisions.

## Architecture Comparison

| Aspect | ACA (Source) | AKS (Target) |
|---|---|---|
| State storage | NFS Azure File share (`openclaw-state`) mounted at `$HOME/.openclaw` | Azure Files (NFS) `PersistentVolume` + `PersistentVolumeClaim` mounted at `$HOME/.openclaw` |
| Container image | ACR-hosted `openclaw:latest` + tools layer | Same ACR image pulled via AKS→ACR attach (`az aks update --attach-acr`) |
| Ollama | Separate Container App (`ca-ollama`) on internal DNS | **Separate pod** (`Deployment` `ollama` + `Service` `ollama`) in the `openclaw` namespace |
| Ollama models | PV-backed on ACA | `PersistentVolumeClaim` `ollama-models` (Azure Disk) mounted at `/root/.ollama` |
| Gateway access | External ingress on port 18789 | `Service` type `LoadBalancer` (or Ingress) on port 18789 |
| Redis | Sidecar container in the same ACA | Sidecar container in the `openclaw` Pod (same lifecycle) |
| Scale | `minReplicas: 1`, `maxReplicas: 1` | `replicas: 1` (single-instance gateway) |
| Secrets | ACA secrets (`secretRef`) | Kubernetes `Secret` referenced via `envFrom` / `valueFrom.secretKeyRef` |

## Prerequisites

- Azure CLI logged in (`az login`) with owner/contributor on the target subscription
- `kubectl` installed (`az aks install-cli`)
- This repo cloned locally with `openclaw-repo/` populated
- Source ACA deployment still running (we will read secrets and state from it)

## Step 1 — Identify ACA Resource Names

```powershell
$ResourceGroup   = "rg-openclaw"     # adjust if using npm variant (rg-openclawnpm)
$AppName         = "ca-openclaw"     # adjust if using npm variant (ca-openclawnpm)
$DeploymentName  = "main"            # "mainnpm" for npm variant
$Location        = "swedencentral"

# Storage account (from Bicep outputs)
$StorageAccount = az deployment group show `
    --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.storageAccountName.value" -o tsv

# ACR login server
$AcrName = az deployment group show `
    --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.containerRegistryName.value" -o tsv
$AcrLoginServer = "$AcrName.azurecr.io"

Write-Host "Storage: $StorageAccount   ACR: $AcrLoginServer"
```

## Step 2 — Back Up OpenClaw State from ACA

### Option A — `openclaw backup` inside the running container (recommended)

```powershell
az containerapp exec --name $AppName --resource-group $ResourceGroup --command bash
```

Inside the container:

```bash
openclaw backup create --output /home/node/.openclaw/ --verify
ls -lh /home/node/.openclaw/openclaw-backup-*.tar.gz
```

### Option B — Direct NFS share copy

The share is:
- Storage account: `$StorageAccount`
- Share name: `openclaw-state`
- Contents: entire `~/.openclaw/` tree

```powershell
az storage file download-batch --account-name $StorageAccount `
    --source openclaw-state --destination ./tmp/aca-state `
    --auth-mode login
```

## Step 3 — Capture Secrets from ACA

```powershell
# Gateway token (the key secret you must preserve)
$GatewayToken = az containerapp secret show `
    --name $AppName --resource-group $ResourceGroup `
    --secret-name gateway-token --query value -o tsv

# Any provider API keys (example: groq-api-key)
$GroqKey = az containerapp secret show `
    --name $AppName --resource-group $ResourceGroup `
    --secret-name groq-api-key --query value -o tsv 2>$null
```

## Step 4 — Provision the AKS Cluster

```powershell
$AksRg        = "rg-openclaw-aks"
$AksName      = "aks-openclaw"
$NodeCount    = 2
$NodeVmSize   = "Standard_D4s_v5"   # 4 vCPU / 16 GiB — fits OpenClaw (3.5 CPU/7.0 Gi) + Redis + CRW sidecars; add Ollama separately or use larger SKU

az group create --name $AksRg --location $Location | Out-Null

az aks create `
    --resource-group $AksRg --name $AksName `
    --location $Location `
    --node-count $NodeCount --node-vm-size $NodeVmSize `
    --enable-managed-identity `
    --network-plugin azure `
    --generate-ssh-keys

# Attach the existing ACR so AKS can pull the OpenClaw image without secrets
az aks update --resource-group $AksRg --name $AksName --attach-acr $AcrName

# Fetch kubeconfig
az aks get-credentials --resource-group $AksRg --name $AksName --overwrite-existing
kubectl get nodes
```

## Step 5 — Create Namespace and Secrets

```powershell
kubectl create namespace openclaw

# Gateway token + provider keys as a Kubernetes secret
kubectl -n openclaw create secret generic openclaw-secrets `
    --from-literal=OPENCLAW_GATEWAY_TOKEN=$GatewayToken `
    --from-literal=GROQ_API_KEY=$GroqKey
```

## Step 6 — Provision Persistent Storage

### 6a. Azure Files (NFS) for OpenClaw state — reuse existing share

The existing `openclaw-state` NFS share already holds the migrated state from Step 2 (Option B) or is intact if you chose Option A and are rsync'ing into a new share. Bind AKS to it directly using a static PV.

```powershell
# Get the storage account resource ID and key (needed for NFS PV auth scoping)
$StorageRg = (az storage account show --name $StorageAccount --query resourceGroup -o tsv)
$StorageId = az storage account show --name $StorageAccount --resource-group $StorageRg --query id -o tsv

# Grant AKS kubelet identity reader on storage (NFS uses network rules, not keys)
$KubeletObjId = az aks show --resource-group $AksRg --name $AksName `
    --query identityProfile.kubeletidentity.objectId -o tsv
az role assignment create --assignee $KubeletObjId `
    --role "Storage File Data Privileged Contributor" --scope $StorageId
```

Create `openclaw-state-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: openclaw-state
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: file.csi.azure.com
    volumeHandle: openclaw-state-handle
    volumeAttributes:
      resourceGroup: "<STORAGE_RG>"
      storageAccount: "<STORAGE_ACCOUNT>"
      shareName: openclaw-state
      protocol: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-state
  namespace: openclaw
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  resources:
    requests:
      storage: 100Gi
  volumeName: openclaw-state
```

Fill placeholders and apply:

```powershell
(Get-Content openclaw-state-pv.yaml) `
  -replace '<STORAGE_RG>', $StorageRg `
  -replace '<STORAGE_ACCOUNT>', $StorageAccount |
  Set-Content openclaw-state-pv.yaml

kubectl apply -f openclaw-state-pv.yaml
```

> **Important:** The storage account's private endpoint (created by Bicep) must allow the AKS VNet. If your AKS is in a different VNet, either peer the VNets or add the AKS subnet to the storage account's network rules. A same-region public-endpoint fallback requires `allowSharedKeyAccess: true`, which the original Bicep disables — keep NFS + network rules.

### 6b. Azure Disk for Ollama models

Ollama models are large and benefit from a fast local disk. Use the default `managed-csi-premium` storage class.

Create `ollama-models-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: openclaw
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: managed-csi-premium
  resources:
    requests:
      storage: 100Gi
```

```powershell
kubectl apply -f ollama-models-pvc.yaml
```

## Step 7 — Deploy Ollama as a Separate Pod

`ollama.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: openclaw
  labels: { app: ollama }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: ollama }
  template:
    metadata:
      labels: { app: ollama }
    spec:
      containers:
        - name: ollama
          image: ollama/ollama:latest
          ports:
            - name: http
              containerPort: 11434
          env:
            - name: OLLAMA_HOST
              value: "0.0.0.0:11434"
            - name: OLLAMA_KEEP_ALIVE
              value: "24h"
          resources:
            requests: { cpu: "500m",  memory: "1Gi" }
            limits:   { cpu: "1",     memory: "2Gi" }
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
          readinessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: openclaw
spec:
  type: ClusterIP
  selector: { app: ollama }
  ports:
    - name: http
      port: 11434
      targetPort: 11434
```

```powershell
kubectl apply -f ollama.yaml
kubectl -n openclaw rollout status deploy/ollama
```

Pre-pull the models you used on ACA:

```powershell
kubectl -n openclaw exec deploy/ollama -- ollama pull llama3.1:8b
# repeat for any other models
```

In-cluster DNS makes Ollama reachable at **`http://ollama:11434`** from any pod in the `openclaw` namespace.

> **Tip:** For automated Ollama setup in AKS (environment bootstrap), use `start-ollama-aks.ps1` which deploys the pod, service, and pulls initial models in one command.

## Step 8 — Deploy OpenClaw (and Redis sidecar)

`openclaw.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw
  namespace: openclaw
  labels: { app: openclaw }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: openclaw }
  template:
    metadata:
      labels: { app: openclaw }
    spec:
      securityContext:
        fsGroup: 1000   # node user UID/GID for mounted NFS
      containers:
        - name: openclaw
          image: <ACR_LOGIN_SERVER>/openclaw:latest
          command: ["/bin/sh", "-c", "sleep infinity"]  # placeholder; replace with real entrypoint
          ports:
            - name: gateway
              containerPort: 18789
          envFrom:
            - secretRef: { name: openclaw-secrets }
          env:
            - name: OLLAMA_HOST
              value: "http://ollama:11434"
          resources:
            requests: { cpu: "2",   memory: "4Gi" }
            limits:   { cpu: "3",   memory: "6Gi" }
          volumeMounts:
            - name: state
              mountPath: /home/node/.openclaw
          startupProbe:
            tcpSocket: { port: gateway }
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            tcpSocket: { port: gateway }
            periodSeconds: 30
        - name: redis
          image: redis:7-alpine
          args: ["redis-server", "--appendonly", "yes", "--dir", "/data"]
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "250m", memory: "512Mi" }
          volumeMounts:
            - name: redis-data
              mountPath: /data
      volumes:
        - name: state
          persistentVolumeClaim:
            claimName: openclaw-state
        - name: redis-data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: openclaw
  namespace: openclaw
spec:
  type: LoadBalancer
  selector: { app: openclaw }
  ports:
    - name: gateway
      port: 18789
      targetPort: 18789
```

Substitute the ACR server, then apply:

```powershell
(Get-Content openclaw.yaml) -replace '<ACR_LOGIN_SERVER>', $AcrLoginServer |
  Set-Content openclaw.yaml

kubectl apply -f openclaw.yaml
kubectl -n openclaw rollout status deploy/openclaw
```

> **Note on command/args:** The source `ca-openclaw.yaml` uses `sleep infinity` as a placeholder pattern. Replace `command`/`args` with the actual OpenClaw entrypoint used by your image (matching what the ACA deploy scripts set post-swap).

## Step 9 — Update `openclaw.json` to Target In-Cluster Ollama

The ACA config references `http://ca-ollama.internal.<env-domain>`. Rewrite it to the AKS service DNS:

```powershell
$pod = kubectl -n openclaw get pod -l app=openclaw -o jsonpath='{.items[0].metadata.name}'

kubectl -n openclaw exec $pod -- sh -c "
  sed -i 's|http://ca-ollama[^\"]*|http://ollama:11434|g' /home/node/.openclaw/openclaw.json
"
```

Restart the pod so the new config is picked up:

```powershell
kubectl -n openclaw rollout restart deploy/openclaw
```

## Step 10 — Verify the Migration

```powershell
# Pods healthy
kubectl -n openclaw get pods -o wide

# Ollama reachable from openclaw pod
kubectl -n openclaw exec deploy/openclaw -- curl -sf http://ollama:11434/api/tags

# Workspace and skills present
kubectl -n openclaw exec deploy/openclaw -- ls /home/node/.openclaw/workspace
kubectl -n openclaw exec deploy/openclaw -- openclaw skills list

# External gateway endpoint
$GatewayIp = kubectl -n openclaw get svc openclaw -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Start-Process "http://${GatewayIp}:18789"
```

## Step 11 — Post-Migration Cleanup

1. **Confirm functionality** — run `openclaw security audit` and exercise a real session end-to-end before touching ACA.
2. **Teardown ACA (optional, irreversible):**
   ```powershell
   az group delete --name $ResourceGroup --yes --no-wait
   ```
   > Keeping the storage account intact lets the AKS PV keep serving the same data — only delete the ACA managed environment and container app if you want to reuse the storage long-term.

## What Transfers Automatically

| Data | Transfers? | Location on AKS |
|---|---|---|
| `openclaw.json` (all config) | Yes | NFS PVC `openclaw-state` at `/home/node/.openclaw/openclaw.json` |
| Auth profiles & API keys | Yes | Inside `openclaw.json` |
| Model definitions | Yes | Inside `openclaw.json` |
| AGENTS.md, SOUL.md, USER.md | Yes | `/home/node/.openclaw/workspace/` |
| Daily memory files | Yes | `/home/node/.openclaw/workspace/memory/` |
| Workspace skills | Yes | `/home/node/.openclaw/workspace/skills/` |
| Managed skills (ClawHub) | Yes | `/home/node/.openclaw/skills/` |
| Session transcripts | Yes | `/home/node/.openclaw/agents/` |
| Gateway token | **Yes** (via `openclaw-secrets` Secret) | `OPENCLAW_GATEWAY_TOKEN` env |
| Ollama models | **No** | Must re-pull via `ollama pull` into `ollama-models` PVC |
| Container image layers | Yes (same ACR) | Pulled by AKS via ACR attach |

## Troubleshooting

| Issue | Fix |
|---|---|
| `ImagePullBackOff` on openclaw pod | Re-run `az aks update --attach-acr $AcrName`; confirm kubelet identity has `AcrPull`. |
| NFS mount hangs / `permission denied` | Verify storage account network rules allow the AKS VNet/subnet, and the private endpoint is resolvable from the AKS VNet's DNS. |
| `fsGroup` not applied to NFS files | NFS ignores `fsGroup`. Fix ownership on the source side: `chown -R 1000:1000 /home/node/.openclaw` via a one-shot job. |
| OpenClaw can't reach Ollama | `kubectl -n openclaw get svc ollama`; ensure it's `ClusterIP` with endpoints. Config must use `http://ollama:11434`, not the ACA FQDN. |
| Ollama OOM on model load | Bump pod memory limits or switch node pool to a larger VM; 2 GiB is the floor for 7B models. |
| Gateway token rejected | Confirm `openclaw-secrets` contains the exact token from ACA (Step 3) and is referenced via `envFrom`. |
| `LoadBalancer` stuck pending | Check AKS has outbound + inbound LB permissions; for private clusters, use an Ingress controller (NGINX/AGIC) instead. |
| Model pulls lost after pod restart | Ensure `ollama-models` PVC is bound and mounted at `/root/.ollama`; `emptyDir` would lose models on restart. |

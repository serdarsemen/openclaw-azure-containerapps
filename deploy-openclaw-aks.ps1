# ---------------------------------------------------------------------------
# deploy-openclaw-aks.ps1 — Provision AKS and deploy OpenClaw + Ollama (separate pods)
#
# Mirrors deploy-openclaw-ACA.ps1 but targets an Azure Kubernetes Service
# cluster. Ollama runs as its own Deployment/Service in the `openclaw` namespace
# and OpenClaw reaches it via in-cluster DNS at http://ollama:11434.
#
# Infrastructure reuse:
#   - Reuses the existing ACR + NFS Azure Files share from the ACA Bicep deployment
#     (rg-openclaw / rg-openclawnpm) so the image and state can roll forward.
#   - Creates a new AKS cluster in its own resource group (default: rg-openclaw-aks).
#
# Prerequisites:
#   - Azure CLI logged in (`az login`)
#   - kubectl installed (`az aks install-cli`)
#   - Source ACA infrastructure deployed (this script discovers ACR + storage via Bicep outputs)
#
# Usage:
#   .\deploy-openclaw-aks.ps1                                  # source-build variant
#   .\deploy-openclaw-aks.ps1 -Npm                             # npm variant
#   .\deploy-openclaw-aks.ps1 -GatewayToken <hex>              # reuse an ACA token
#   .\deploy-openclaw-aks.ps1 -OllamaModels "llama3.1:8b,qwen2.5:7b"
# ---------------------------------------------------------------------------

param(
    [switch] $Npm,
    [string] $SourceResourceGroup = "rg-openclaw",      # ACA resource group (source of ACR + storage)
    [string] $SourceDeploymentName = "main",            # "mainnpm" for npm variant
    [string] $AksResourceGroup = "rg-openclaw-aks",
    [string] $AksName = "aks-openclaw",
    [string] $Location = "swedencentral",
    [string] $NodeVmSize = "Standard_D4s_v5",
    [int]    $NodeCount = 2,
    [string] $Namespace = "openclaw",
    [string] $GatewayToken = "",                         # if empty, a new 256-bit token is generated
    [string] $GroqApiKey = "",
    [string] $OllamaImage = "ollama/ollama:latest",
    [string] $OllamaModels = "llama3.1:8b",              # comma-separated list to pre-pull
    [string] $OpenClawCpu = "3",
    [string] $OpenClawMemory = "6Gi",
    [string] $OllamaCpu = "1",
    [string] $OllamaMemory = "2Gi",
    [int]    $OllamaModelsPvcSize = 100,                 # GiB
    [int]    $OpenClawStatePvSize = 100                  # GiB
)

$ErrorActionPreference = "Stop"

if (-not $GroqApiKey) { $GroqApiKey = "REPLACE_ME" }

# --- Variant-specific defaults ---
if ($Npm) {
    if (-not $PSBoundParameters.ContainsKey('SourceResourceGroup'))  { $SourceResourceGroup  = "rg-openclawnpm" }
    if (-not $PSBoundParameters.ContainsKey('SourceDeploymentName')) { $SourceDeploymentName = "mainnpm" }
    $HomeDir = "/home/openclaw"
    Write-Host "`n*** NPM variant selected ***" -ForegroundColor Magenta
} else {
    $HomeDir = "/home/node"
    Write-Host "`n*** Source-build variant selected ***" -ForegroundColor Magenta
}

# --- Discover source infra from ACA Bicep deployment ---
Write-Host "`n=== Step 1/8: Discovering source infrastructure ===" -ForegroundColor Cyan

$AcrName = az deployment group show --resource-group $SourceResourceGroup --name $SourceDeploymentName `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$StorageAccount = az deployment group show --resource-group $SourceResourceGroup --name $SourceDeploymentName `
    --query "properties.outputs.storageAccountName.value" -o tsv 2>$null

if (-not $AcrName -or -not $StorageAccount) {
    throw "Could not discover ACR/Storage from deployment '$SourceDeploymentName' in '$SourceResourceGroup'."
}
$AcrServer = "$AcrName.azurecr.io"
$StorageRg = az storage account show --name $StorageAccount --query resourceGroup -o tsv
if ($LASTEXITCODE -ne 0 -or -not $StorageRg) { throw "Failed to resolve storage account resource group" }

Write-Host "  ACR:       $AcrServer" -ForegroundColor Green
Write-Host "  Storage:   $StorageAccount (rg: $StorageRg)" -ForegroundColor Green

# --- Provision AKS (idempotent) ---
Write-Host "`n=== Step 2/8: Provisioning AKS cluster ===" -ForegroundColor Cyan

az group create --name $AksResourceGroup --location $Location --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $AksResourceGroup" }

$existing = az aks show --resource-group $AksResourceGroup --name $AksName --query name -o tsv 2>$null
if ($existing) {
    Write-Host "  AKS cluster '$AksName' already exists — skipping create" -ForegroundColor Gray
} else {
    Write-Host "  Creating AKS cluster $AksName ($NodeCount x $NodeVmSize)..." -ForegroundColor Gray
    az aks create `
        --resource-group $AksResourceGroup --name $AksName `
        --location $Location `
        --node-count $NodeCount --node-vm-size $NodeVmSize `
        --enable-managed-identity `
        --network-plugin azure `
        --generate-ssh-keys `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "AKS create failed" }
}

# Attach ACR so kubelet can pull images without imagePullSecrets
Write-Host "  Attaching ACR $AcrName to AKS..." -ForegroundColor Gray
az aks update --resource-group $AksResourceGroup --name $AksName --attach-acr $AcrName --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "aks update --attach-acr failed" }

# Grant kubelet identity Storage File Data Privileged Contributor on the NFS share storage
$KubeletObjId = az aks show --resource-group $AksResourceGroup --name $AksName `
    --query identityProfile.kubeletidentity.objectId -o tsv
$StorageId = az storage account show --name $StorageAccount --resource-group $StorageRg --query id -o tsv
Write-Host "  Granting kubelet identity access to storage..." -ForegroundColor Gray
az role assignment create --assignee $KubeletObjId `
    --role "Storage File Data Privileged Contributor" --scope $StorageId --only-show-errors 2>$null | Out-Null

# Fetch kubeconfig
az aks get-credentials --resource-group $AksResourceGroup --name $AksName --overwrite-existing --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "get-credentials failed" }
kubectl get nodes --no-headers | Out-Host

# --- Namespace + secrets ---
Write-Host "`n=== Step 3/8: Creating namespace and secrets ===" -ForegroundColor Cyan

kubectl get namespace $Namespace 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    kubectl create namespace $Namespace | Out-Null
}

if (-not $GatewayToken) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $GatewayToken = [BitConverter]::ToString($bytes).Replace('-', '').ToLower()
    Write-Host "  Generated new gateway token" -ForegroundColor Gray
} else {
    Write-Host "  Using provided gateway token" -ForegroundColor Gray
}
Write-Host "  Token: $GatewayToken" -ForegroundColor Yellow

# Recreate secret to keep values in sync on re-runs
kubectl -n $Namespace delete secret openclaw-secrets --ignore-not-found | Out-Null
kubectl -n $Namespace create secret generic openclaw-secrets `
    --from-literal=OPENCLAW_GATEWAY_TOKEN=$GatewayToken `
    --from-literal=GROQ_API_KEY=$GroqApiKey | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create openclaw-secrets" }

# --- Persistent storage ---
Write-Host "`n=== Step 4/8: Provisioning persistent storage ===" -ForegroundColor Cyan

$stateManifest = @"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: openclaw-state
spec:
  capacity:
    storage: ${OpenClawStatePvSize}Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: file.csi.azure.com
    volumeHandle: openclaw-state-${StorageAccount}
    volumeAttributes:
      resourceGroup: "$StorageRg"
      storageAccount: "$StorageAccount"
      shareName: openclaw-state
      protocol: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-state
  namespace: $Namespace
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  resources:
    requests:
      storage: ${OpenClawStatePvSize}Gi
  volumeName: openclaw-state
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: $Namespace
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: managed-csi-premium
  resources:
    requests:
      storage: ${OllamaModelsPvcSize}Gi
"@

$tmpState = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")
try {
    $stateManifest | Set-Content $tmpState -Encoding utf8
    kubectl apply -f $tmpState | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply storage manifests" }
} finally {
    Remove-Item $tmpState -ErrorAction SilentlyContinue
}

# --- Deploy Ollama as a separate pod ---
Write-Host "`n=== Step 5/8: Deploying Ollama (separate pod) ===" -ForegroundColor Cyan

$ollamaManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: $Namespace
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
          image: $OllamaImage
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
            limits:   { cpu: "$OllamaCpu", memory: "$OllamaMemory" }
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
  namespace: $Namespace
spec:
  type: ClusterIP
  selector: { app: ollama }
  ports:
    - name: http
      port: 11434
      targetPort: 11434
"@

$tmpOllama = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")
try {
    $ollamaManifest | Set-Content $tmpOllama -Encoding utf8
    kubectl apply -f $tmpOllama | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply ollama manifest" }
} finally {
    Remove-Item $tmpOllama -ErrorAction SilentlyContinue
}

Write-Host "  Waiting for ollama rollout..." -ForegroundColor Gray
kubectl -n $Namespace rollout status deploy/ollama --timeout=300s | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Ollama rollout did not complete" }

# Pre-pull models
if ($OllamaModels) {
    foreach ($m in ($OllamaModels -split ',')) {
        $m = $m.Trim()
        if (-not $m) { continue }
        Write-Host "  Pulling Ollama model: $m" -ForegroundColor Gray
        kubectl -n $Namespace exec deploy/ollama -- ollama pull $m
        if ($LASTEXITCODE -ne 0) { Write-Warning "ollama pull $m failed (exit $LASTEXITCODE)" }
    }
}

# --- Deploy OpenClaw (with Redis sidecar) ---
Write-Host "`n=== Step 6/8: Deploying OpenClaw ===" -ForegroundColor Cyan

if ($Npm) {
    $OpenClawCommand = @(
        "bash", "-c",
        "umask 077 && (openclaw config set gateway.controlUi.allowInsecureAuth true || true) && (openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) && (openclaw config set gateway.auth.rateLimit.maxAttempts 10 || true) && (openclaw config set gateway.auth.rateLimit.windowMs 60000 || true) && (openclaw config set gateway.auth.rateLimit.lockoutMs 300000 || true) && (openclaw config set browser.executablePath /usr/bin/chromium || true) && npm config set prefix '~/.openclaw/npm-global' && mkdir -p $HomeDir/.openclaw/workspace/memory && export OPENCLAW_NO_RESPAWN=1 && find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true && find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true && find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true && openclaw gateway --allow-unconfigured --bind lan --port 18789"
    )
    $PluginsDir = "/usr/local/lib/node_modules/openclaw/dist/extensions"
} else {
    $OpenClawCommand = @(
        "sh", "-c",
        "umask 077 && chmod -R 755 /app/dist/extensions && mkdir -p $HomeDir/.openclaw/workspace/memory && export OPENCLAW_NO_RESPAWN=1 && (node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true || true) && (node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true || true) && (node openclaw.mjs config set gateway.auth.rateLimit.maxAttempts 10 || true) && (node openclaw.mjs config set gateway.auth.rateLimit.windowMs 60000 || true) && (node openclaw.mjs config set gateway.auth.rateLimit.lockoutMs 300000 || true) && find $HomeDir/.openclaw -name 'auth-*.json' -exec chmod 600 {} + 2>/dev/null || true && find $HomeDir/.openclaw -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true && find $HomeDir/.openclaw -type d -exec chmod 700 {} + 2>/dev/null || true && node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789"
    )
    $PluginsDir = "/app/dist/extensions"
}

$cmdYaml = ($OpenClawCommand | ForEach-Object { "            - " + ($_ | ConvertTo-Json -Compress) }) -join "`n"

$openclawManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw
  namespace: $Namespace
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
        fsGroup: 1000
      containers:
        - name: openclaw
          image: $AcrServer/openclaw:latest
          command:
$cmdYaml
          ports:
            - name: gateway
              containerPort: 18789
          envFrom:
            - secretRef: { name: openclaw-secrets }
          env:
            - name: REDIS_HOST
              value: localhost
            - name: REDIS_PORT
              value: "6379"
            - name: NODE_ENV
              value: production
            - name: HOME
              value: $HomeDir
            - name: TERM
              value: xterm-256color
            - name: OPENCLAW_BUNDLED_PLUGINS_DIR
              value: $PluginsDir
            - name: OLLAMA_HOST
              value: "http://ollama:11434"
            - name: OPENCLAW_DISABLE_BONJOUR
              value: "true"
          resources:
            requests: { cpu: "2",            memory: "4Gi" }
            limits:   { cpu: "$OpenClawCpu", memory: "$OpenClawMemory" }
          volumeMounts:
            - name: state
              mountPath: $HomeDir/.openclaw
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
  namespace: $Namespace
spec:
  type: LoadBalancer
  selector: { app: openclaw }
  ports:
    - name: gateway
      port: 18789
      targetPort: 18789
"@

$tmpOpenclaw = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".yaml")
try {
    $openclawManifest | Set-Content $tmpOpenclaw -Encoding utf8
    kubectl apply -f $tmpOpenclaw | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply openclaw manifest" }
} finally {
    Remove-Item $tmpOpenclaw -ErrorAction SilentlyContinue
}

Write-Host "  Waiting for openclaw rollout..." -ForegroundColor Gray
kubectl -n $Namespace rollout status deploy/openclaw --timeout=600s | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Warning "openclaw rollout did not complete within timeout" }

# --- Non-interactive onboarding ---
Write-Host "`n=== Step 7/8: Configuring OpenClaw (non-interactive) ===" -ForegroundColor Cyan

function Invoke-PodExec {
    param([string] $Label, [string] $Command, [int] $MaxRetries = 3, [int] $DelaySec = 15)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "  [$Label] attempt $i/$MaxRetries" -ForegroundColor Gray
        kubectl -n $Namespace exec deploy/openclaw -c openclaw -- bash -c $Command
        if ($LASTEXITCODE -eq 0) { return }
        if ($i -lt $MaxRetries) {
            Write-Host "  [$Label] exec failed — retrying in ${DelaySec}s..." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySec
        }
    }
        throw "[$Label] failed after $MaxRetries attempts (exit $LASTEXITCODE)"
}

if ($Npm) {
    $bin = "openclaw"
} else {
    $bin = "node openclaw.mjs"
}

Invoke-PodExec -Label "Onboard" `
    -Command "$bin onboard --non-interactive --accept-risk --mode local --flow manual --auth-choice skip --gateway-port 18789 --gateway-bind lan --gateway-auth token --gateway-token `$OPENCLAW_GATEWAY_TOKEN --skip-channels --skip-skills --skip-daemon --skip-health"

Invoke-PodExec -Label "Model set" -Command "$bin models set github-copilot/claude-opus-4.6"
Invoke-PodExec -Label "Security audit" -Command "$bin security audit"

# --- Summary ---
Write-Host "`n=== Step 8/8: Gateway configured ===" -ForegroundColor Green

$GatewayIp = ""
for ($i = 0; $i -lt 30; $i++) {
    $GatewayIp = kubectl -n $Namespace get svc openclaw -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($GatewayIp) { break }
    Start-Sleep -Seconds 10
}
if (-not $GatewayIp) { $GatewayIp = "<pending — run: kubectl -n $Namespace get svc openclaw>" }

$variantLabel = if ($Npm) { "npm" } else { "source" }
$boxLabel  = "GATEWAY TOKEN: $GatewayToken"
$boxBorder = "─" * ($boxLabel.Length + 2)
Write-Host "  ┌$boxBorder┐" -ForegroundColor Yellow
Write-Host "  │ $boxLabel │" -ForegroundColor Yellow
Write-Host "  └$boxBorder┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "OpenClaw ($variantLabel) URL:  http://${GatewayIp}:18789"
Write-Host "Control UI:           http://${GatewayIp}:18789/#token=$GatewayToken"
Write-Host ""
Write-Host "=== One manual step remaining: GitHub Copilot auth ===" -ForegroundColor Cyan
Write-Host "1. Exec into the pod:" -ForegroundColor Yellow
Write-Host "   kubectl -n $Namespace exec -it deploy/openclaw -c openclaw -- bash"
Write-Host ""
Write-Host "2. Inside the container:" -ForegroundColor Yellow
$authCmd = if ($Npm) { "openclaw models auth login-github-copilot" } else { "node openclaw.mjs models auth login-github-copilot" }
Write-Host "   $authCmd" -ForegroundColor White
Write-Host ""
Write-Host "Ollama pod:" -ForegroundColor Cyan
Write-Host "   kubectl -n $Namespace get pods -l app=ollama"
Write-Host "   kubectl -n $Namespace exec deploy/ollama -- ollama list"
Write-Host ""
Write-Host "=== Last step: save gateway token and URL ===" -ForegroundColor Cyan
Write-Host ""
$boxLabelLast  = "GATEWAY TOKEN: $GatewayToken"
$boxBorderLast = "─" * ($boxLabelLast.Length + 2)
Write-Host "  ┌$boxBorderLast┐" -ForegroundColor Yellow
Write-Host "  │ $boxLabelLast │" -ForegroundColor Yellow
Write-Host "  └$boxBorderLast┘" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Control UI: http://${GatewayIp}:18789/#token=$GatewayToken" -ForegroundColor White


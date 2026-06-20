#!/usr/bin/env pwsh
<#
.SYNOPSIS
Deploy Ollama with qwen3.5 model to Azure Kubernetes Service (AKS)

.DESCRIPTION
Creates a Kubernetes deployment for Ollama in an AKS cluster and pulls the qwen3.5 model.
This enables CRW to access Ollama for LLM-powered extraction within the cluster.

.PARAMETER ResourceGroup
The Azure resource group containing the AKS cluster (default: from current context)

.PARAMETER ClusterName
The AKS cluster name (default: auto-discovered from subscriptions)

.PARAMETER Namespace
Kubernetes namespace for Ollama deployment (default: ollama)

.PARAMETER Model
Ollama model to pull (default: qwen3.5)

.PARAMETER GpuEnabled
Enable GPU support if available (default: false for CPU inference)

.EXAMPLE
.\start-ollama-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks

.EXAMPLE
.\start-ollama-aks.ps1 -GpuEnabled

.NOTES
Requires:
- Azure CLI (az) logged in
- kubectl configured to access target AKS cluster
- Sufficient cluster resources (min: 2 vCPU / 4GB RAM for CPU)
#>

param(
    [string]$ResourceGroup,
    [string]$ClusterName,
    [string]$Namespace = "ollama",
    [string]$Model = "qwen3.5",
    [switch]$GpuEnabled
)

$ErrorActionPreference = "Stop"

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Ollama AKS + Qwen3.5 Model Deployment Script             ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Step 1: Verify Azure CLI and kubectl
Write-Host "`n[1/5] Verifying Azure CLI and kubectl..." -ForegroundColor Cyan
try {
    $azVersion = az --version 2>&1 | Select-Object -First 1
    Write-Host "  Azure CLI: $azVersion" -ForegroundColor Green

    $kubectlVersion = kubectl version --client --short 2>&1
    Write-Host "  kubectl: $kubectlVersion" -ForegroundColor Green
} catch {
    Write-Host "  Error: Azure CLI and kubectl are required" -ForegroundColor Red
    exit 1
}

# Step 2: Get or discover AKS cluster
Write-Host "`n[2/5] Discovering AKS cluster..." -ForegroundColor Cyan
if (-not $ResourceGroup -or -not $ClusterName) {
    Write-Host "  Auto-discovering cluster..." -ForegroundColor Gray
    $clusters = az aks list --query "[0]" --output json | ConvertFrom-Json
    if (-not $clusters) {
        Write-Host "  No AKS clusters found. Specify -ResourceGroup and -ClusterName" -ForegroundColor Red
        exit 1
    }
    $ResourceGroup = $clusters.resourceGroup
    $ClusterName = $clusters.name
}

Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Green
Write-Host "  Cluster: $ClusterName" -ForegroundColor Green

# Get cluster credentials
Write-Host "  Getting cluster credentials..." -ForegroundColor Gray
az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --overwrite-existing 2>&1 | Out-Null

# Step 3: Create namespace and prepare deployment
Write-Host "`n[3/5] Creating namespace and RBAC..." -ForegroundColor Cyan
kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null
Write-Host "  Namespace '$Namespace' ready" -ForegroundColor Green

# Step 4: Deploy Ollama
Write-Host "`n[4/5] Deploying Ollama to AKS..." -ForegroundColor Cyan

$resourceRequests = if ($GpuEnabled) {
    @"
        requests:
          memory: "4Gi"
          cpu: "2000m"
          nvidia.com/gpu: "1"
        limits:
          memory: "8Gi"
          cpu: "4000m"
          nvidia.com/gpu: "1"
"@
} else {
    @"
        requests:
          memory: "4Gi"
          cpu: "2000m"
        limits:
          memory: "8Gi"
          cpu: "4000m"
"@
}

$deployment = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
          name: http
        resources:
$resourceRequests
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0:11434"
        volumeMounts:
        - name: ollama-data
          mountPath: /root/.ollama
        livenessProbe:
          httpGet:
            path: /
            port: 11434
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /
            port: 11434
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: ollama-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: $Namespace
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
    name: http
  type: ClusterIP
"@

$deployment | kubectl apply -f - | Out-Null
Write-Host "  Ollama deployment created" -ForegroundColor Green

# Wait for deployment to be ready
Write-Host "  Waiting for Ollama pod to be ready (up to 2 minutes)..." -ForegroundColor Gray
$maxAttempts = 24
for ($i = 0; $i -lt $maxAttempts; $i++) {
    $ready = kubectl get deployment ollama -n $Namespace -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>$null
    if ($ready -eq "True") {
        Write-Host "  Ollama pod is ready" -ForegroundColor Green
        break
    }
    Start-Sleep -Seconds 5
}

# Step 5: Pull model using port-forward
Write-Host "`n[5/5] Pulling $Model model..." -ForegroundColor Cyan
Write-Host "  Setting up port-forward to Ollama pod..." -ForegroundColor Gray

# Start port-forward in background
$portForwardJob = Start-Job -ScriptBlock {
    param($ns)
    kubectl port-forward -n $ns svc/ollama 11434:11434 2>&1 | Out-Null
} -ArgumentList $Namespace

# Wait for port-forward to establish
Start-Sleep -Seconds 3

try {
    Write-Host "  Pulling model (this may take 2-10 minutes)..." -ForegroundColor Gray

    # Use Invoke-WebRequest to trigger the pull via Ollama API
    $pullRequest = @{
        name = $Model
        stream = $false
    } | ConvertTo-Json

    $response = Invoke-WebRequest -Uri "http://localhost:11434/api/pull" `
        -Method Post `
        -ContentType "application/json" `
        -Body $pullRequest `
        -TimeoutSec 600 `
        -ErrorAction Stop

    Write-Host "  Model $Model pulled successfully" -ForegroundColor Green
} catch {
    Write-Host "  Warning: Model pull may still be in progress: $_" -ForegroundColor Yellow
} finally {
    # Stop port-forward
    Stop-Job $portForwardJob -ErrorAction SilentlyContinue
}

# Verification
Write-Host "`n[Verification] Checking deployment status..." -ForegroundColor Cyan
$replicas = kubectl get deployment ollama -n $Namespace -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>$null
Write-Host "  Replicas: $replicas" -ForegroundColor Green

Write-Host "`n✅ Ollama deployment complete!" -ForegroundColor Green
Write-Host "   Service: ollama.$Namespace.svc.cluster.local:11434" -ForegroundColor Green
Write-Host "   Use for CRW: http://ollama.$Namespace.svc.cluster.local:11434/v1" -ForegroundColor Green
Write-Host "`n   To access from localhost (port-forward):" -ForegroundColor Gray
Write-Host "   kubectl port-forward -n $Namespace svc/ollama 11434:11434" -ForegroundColor Gray

Write-Host ""

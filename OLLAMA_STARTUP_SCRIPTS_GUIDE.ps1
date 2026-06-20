#!/usr/bin/env pwsh
<#
.SYNOPSIS
Ollama + Qwen3.5 Model Startup Scripts - Complete Guide

This file provides an overview of all Ollama startup scripts created for different
deployment environments. Each script follows the same 3-step pattern:
1. Start/provision Ollama service in target environment
2. Wait for API readiness (polling with timeout)
3. Pull qwen3.5 model via Ollama CLI
4. Verify model installation

## Quick Reference

| Environment | Script | Platform | Use When |
|---|---|---|---|
| **WSL 2** | `start-ollama-qwen.ps1` | Windows → WSL 2 | Running OpenClaw in WSL 2 with Docker Compose |
| **Windows Native** | `start-ollama-windows.ps1` | Windows | Running Ollama natively on Windows (GitHub Actions, Dev Machines) |
| **Azure Container Apps** | `start-ollama-aca.ps1` | Azure | Deploying Ollama as standalone Container App in Azure |
| **Azure Kubernetes** | `start-ollama-aks.ps1` | Azure | Deploying Ollama pod in existing AKS cluster |
| **GitHub Actions** | `start-ollama-gha.ps1` | CI/CD | Running in GitHub Actions workflows or Codespaces |

## Detailed Guide

### 1. WSL 2 Deployment (start-ollama-qwen.ps1)

**Purpose**: Start Ollama in WSL 2 and prepare qwen3.5 model for Docker Compose OpenClaw

**Use Cases**:
- Local development with OpenClaw running in Docker Compose on WSL 2
- Testing CRW LLM integration locally before cloud deployment
- Development within Windows Subsystem for Linux

**Requirements**:
- WSL 2 installed and configured
- Docker Desktop with WSL 2 backend
- wsl-helpers.ps1 in same directory

**Usage**:
```powershell
# Run from PowerShell (Windows)
.\start-ollama-qwen.ps1

# Expected output:
# [1/3] Starting Ollama on WSL...
#   Ollama is running (PID: 1234)
# [2/3] Waiting for Ollama API to be ready...
#   Ollama API is ready
# [3/3] Pulling qwen3.5 model...
#   Model qwen3.5 pulled successfully
```

**Network Details**:
- WSL 2 container runs on Docker network `openclaw-net` (172.31.240.0/24)
- CRW accesses Ollama via peer DNS: `http://ollama:11434/v1`
- From Windows host: `http://localhost:11434`

**Integration**:
- CRW uses `CRW_EXTRACTION__LLM__BASE_URL=http://ollama:11434/v1`
- Ollama service is a Docker Compose sidecar to OpenClaw
- Redis shares same network for state/queue management

---

### 2. Windows Native Deployment (start-ollama-windows.ps1)

**Purpose**: Start Ollama natively on Windows and prepare qwen3.5 model

**Use Cases**:
- GitHub Actions runners on Windows (windows-latest)
- Windows development machines without WSL
- CI/CD environments requiring native Windows Ollama

**Requirements**:
- Ollama installed natively on Windows
- Download: https://ollama.ai/download/windows
- wsl-helpers.ps1 in same directory (uses Start-OllamaWindows helper)

**Usage**:
```powershell
# Run from PowerShell
.\start-ollama-windows.ps1

# Expected output:
# [1/3] Starting Ollama on Windows...
#   Ollama started successfully
# [2/3] Waiting for Ollama API to be ready...
#   Ollama API is ready
# [3/3] Pulling qwen3.5 model...
#   Model qwen3.5 pulled successfully
```

**Network Details**:
- Ollama listens on `http://localhost:11434`
- Environment variable: `OLLAMA_HOST=0.0.0.0:11434`
- Accessible from Docker containers via `http://host.docker.internal:11434`

**Integration**:
- If running OpenClaw in Docker: `CRW_EXTRACTION__LLM__BASE_URL=http://host.docker.internal:11434/v1`
- If running OpenClaw natively: `CRW_EXTRACTION__LLM__BASE_URL=http://localhost:11434/v1`

---

### 3. Azure Container Apps Deployment (start-ollama-aca.ps1)

**Purpose**: Deploy Ollama as standalone Container App in Azure and pull qwen3.5

**Use Cases**:
- Serverless Ollama deployment without managing infrastructure
- Scalable LLM backend for Azure-hosted OpenClaw
- Dev/test environments with quick teardown
- Integration with Azure OpenClaw deployments

**Requirements**:
- Azure CLI (`az`) logged in
- Container Apps environment pre-created
- Sufficient quota (default: 2 vCPU / 4 GB RAM)

**Usage**:
```powershell
# Basic usage (requires parameters)
.\start-ollama-aca.ps1 -ResourceGroup my-rg -Environment my-aca-env

# With custom resources
.\start-ollama-aca.ps1 -ResourceGroup my-rg `
                       -Environment my-aca-env `
                       -ContainerAppName ollama-prod `
                       -Memory 8 `
                       -Cpu 4.0

# Custom model
.\start-ollama-aca.ps1 -ResourceGroup my-rg `
                       -Environment my-aca-env `
                       -Model mistral
```

**Parameters**:
- `-ResourceGroup`: Azure resource group (required)
- `-Environment`: Container Apps environment name (required)
- `-ContainerAppName`: App name (default: ollama)
- `-Model`: Ollama model to pull (default: qwen3.5)
- `-Memory`: Container memory in GB (default: 4, options: 2, 4, 8)
- `-Cpu`: Container CPU in vCores (default: 2.0, range: 0.5-4.0)

**Output**:
```
Container App URL: https://ollama-abc123.eastus.azurecontainerapps.io
Port: 11434
CRW configuration: CRW_EXTRACTION__LLM__BASE_URL=https://ollama-abc123.eastus.azurecontainerapps.io/v1
```

**Network Details**:
- Public FQDN accessible via HTTPS
- Ingress configured for external access
- TCP transport layer 4 ingress
- Single replica with no auto-scaling

**Integration**:
- Deploy alongside OpenClaw Container App
- Share same Container Apps environment
- CRW references via external HTTPS URL

---

### 4. Azure Kubernetes Service Deployment (start-ollama-aks.ps1)

**Purpose**: Deploy Ollama pod in AKS cluster and pull qwen3.5 model

**Use Cases**:
- Kubernetes-native Ollama deployment
- Multi-replica Ollama for scaling (customizable)
- Integration with existing AKS-hosted OpenClaw
- Production-grade LLM backend with K8s lifecycle management

**Requirements**:
- Azure CLI (`az`) logged in
- kubectl configured and connected to AKS cluster
- Existing AKS cluster
- Sufficient cluster resources (min: 2 vCPU / 4GB per pod)

**Usage**:
```powershell
# Auto-discover cluster
.\start-ollama-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks

# With GPU support (if cluster has GPUs)
.\start-ollama-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks -GpuEnabled

# Custom namespace
.\start-ollama-aks.ps1 -ResourceGroup my-rg `
                       -ClusterName my-aks `
                       -Namespace ollama-prod `
                       -Model llama2
```

**Parameters**:
- `-ResourceGroup`: Azure resource group
- `-ClusterName`: AKS cluster name
- `-Namespace`: Kubernetes namespace (default: ollama)
- `-Model`: Ollama model to pull (default: qwen3.5)
- `-GpuEnabled`: Enable GPU resources if available (requires nvidia.com/gpu: "1")

**Output**:
```
Deployment status:
- Service DNS: ollama.ollama.svc.cluster.local:11434
- Internal URL: http://ollama.ollama.svc.cluster.local:11434/v1
- Port-forward for local access: kubectl port-forward -n ollama svc/ollama 11434:11434
```

**Network Details**:
- ClusterIP service (internal only)
- Pod accessible via Kubernetes service DNS
- Port-forward available for local debugging
- Liveness/readiness probes on http://pod:11434

**Integration**:
- OpenClaw pods use Kubernetes service DNS: `http://ollama.ollama.svc.cluster.local:11434/v1`
- Cross-namespace access: `http://ollama.<namespace>.svc.cluster.local:11434/v1`
- Storage: emptyDir volume (transient, lost on pod restart)

**Production Improvements** (not in base script):
- Use PersistentVolumeClaim for model caching
- Add resource limits and requests
- Configure horizontal pod autoscaler
- Add network policies for security

---

### 5. GitHub Actions / Codespaces Deployment (start-ollama-gha.ps1)

**Purpose**: Start Ollama in GitHub Actions workflows or Codespaces

**Use Cases**:
- GitHub Actions CI/CD workflows requiring Ollama
- Testing OpenClaw in Codespaces
- Integration testing with live LLM inference
- Cross-platform testing (ubuntu-latest, windows-latest, macos-latest)

**Requirements**:
- PowerShell 7+ or 5.1+
- Runner OS support:
  - Linux: Ollama auto-installed if missing
  - Windows: Ollama pre-installed (download first if not present)
  - macOS: Ollama pre-installed

**Usage**:

```powershell
# Standalone script execution
.\start-ollama-gha.ps1

# In GitHub Actions workflow (ubuntu-latest)
- name: Start Ollama
  run: pwsh .\start-ollama-gha.ps1

# In GitHub Actions workflow (windows-latest)
- name: Download Ollama
  run: |
    Invoke-WebRequest -Uri "https://ollama.ai/download/windows" -OutFile ollama-installer.exe
    .\ollama-installer.exe /S

- name: Start Ollama
  run: pwsh .\start-ollama-gha.ps1

# In Codespaces (already has Ollama)
.\start-ollama-gha.ps1
```

**Environment Detection**:
- Detects Linux, Windows, macOS automatically
- Detects GitHub Actions vs Codespaces environment
- Adjusts startup method based on platform

**Network Details**:
- All platforms: `http://localhost:11434`
- OpenQASM compatible endpoint: `http://localhost:11434/v1`

**Integration**:
```yaml
# GitHub Actions example
name: Test with Ollama

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Ollama
        run: pwsh .\start-ollama-gha.ps1

      - name: Run tests
        env:
          OLLAMA_HOST: http://localhost:11434
          CRW_EXTRACTION__LLM__BASE_URL: http://localhost:11434/v1
        run: npm test
```

---

## Error Handling & Troubleshooting

### Common Issues

**Issue**: "Ollama not found"
- **WSL**: Ensure Docker Desktop is running and WSL 2 backend is enabled
- **Windows**: Download from https://ollama.ai/download/windows
- **ACA**: Should auto-pull from Docker Hub; check Azure logs
- **AKS**: Verify cluster can pull from public registries
- **GHA**: Script auto-installs on Linux; pre-install on Windows/macOS

**Issue**: "Port 11434 already in use"
- WSL/Windows: `netstat -ano | findstr 11434` → kill process
- AKS: Use different namespace and port-forward to different local port
- GHA: Ensure no other job is using same port

**Issue**: "Model pull timeout"
- Network issue or registry connectivity
- Model file is large (1-7+ GB)
- Allow longer timeout in script or increase timeout
- Check network connectivity

### Debugging

```powershell
# Check Ollama status
curl http://localhost:11434/api/tags

# Check models
ollama list  # Windows/WSL
kubectl exec -it ollama-pod -- ollama list  # AKS
az containerapp exec --name ollama --resource-group rg --command "ollama list"  # ACA

# Check logs
kubectl logs -f deployment/ollama -n ollama  # AKS
az containerapp logs show --name ollama --resource-group rg --follow  # ACA

# Port forwarding (AKS)
kubectl port-forward -n ollama svc/ollama 11434:11434
```

---

## Integration with OpenClaw Deployment Scripts

### WSL Deployment
```powershell
# 1. Start Ollama
.\start-ollama-qwen.ps1

# 2. Deploy OpenClaw with Ollama sidecar
.\deploy-openclaw-wsl.ps1 -OllamaWSL
```

### Azure Container Apps Deployment
```powershell
# 1. Start Ollama
.\start-ollama-aca.ps1 -ResourceGroup my-rg -Environment my-env

# 2. Deploy OpenClaw (references Ollama via URL)
.\deploy-openclaw-ACA.ps1 -ResourceGroup my-rg -OllamaUrl "https://ollama-abc.azurecontainerapps.io"
```

### Azure Kubernetes Service Deployment
```powershell
# 1. Start Ollama in AKS
.\start-ollama-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks

# 2. Deploy OpenClaw to same cluster
.\deploy-openclaw-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks
```

---

## Best Practices

1. **Model Caching**: Keep models in persistent storage (AKS PVC, ACA file shares)
2. **Resource Tuning**: Monitor and adjust CPU/memory based on model size
3. **Health Checks**: Implement liveness/readiness probes (already in AKS script)
4. **Error Handling**: All scripts use `$ErrorActionPreference = "Stop"`
5. **Cleanup**: Delete resources when not in use (especially ACA for cost)
6. **Testing**: Verify model access before deploying dependent services
7. **Networking**: Understand service-to-service communication for each environment

---

## Reference

**All scripts follow standard PowerShell conventions**:
- Error handling: `$ErrorActionPreference = "Stop"`
- Logging: `Write-Host` with color-coding (Cyan=header, Green=success, Yellow=warning, Red=error)
- Output: Progress tracking and verification steps
- Cleanup: Proper resource disposal in finally blocks

**Model Sizes** (approx):
- qwen3.5: 5-7 GB
- llama2: 3-7 GB (by variant)
- mistral: 4-7 GB (by variant)

**API Endpoints**:
- List models: `GET /api/tags`
- Pull model: `POST /api/pull` (with JSON body)
- Generate: `POST /api/generate`
- Chat: `POST /api/chat`

#>

# This file is documentation only. The actual scripts are:
# - start-ollama-qwen.ps1 (WSL 2)
# - start-ollama-windows.ps1 (Windows Native)
# - start-ollama-aca.ps1 (Azure Container Apps)
# - start-ollama-aks.ps1 (Azure Kubernetes Service)
# - start-ollama-gha.ps1 (GitHub Actions / Codespaces)

Write-Host @"

╔════════════════════════════════════════════════════════════════╗
║    Ollama + Qwen3.5 Startup Scripts - Quick Reference          ║
╚════════════════════════════════════════════════════════════════╝

Available Scripts:
  1. start-ollama-qwen.ps1          → WSL 2 deployment
  2. start-ollama-windows.ps1       → Windows native
  3. start-ollama-aca.ps1           → Azure Container Apps
  4. start-ollama-aks.ps1           → Azure Kubernetes Service
  5. start-ollama-gha.ps1           → GitHub Actions / Codespaces

For detailed documentation, see the function comments in each script.

Quick Start Examples:

  WSL 2:
    .\start-ollama-qwen.ps1

  Windows:
    .\start-ollama-windows.ps1

  Azure Container Apps:
    .\start-ollama-aca.ps1 -ResourceGroup my-rg -Environment my-env

  Azure Kubernetes:
    .\start-ollama-aks.ps1 -ResourceGroup my-rg -ClusterName my-aks

  GitHub Actions:
    .\start-ollama-gha.ps1

All scripts pull qwen3.5 model and verify installation.

"@ -ForegroundColor Cyan

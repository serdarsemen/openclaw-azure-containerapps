// ---------------------------------------------------------------------------
// Ollama on Azure Container Apps — Standalone Inference Sidecar
//
// Deploys an Ollama Container App into an existing Container Apps Environment.
// Must be deployed AFTER main.bicep (or mainnpm.bicep) since it references
// the existing environment by name.
//
// Ollama runs on Consumption profile: 4 vCPU / 8 GiB dedicated to inference.
// No ingress (internal-only) — OpenClaw reaches it via internal DNS:
//   http://ca-ollama:11434
//
// Usage:
//   az deployment group create --resource-group rg-openclaw \
//     --template-file bicep/ollama.bicep --parameters bicep/ollama.bicepparam
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = 'swedencentral'

@description('Name of the existing Container Apps Environment.')
param envName string = 'cae-openclaw'

@description('Ollama container CPU cores (Consumption max 4).')
param ollamaCpu string = '4'

@description('Ollama container memory (Consumption max 8Gi).')
param ollamaMemory string = '8Gi'

// --- Naming (CAF conventions) ---
var appName = 'ca-ollama'

// ---- Reference existing environment ----
resource acaEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: envName
}

// ---- Ollama Container App ----
// Internal-only (no ingress) — other apps in the same environment reach it via:
//   http://ca-ollama:11434
// Consumption profile: single container gets the full 4 vCPU / 8 GiB budget.

resource ollamaApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: false
        targetPort: 11434
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'ollama'
          image: 'ollama/ollama:latest'
          resources: {
            cpu: json(ollamaCpu)
            memory: ollamaMemory
          }
          env: [
            {
              name: 'OLLAMA_HOST'
              value: '0.0.0.0:11434'
            }
          ]
          probes: [
            {
              type: 'startup'
              httpGet: {
                port: 11434
                path: '/'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              failureThreshold: 30
            }
            {
              type: 'liveness'
              httpGet: {
                port: 11434
                path: '/'
              }
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ---- Outputs ----

@description('Ollama Container App name.')
output ollamaAppName string = ollamaApp.name

@description('Internal FQDN for Ollama (use from other apps in the same environment).')
output ollamaInternalFqdn string = ollamaApp.properties.configuration.ingress.fqdn

@description('Ollama URL for use in OLLAMA_HOST environment variable.')
output ollamaUrl string = 'http://${ollamaApp.properties.configuration.ingress.fqdn}'

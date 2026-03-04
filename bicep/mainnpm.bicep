// ---------------------------------------------------------------------------
// OpenClaw on Azure Container Apps — Infrastructure as Code
//
// Deploys all infrastructure + a placeholder container (Microsoft ACA quickstart).
// After deploy: run deploy-openclaw.ps1 to build image and switch to OpenClaw.
//
// Naming: follows Azure Cloud Adoption Framework (CAF) conventions.
// Globally unique names (ACR, Storage) auto-append a hash — no manual naming needed.
//
// Usage:
//   1. az group create --name rg-openclaw --location swedencentral
//   2. az deployment group create --resource-group rg-openclaw --template-file bicep/main.bicep --parameters bicep/main.bicepparam
//   3. Verify: open appUrl output → ACA quickstart page
//   4. ./deploy-openclaw.ps1 -ResourceGroup rg-openclaw
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = 'swedencentral'

@description('VNet address space.')
param vnetAddressPrefix string = '10.1.0.0/26'

@description('ACA subnet address range (minimum /27 for workload profiles).')
param acaSubnetPrefix string = '10.1.0.0/27'

@description('Private endpoint subnet address range.')
param peSubnetPrefix string = '10.1.0.32/28'

@description('NFS file share quota in GiB (100 GiB minimum for Premium FileStorage).')
param storageShareQuota int = 100

// --- Naming (CAF conventions) ---
// Globally unique names use uniqueString() — deterministic hash of the resource group ID.
// This means: same RG = same names (idempotent), different RG = different names (no collisions).
var suffix = uniqueString(resourceGroup().id)
var acrName = 'acropenclawnpm${suffix}'          // acr{workload}{hash} — globally unique
var storageName = 'stclawnpm${suffix}'        // st{workload}{hash} — globally unique
var shareName = 'openclawnpm-state'
var vnetName = 'vnet-openclaw'
var acaSubnetName = 'snet-aca'
var peSubnetName = 'snet-pe'
var peName = 'pep-storage'
var dnsZoneName = 'privatelink.file.${environment().suffixes.storage}'
var dnsLinkName = 'link-vnet'
var lawName = 'law-openclawnpm'
var envName = 'cae-openclaw'
var appName = 'ca-openclawnpm'
var envStorageName = 'openclawnpmstorage'

// ---- Networking ----

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: acaSubnetName
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
        }
      }
    ]
  }

  resource acaSubnet 'subnets' existing = {
    name: acaSubnetName
  }

  resource peSubnet 'subnets' existing = {
    name: peSubnetName
  }
}

// ---- Storage (Premium NFS) ----
// NFS chosen over SMB because tenant-enforced allowSharedKeyAccess=false blocks
// ACA's SMB mount. NFS authenticates via network rules (private endpoint).

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: false // NFS uses plain TCP port 2049, not HTTPS
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: [
        {
          id: vnet::acaSubnet.id
          action: 'Allow'
        }
      ]
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    shareQuota: storageShareQuota
    enabledProtocols: 'NFS'
  }
}

// ---- Private Endpoint + DNS ----
// Gives the storage account a private IP inside the VNet so ACA can NFS-mount it.

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: peName
  location: location
  properties: {
    subnet: {
      id: vnet::peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'connection-storage'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: dnsLinkName
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'dnsgroup-storage'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// ---- Container Registry ----
// ACR stores the built OpenClaw image. Admin auth for simplest ACA image pull.
// Image must be built separately: az acr build (before deploying this template).

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ---- Log Analytics ----

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---- Container Apps Environment ----
// Custom VNet required for NFS mount. NFS storage linked as environment-level storage.

resource acaEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: envName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: vnet::acaSubnet.id
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource acaStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: acaEnvironment
  name: envStorageName
  properties: {
    nfsAzureFile: {
      server: '${storageName}.file.${environment().suffixes.storage}'
      shareName: '/${storageName}/${shareName}'
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [
    dnsZoneGroup // DNS must resolve before NFS mount
    dnsVnetLink
    fileShare
  ]
}

// ---- Container App ----
// Deploys with Microsoft's ACA quickstart image (public, no ACR needed).
// Proves infrastructure works — HTTPS URL, networking, ACA environment all functional.
// Run deploy-openclaw.ps1 after to build OpenClaw image and update the app.

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: appName
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
        {
          name: 'redis'
          image: 'redis:7-alpine'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          command: [
            'redis-server'
            '--appendonly'
            'yes'
            '--dir'
            '/data'
          ]
          volumeMounts: [
            {
              volumeName: 'openclaw-state'
              mountPath: '/data'
            }
          ]
          probes: [
            {
              type: 'liveness'
              tcpSocket: {
                port: 6379
              }
              periodSeconds: 30
            }
          ]
        }
        {
          name: 'ollama'
          image: 'ollama/ollama:latest'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            {
              name: 'OLLAMA_HOST'
              value: '0.0.0.0:11434'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'openclaw-state'
              mountPath: '/root/.ollama'
            }
          ]
          probes: [
            {
              type: 'liveness'
              httpGet: {
                path: '/'
                port: 11434
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
      volumes: [
        {
          name: 'openclaw-state'
          storageType: 'NfsAzureFile'
          storageName: envStorageName
        }
      ]
    }
  }
  dependsOn: [
    acaStorage
  ]
}

// ---- Outputs ----

@description('Container App FQDN (HTTPS URL).')
output appUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'

@description('ACR name (for use with deploy-openclaw.ps1).')
output acrName string = acr.name

@description('ACR login server for image builds.')
output acrLoginServer string = acr.properties.loginServer

@description('Container Apps Environment default domain.')
output environmentDomain string = acaEnvironment.properties.defaultDomain

@description('Container App name (for use with deploy-openclaw.ps1).')
output appName string = containerApp.name



# ---------------------------------------------------------------------------
# Parameters and resource discovery
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $GitHubPAT = ""
)

$ErrorActionPreference = "Stop"

# Discover resource names from Bicep deployment outputs
$AcrName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$AppName = az deployment group show --resource-group $ResourceGroup --name main `
    --query "properties.outputs.appName.value" -o tsv 2>$null

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was main.bicep deployed to '$ResourceGroup'?"
}

# Discover Container Apps environment name
$envId = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.managedEnvironmentId" -o tsv 2>$null
if (-not $envId) { throw "Failed to get environment ID for $AppName" }
$envName = $envId.Split("/")[-1]

Write-Host "  ResourceGroup: $ResourceGroup" -ForegroundColor Green
Write-Host "  ACR:           $AcrName" -ForegroundColor Green
Write-Host "  App:           $AppName" -ForegroundColor Green
Write-Host "  Environment:   $envName" -ForegroundColor Green

# Option 1: ACR Task (auto-build on git push — recommended)
# ACR Tasks can watch the OpenClaw GitHub repo and automatically rebuild the image when commits are pushed. This replaces steps 1–2 of your script. You then add a webhook to restart the Container App.

# Create an ACR Task that auto-builds on commits to the main branch
az acr task create `
    --registry $AcrName `
    --name openclaw-autobuild `
    --image openclaw:latest `
    --context https://github.com/openclaw/openclaw.git `
    --file Dockerfile `
    --git-access-token $GitHubPAT `
    --commit-trigger-enabled true `
    --branch main

# You can also add a schedule (e.g., daily at 3 AM UTC)
az acr task create `
    --registry $AcrName `
    --name openclaw-scheduled-build `
    --image openclaw:latest `
    --context https://github.com/openclaw/openclaw.git `
    --file Dockerfile `
    --git-access-token $GitHubPAT `
    --schedule "0 6 * * *" `
    --commit-trigger-enabled false



    # Enable continuous deployment on the Container App (auto-restart on new image)
az containerapp update `
    --name $AppName `
    --resource-group $ResourceGroup `
    --image "$AcrName.azurecr.io/openclaw:latest"

# Or use ACR webhook to trigger a restart
az acr webhook create `
    --registry $AcrName `
    --name restartApp `
    --actions push `
    --scope "openclaw:latest" `
    --uri "https://management.azure.com/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.App/containerApps/{appName}/restart?api-version=2023-05-01"


# Option 3: Azure Container Apps Job (scheduled job)
# Run the update as a scheduled Container Apps Job using a custom image with az CLI and git:
az containerapp job create `
    --name openclaw-updater `
    --resource-group $ResourceGroup `
    --environment $envName `
    --image mcr.microsoft.com/azure-cli:latest `
    --trigger-type Schedule `
    --cron-expression "0 3 * * *" `
    --cpu 0.5 --memory 1Gi `
    --command "bash" "-c" `
    "az login --identity && az acr build --registry $AcrName --image openclaw:latest --file Dockerfile https://github.com/openclaw/openclaw.git && az containerapp update --name $AppName --resource-group $ResourceGroup --image $AcrName.azurecr.io/openclaw:latest"


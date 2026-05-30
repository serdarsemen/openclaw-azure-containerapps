# ---------------------------------------------------------------------------
# imagedeployautomationscripts.ps1
#
# Sets up CI/CD automation for rebuilding and redeploying the OpenClaw image.
# Three MUTUALLY-EXCLUSIVE options are available; choose exactly ONE via -Option:
#
#   AcrTask  - ACR Tasks that auto-build the image on commits to main (and a
#              daily scheduled build), enable continuous deployment on the
#              Container App, and add a webhook that restarts the app on push.
#              Requires -GitHubPAT (a GitHub PAT with repo read access).
#   Webhook  - Only (re)create the ACR webhook that restarts the Container App
#              when a new image is pushed.
#   Job      - Scheduled Container Apps Job that rebuilds and redeploys nightly
#              using a managed identity (no PAT required).
#
# Usage:
#   ./imagedeployautomationscripts.ps1 -ResourceGroup rg-openclaw -Option AcrTask -GitHubPAT <pat>
#   ./imagedeployautomationscripts.ps1 -ResourceGroup rg-openclaw -Option Webhook
#   ./imagedeployautomationscripts.ps1 -ResourceGroup rg-openclaw -Option Job
#   # npm variant: pass the matching deployment name
#   ./imagedeployautomationscripts.ps1 -ResourceGroup rg-openclawnpm -DeploymentName mainnpm -Option Webhook
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [ValidateSet("AcrTask", "Webhook", "Job")] [string] $Option,
    [string] $DeploymentName = "main",   # Bicep deployment name (use "mainnpm" for the npm variant)
    [string] $GitHubPAT = ""
)

$ErrorActionPreference = "Stop"

# Verify the previous az CLI call succeeded; throw with context otherwise.
function Assert-LastExit {
    param([Parameter(Mandatory)] [string] $Step)
    if ($LASTEXITCODE -ne 0) { throw "Failed: $Step (az exit code $LASTEXITCODE)" }
}

# ---------------------------------------------------------------------------
# Resource discovery (shared by all options)
# ---------------------------------------------------------------------------
Write-Host "Discovering resources in '$ResourceGroup'..." -ForegroundColor Cyan

# Discover resource names from Bicep deployment outputs
$AcrName = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.acrName.value" -o tsv 2>$null
$AppName = az deployment group show --resource-group $ResourceGroup --name $DeploymentName `
    --query "properties.outputs.appName.value" -o tsv 2>$null

if (-not $AcrName -or -not $AppName) {
    throw "Could not discover ACR or App name from deployment outputs. Was deployment '$DeploymentName' run in '$ResourceGroup'?"
}

# Discover Container Apps environment name
$envId = az containerapp show --name $AppName --resource-group $ResourceGroup `
    --query "properties.managedEnvironmentId" -o tsv 2>$null
if (-not $envId) { throw "Failed to get environment ID for $AppName" }
$envName = $envId.Split("/")[-1]

# Discover the subscription ID for fully-qualified resource URIs
$subId = az account show --query "id" -o tsv 2>$null
if (-not $subId) { throw "Failed to determine the current subscription ID. Run 'az login' first." }

Write-Host "Using built-in Consumption workload profile on environment $envName" -ForegroundColor Gray
Write-Host "  ResourceGroup: $ResourceGroup" -ForegroundColor Green
Write-Host "  ACR:           $AcrName" -ForegroundColor Green
Write-Host "  App:           $AppName" -ForegroundColor Green
Write-Host "  Environment:   $envName" -ForegroundColor Green
Write-Host "  Subscription:  $subId" -ForegroundColor Green
Write-Host "  Option:        $Option" -ForegroundColor Green

switch ($Option) {

    # -----------------------------------------------------------------------
    # Option: ACR Task (auto-build on git push — recommended)
    # ACR Tasks watch the OpenClaw GitHub repo and rebuild the image when
    # commits are pushed. A webhook then restarts the Container App.
    # -----------------------------------------------------------------------
    "AcrTask" {
        if (-not $GitHubPAT) {
            throw "Option 'AcrTask' requires -GitHubPAT (a GitHub PAT with repo read access)."
        }

        Write-Host "Creating ACR Task 'openclaw-autobuild' (commit trigger on main)..." -ForegroundColor Cyan
        az acr task create `
            --registry $AcrName `
            --name openclaw-autobuild `
            --image openclaw:latest `
            --context https://github.com/openclaw/openclaw.git `
            --file Dockerfile `
            --git-access-token $GitHubPAT `
            --commit-trigger-enabled true `
            --branch main
        Assert-LastExit "create ACR task openclaw-autobuild"

        Write-Host "Creating ACR Task 'openclaw-scheduled-build' (daily at 06:00 UTC)..." -ForegroundColor Cyan
        az acr task create `
            --registry $AcrName `
            --name openclaw-scheduled-build `
            --image openclaw:latest `
            --context https://github.com/openclaw/openclaw.git `
            --file Dockerfile `
            --git-access-token $GitHubPAT `
            --schedule "0 6 * * *" `
            --commit-trigger-enabled false
        Assert-LastExit "create ACR task openclaw-scheduled-build"

        Write-Host "Pointing the Container App at openclaw:latest (continuous deployment)..." -ForegroundColor Cyan
        az containerapp update `
            --name $AppName `
            --resource-group $ResourceGroup `
            --image "$AcrName.azurecr.io/openclaw:latest" `
            --workload-profile-name "Consumption"
        Assert-LastExit "update Container App image"

        Write-Host "Creating ACR webhook 'restartApp'..." -ForegroundColor Cyan
        $restartUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$AppName/restart?api-version=2023-05-01"
        az acr webhook create `
            --registry $AcrName `
            --name restartApp `
            --actions push `
            --scope "openclaw:latest" `
            --uri $restartUri
        Assert-LastExit "create ACR webhook restartApp"

        Write-Host "ACR Task automation configured." -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # Option: ACR webhook only — restart the Container App on image push.
    # -----------------------------------------------------------------------
    "Webhook" {
        Write-Host "Creating ACR webhook 'restartApp'..." -ForegroundColor Cyan
        $restartUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$AppName/restart?api-version=2023-05-01"
        az acr webhook create `
            --registry $AcrName `
            --name restartApp `
            --actions push `
            --scope "openclaw:latest" `
            --uri $restartUri
        Assert-LastExit "create ACR webhook restartApp"

        Write-Host "Webhook configured." -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # Option: Azure Container Apps Job (scheduled nightly rebuild + redeploy)
    # Runs via managed identity using a custom image with az CLI and git.
    # -----------------------------------------------------------------------
    "Job" {
        Write-Host "Creating scheduled Container Apps Job 'openclaw-updater' (daily at 03:00 UTC)..." -ForegroundColor Cyan
        az containerapp job create `
            --name openclaw-updater `
            --resource-group $ResourceGroup `
            --environment $envName `
            --image mcr.microsoft.com/azure-cli:latest `
            --trigger-type Schedule `
            --cron-expression "0 3 * * *" `
            --cpu 1.0 --memory 2Gi `
            --workload-profile-name "Consumption" `
            --command "bash" "-c" `
            "az login --identity && az acr build --registry $AcrName --image openclaw:latest --file Dockerfile https://github.com/openclaw/openclaw.git && az containerapp update --name $AppName --resource-group $ResourceGroup --image $AcrName.azurecr.io/openclaw:latest"
        Assert-LastExit "create Container Apps job openclaw-updater"

        Write-Host "Scheduled job configured." -ForegroundColor Green
    }
}


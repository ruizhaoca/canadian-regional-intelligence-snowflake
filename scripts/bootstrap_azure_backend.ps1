[CmdletBinding()]
param(
    [string]$Location = "eastus",
    [string]$ResourceGroup = "rg-cri-tfstate-eastus",
    [string]$Container = "tfstate"
)

$ErrorActionPreference = "Stop"

$account = az account show --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not authenticated. Run az login first."
}

$subscriptionToken = $account.id.Replace("-", "").Substring(0, 8).ToLowerInvariant()
$storageAccount = "stcritfstate$subscriptionToken"
$storageScope = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount"

$requiredProviders = @(
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.EventGrid",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Storage"
)

foreach ($providerNamespace in $requiredProviders) {
    $registrationState = az provider show `
        --namespace $providerNamespace `
        --query registrationState `
        --output tsv
    if ($registrationState -ne "Registered") {
        Write-Host "Registering $providerNamespace"
        az provider register --namespace $providerNamespace --only-show-errors | Out-Null
    }
}

for ($attempt = 1; $attempt -le 30; $attempt++) {
    $pendingProviders = @(
        foreach ($providerNamespace in $requiredProviders) {
            $registrationState = az provider show `
                --namespace $providerNamespace `
                --query registrationState `
                --output tsv
            if ($registrationState -ne "Registered") { $providerNamespace }
        }
    )
    if ($pendingProviders.Count -eq 0) { break }
    Write-Host "Waiting for provider registration: $($pendingProviders -join ', ')"
    Start-Sleep -Seconds 5
}

if ($pendingProviders.Count -ne 0) {
    throw "Azure providers did not finish registering: $($pendingProviders -join ', ')"
}

az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags project=canadian-regional-intelligence managed_by=bootstrap `
    --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create the Terraform state resource group." }

az storage account create `
    --name $storageAccount `
    --resource-group $ResourceGroup `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create the Terraform state storage account." }

az storage account blob-service-properties update `
    --account-name $storageAccount `
    --resource-group $ResourceGroup `
    --enable-versioning true `
    --only-show-errors | Out-Null

az role assignment create `
    --assignee $account.user.name `
    --role "Storage Blob Data Contributor" `
    --scope $storageScope `
    --only-show-errors | Out-Null

az storage container create `
    --name $Container `
    --account-name $storageAccount `
    --auth-mode login `
    --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "The role assignment can take several minutes to propagate. Re-run this script."
}

[pscustomobject]@{
    subscription_id      = $account.id
    tenant_id            = $account.tenantId
    resource_group_name  = $ResourceGroup
    storage_account_name = $storageAccount
    container_name       = $Container
} | ConvertTo-Json

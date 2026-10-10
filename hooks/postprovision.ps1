#Requires -Version 7.3
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Wait-ArcBoxDeployment -TimeoutMinutes (Get-ArcBoxTimeoutMinutes)

$client = $env:ARCBOX_CLIENT_VM_NAME
Write-Host "Client VM: $client"
Write-Host "Username: $env:ARCBOX_CLIENT_USERNAME"
Write-Host "Resource group: https://portal.azure.com/#resource/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZURE_RESOURCE_GROUP/overview"
Write-Host "Retrieve the administrator password from the 'windowsAdminPassword' secret in this resource group's Key Vault."

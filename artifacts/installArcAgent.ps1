 # Download the package
 param (
    [string]$accessToken,
    [string]$tenantId,
    [string]$subscriptionId,
    [string]$resourceGroup,
    [string]$Azurelocation
)

 $ErrorActionPreference = 'Stop'
 $agentPath = "$Env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
 if (Test-Path $agentPath) {
     $agentInfo = & $agentPath show --json | ConvertFrom-Json
     if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the existing Azure Arc agent.' }
     if ($agentInfo.status -eq 'Connected') {
         if ($agentInfo.subscriptionId -ne $subscriptionId -or $agentInfo.resourceGroup -ne $resourceGroup) {
             throw 'Existing Azure Arc connection belongs to a different subscription or resource group.'
         }
         Write-Output 'Azure Arc agent already connected to the requested resource group.'
         return
     }
 }

 if (-not (Test-Path $agentPath)) {
     $ProgressPreference = 'SilentlyContinue'
     Invoke-WebRequest -Uri https://aka.ms/AzureConnectedMachineAgent -OutFile AzureConnectedMachineAgent.msi -TimeoutSec 900
     $installer = Start-Process -FilePath msiexec.exe -ArgumentList @("/i", "AzureConnectedMachineAgent.msi", "/l*v", "installationlog.txt", "/qn") -PassThru
     if (-not $installer.WaitForExit(900000)) {
         Stop-Process -Id $installer.Id -Force -ErrorAction Stop
         throw 'Azure Arc agent installation exceeded the 15-minute limit.'
     }
     $installer.Refresh()
     $exitCode = $installer.ExitCode
     if ($exitCode -notin @(0, 3010)) {
     $message=(net helpmsg $exitCode)
     throw "Installation failed: $message See installationlog.txt for additional details."
     }
 }

 # Run connect command
 & "$Env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" connect `
 --access-token $accessToken `
 --resource-group $resourceGroup `
 --tenant-id $tenantId `
 --location $Azurelocation `
 --subscription-id $subscriptionId `
 --cloud "AzureCloud" `
 --correlation-id "d009f5dd-dba8-4ac7-bac9-b54ef3a6671a" # Do no change!

 if ($LastExitCode -ne 0) { throw "Azure Arc agent connection failed with exit code $LastExitCode." }
 Write-Host -ForegroundColor yellow "To view your onboarded server(s), navigate to https://ms.portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.HybridCompute%2Fmachines"
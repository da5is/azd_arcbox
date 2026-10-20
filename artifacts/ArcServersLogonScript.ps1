$ErrorActionPreference = $env:ErrorActionPreference

$Env:ArcBoxDir = 'C:\ArcBox'
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = 'F:\Virtual Machines'
$Env:ArcBoxIconDir = "$Env:ArcBoxDir\Icons"
$Env:ArcBoxTestsDir = "$Env:ArcBoxDir\Tests"
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$agentScript = "$Env:ArcBoxDir\agentScript"

# Set variables to execute remote powershell scripts on guest VMs
$nestedVMArcBoxDir = $Env:ArcBoxDir
$tenantId = $env:tenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup
$resourceTags = $env:resourceTags
$namingPrefix = $env:namingPrefix
if ($env:flavor -in @('ITPro', 'DataOps')) {
    . "$env:ArcBoxDir\ArcBoxServerManagement.ps1"
}

function Set-ArcBoxWindowsGuestPassword {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Password
    )

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('Administrator', $securePassword)
    try {
        Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock { $null = hostname } -ErrorAction Stop | Out-Null
        return $credential
    } catch {
        # Prebuilt Windows VHDs ship with this password; use it only to rotate their Administrator account.
        $bootstrapPassword = ConvertTo-SecureString 'JS123!!' -AsPlainText -Force
        $bootstrapCredential = [System.Management.Automation.PSCredential]::new('Administrator', $bootstrapPassword)
        try {
            Invoke-Command -VMName $VMName -Credential $bootstrapCredential -ArgumentList $Password -ScriptBlock {
                param([string]$NewPassword)
                $secureNewPassword = ConvertTo-SecureString $NewPassword -AsPlainText -Force
                Set-LocalUser -Name 'Administrator' -Password $secureNewPassword -ErrorAction Stop
            } -ErrorAction Stop
        } catch {
            throw "Could not verify or set the shared password on Windows guest '$VMName'. Verify the guest is running and its local Administrator account is available. Guest error: $($_.Exception.Message)"
        }
    }
    return $credential
}

function Save-ArcBoxGuestDisk {
    param([string]$SourceName, [string]$DestinationPath)

    if (Test-Path -LiteralPath $DestinationPath) {
        Write-Host "Reusing guest disk $DestinationPath."
        return
    }
    $attachedDisks = @(Get-VM -ErrorAction Stop | Get-VMHardDiskDrive -ErrorAction Stop)
    if ($attachedDisks.Path -contains $DestinationPath) {
        throw "Refusing to download over an attached guest disk: $DestinationPath."
    }
    $temporaryPath = "$DestinationPath.download"
    try {
        azcopy cp ($vhdSourceFolder.TrimEnd('*') + $SourceName) $temporaryPath --overwrite=true --check-length=true --log-level=ERROR
        if ($LASTEXITCODE -ne 0) {
            throw "Guest VHD download failed for $SourceName (AzCopy exit code $LASTEXITCODE)."
        }
        if (-not (Test-Path -LiteralPath $temporaryPath) -or (Get-Item -LiteralPath $temporaryPath).Length -eq 0) {
            throw "Guest VHD download produced no data for $SourceName."
        }
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Set-ArcBoxGuestLifecycle {
    param([Parameter(Mandatory)][string]$VMName)

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.AutomaticStopAction -eq 'ShutDown' -and $vm.AutomaticStartAction -eq 'Start') {
        return
    }
    if ($vm.State -notin @('Running', 'Off')) {
        throw "Cannot configure lifecycle policies for $VMName in state '$($vm.State)'."
    }
    $restart = $vm.State -eq 'Running' -and $vm.AutomaticStopAction -ne 'ShutDown'
    try {
        if ($restart) {
            Write-Host "Gracefully shutting down $VMName to configure its automatic stop policy."
            $job = Stop-VM -Name $VMName -AsJob -ErrorAction Stop
            try {
                if (-not (Wait-Job -Job $job -Timeout 180)) {
                    throw "Timed out waiting for $VMName to shut down; refusing to force power off."
                }
                Receive-Job -Job $job -ErrorAction Stop | Out-Null
            } finally {
                if ($job.State -in @('Running', 'NotStarted')) {
                    Stop-Job -Job $job -ErrorAction Stop
                }
                Remove-Job -Job $job -ErrorAction Stop
            }
            if ((Get-VM -Name $VMName -ErrorAction Stop).State -ne 'Off') {
                throw "$VMName did not shut down; refusing to modify its stop policy."
            }
        }
        Set-VM -Name $VMName -AutomaticStopAction ShutDown -AutomaticStartAction Start -ErrorAction Stop
    } finally {
        if ($restart -and (Get-VM -Name $VMName -ErrorAction Stop).State -eq 'Off') {
            Start-VM -Name $VMName -ErrorAction Stop | Out-Null
        }
    }
}

function Install-ArcBoxSqlExtension {
    param(
        [Parameter(Mandatory)][string]$MachineName,
        [Parameter(Mandatory)][ValidateSet('Paid', 'LicenseOnly')][string]$LicenseType
    )

    $extensionsUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$MachineName/extensions?api-version=2024-07-10"
    $state = az rest --method get --url $extensionsUrl --query "value[?name=='WindowsAgent.SqlServer'].properties.provisioningState | [0]" --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list SQL extensions on $MachineName (Azure CLI exit code $LASTEXITCODE)."
    }
    if ($state -eq 'Succeeded') {
        Write-Host "SQL Server extension already installed on $MachineName; preserving its license and settings."
        return
    }
    if ($state -in @('Failed', 'Canceled')) {
        throw "SQL extension on $MachineName entered state '$state'. Repair the existing extension without overwriting its license settings."
    }
    if ([string]::IsNullOrWhiteSpace($state)) {
        $settingsPath = Join-Path $Env:ArcBoxDir "SqlExtension-$MachineName.json"
        @{
            LicenseType = $LicenseType
            SqlManagement = @{ IsEnabled = $true }
        } | ConvertTo-Json -Depth 3 | Set-Content -Path $settingsPath -Encoding utf8 -ErrorAction Stop
        try {
            # A settings file avoids JSON quote loss through az.cmd on Windows.
            az connectedmachine extension create --subscription $subscriptionId --machine-name $MachineName --name 'WindowsAgent.SqlServer' --resource-group $resourceGroup --type 'WindowsAgent.SqlServer' --publisher 'Microsoft.AzureData' --settings "@$settingsPath" --tags $resourceTags --location $azureLocation --only-show-errors --no-wait
            if ($LASTEXITCODE -ne 0) {
                throw "SQL extension creation failed on $MachineName (Azure CLI exit code $LASTEXITCODE)."
            }
        } finally {
            Remove-Item -LiteralPath $settingsPath -Force
        }
    }

    $deadline = (Get-Date).AddMinutes(15)
    do {
        $state = az rest --method get --url $extensionsUrl --query "value[?name=='WindowsAgent.SqlServer'].properties.provisioningState | [0]" --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read SQL extension status on $MachineName (Azure CLI exit code $LASTEXITCODE)."
        }
        if ($state -eq 'Succeeded') {
            Write-Host "SQL Server extension installed successfully on $MachineName."
            return
        }
        if ($state -in @('Failed', 'Canceled')) {
            throw "SQL extension on $MachineName entered state '$state'."
        }
        Write-Host "Waiting for SQL Server extension on $MachineName (state: $state)."
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for SQL Server extension on $MachineName (last state: $state)."
}

# Moved VHD storage account details here to keep only in place to prevent duplicates.
$vhdSourceFolder = 'https://jumpstartprodsg.blob.core.windows.net/arcbox/prod/*'

# Archive existing log file and create new one
$logFilePath = "$Env:ArcBoxLogsDir\ArcServersLogonScript.log"
if (Test-Path $logFilePath) {
    $archivefile = "$Env:ArcBoxLogsDir\ArcServersLogonScript-" + (Get-Date -Format 'yyyyMMddHHmmss')
    Rename-Item -Path $logFilePath -NewName $archivefile -Force
}

Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

try {
# Remove registry keys that are used to automatically logon the user (only used for first-time setup)
$registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$keys = @('AutoAdminLogon', 'DefaultUserName', 'DefaultPassword')

foreach ($key in $keys) {
    try {
        $property = Get-ItemProperty -Path $registryPath -Name $key -ErrorAction Stop
        Remove-ItemProperty -Path $registryPath -Name $key
        Write-Host "Removed registry key that are used to automatically logon the user: $key"
    } catch {
        Write-Verbose "Key $key does not exist."
    }
}

# Create desktop shortcut for Logs-folder
$WshShell = New-Object -ComObject WScript.Shell
$LogsPath = 'C:\ArcBox\Logs'
$Shortcut = $WshShell.CreateShortcut("$Env:USERPROFILE\Desktop\Logs.lnk")
$Shortcut.TargetPath = $LogsPath
$shortcut.WindowStyle = 3
$shortcut.Save()

# Configure Windows Terminal as the default terminal application
$registryPath = 'HKCU:\Console\%%Startup'

if (Test-Path $registryPath) {
    Set-ItemProperty -Path $registryPath -Name 'DelegationConsole' -Value '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    Set-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -Value '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
} else {
    New-Item -Path $registryPath -Force | Out-Null
    Set-ItemProperty -Path $registryPath -Name 'DelegationConsole' -Value '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    Set-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -Value '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
}


################################################
# Setup Hyper-V server before deploying VMs for each flavor
################################################
if ($Env:flavor -ne 'DevOps') {
    # Install and configure DHCP service (used by Hyper-V nested VMs)
    Write-Host 'Configuring DHCP Service'
    $dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq 'Ethernet' }
    $dhcpScope = Get-DhcpServerv4Scope
    if ($dhcpScope.Name -ne 'ArcBox') {
        Add-DhcpServerv4Scope -Name 'ArcBox' `
            -StartRange 10.10.1.100 `
            -EndRange 10.10.1.200 `
            -SubnetMask 255.255.255.0 `
            -LeaseDuration 1.00:00:00 `
            -State Active
    }

    $dhcpOptions = Get-DhcpServerv4OptionValue
    if ($dhcpOptions.Count -lt 3) {
        Set-DhcpServerv4OptionValue -ComputerName localhost `
            -DnsDomain $dnsClient.ConnectionSpecificSuffix `
            -DnsServer 168.63.129.16, 10.16.2.100 `
            -Router 10.10.1.1 `
            -Force
    }

    # Set custom DNS if flaver is DataOps
    if ($Env:flavor -eq 'DataOps') {
        Add-DhcpServerInDC -DnsName "$namingPrefix-client.jumpstart.local"
        Restart-Service dhcpserver
    }

    # Create the NAT network
    Write-Host 'Creating Internal NAT'
    $natName = 'InternalNat'
    $netNat = Get-NetNat
    if ($netNat.Name -ne $natName) {
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.1.0/24
    }

    Write-Host 'Preparing VM credentials'
    $nestedWindowsUsername = 'Administrator'

    # Creating Hyper-V Manager desktop shortcut
    Write-Host 'Creating Hyper-V Shortcut'
    Copy-Item -Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk' -Destination 'C:\Users\All Users\Desktop' -Force

    $cliDir = New-Item -Path "$Env:ArcBoxDir\.cli\" -Name '.servers' -ItemType Directory -Force
    if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
        $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
        $folder.Attributes += [System.IO.FileAttributes]::Hidden
    }

    # Install Azure CLI extensions
    Write-Header 'Az CLI extensions'

    az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

    @('ssh', 'log-analytics-solution', 'connectedmachine', 'monitor-control-service') |
    ForEach-Object -Parallel {
        az extension add --name $PSItem --yes --only-show-errors
    }

    # Required for CLI commands
    Write-Header 'Az CLI Login'
    az login --identity
    az account set -s $subscriptionId

    Write-Header 'Az PowerShell Login'
    Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId

    $keyVault = Get-AzKeyVault -ResourceGroupName $resourceGroup -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $keyVault) {
        throw "Could not find the ArcBox Key Vault in resource group '$resourceGroup'."
    }
    $nestedGuestPassword = Get-AzKeyVaultSecret -VaultName $keyVault.VaultName -Name 'windowsAdminPassword' -AsPlainText -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($nestedGuestPassword)) {
        throw "Key Vault '$($keyVault.VaultName)' returned an empty windowsAdminPassword; nested guest setup cannot continue."
    }

    $DeploymentProgressString = 'Started ArcServersLogonScript'

    $tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

    if ($null -ne $tags) {
        $tags.Remove('DeploymentStatus')
        $tags['DeploymentProgress'] = $DeploymentProgressString
    } else {
        $tags = @{'DeploymentProgress' = $DeploymentProgressString }
    }

    $null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
    $null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

    $existingVMDisk = Get-AzDisk -ResourceGroupName $env:resourceGroup | Where-Object name -Like *VMsDisk

    # Update disk IOPS and throughput before downloading nested VMs
    az disk update --resource-group $env:resourceGroup --name $existingVMDisk.Name --disk-iops-read-write 80000 --disk-mbps-read-write 1200

    # Enable defender for cloud for SQL Server
    # Get workspace information
    $workspaceResourceID = (az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $Env:workspaceName --query 'id' -o tsv)

    # Before deploying ArcBox SQL set resource group tag ArcSQLServerExtensionDeployment=Disabled to opt out of automatic SQL onboarding
    az tag update --resource-id "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" --operation Merge --tags ArcSQLServerExtensionDeployment=Disabled
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to merge the SQL auto-onboarding opt-out tag (Azure CLI exit code $LASTEXITCODE)."
    }

    $vhdImageToDownload = 'ArcBox-SQL-DEV.vhdx'
    if ($Env:sqlServerEdition -eq 'Standard') {
        $vhdImageToDownload = 'ArcBox-SQL-STD.vhdx'
    } elseif ($Env:sqlServerEdition -eq 'Enterprise') {
        $vhdImageToDownload = 'ArcBox-SQL-ENT.vhdx'
    }


    $DeploymentProgressString = 'Downloading and configuring nested SQL VM'

    $tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

    if ($null -ne $tags) {
        $tags['DeploymentProgress'] = $DeploymentProgressString
    } else {
        $tags = @{'DeploymentProgress' = $DeploymentProgressString }
    }

    $null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
    $null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

    Write-Host 'Fetching SQL VM'
    $SQLvmName = 'win22sql22'
    $SQLvmvhdPath = "$Env:ArcBoxVMDir\$namingPrefix-SQL.vhdx"

    # Verify if VHD files already downloaded especially when re-running this script
    Save-ArcBoxGuestDisk -SourceName $vhdImageToDownload -DestinationPath $SQLvmvhdPath

    # Create the nested VMs if not already created
    Write-Header 'Create Hyper-V VMs'

    # Create the nested SQL VMs
    $sqlDscConfigurationFile = "$Env:ArcBoxDscDir\virtual_machines_sql.dsc.yml"
    (Get-Content -Path $sqlDscConfigurationFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $sqlDscConfigurationFile
    winget configure --file C:\ArcBox\DSC\virtual_machines_sql.dsc.yml --accept-configuration-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "SQL guest configuration failed (WinGet exit code $LASTEXITCODE)."
    }

    # Restarting Windows VM Network Adapters
    Write-Host 'Restarting Network Adapters'
    $winCreds = Set-ArcBoxWindowsGuestPassword -VMName $SQLvmName -Password $nestedGuestPassword
    Start-Sleep -Seconds 5
    Invoke-Command -VMName $SQLvmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
    Start-Sleep -Seconds 20

    # Rename the prebuilt SQL guest to its OS and SQL Server version name.
    $hostname = Invoke-Command -VMName $SQLvmName -ScriptBlock { hostname } -Credential $winCreds

    if ($hostname -ne $SQLvmName) {

        Write-Header 'Renaming the nested SQL VM'
        Invoke-Command -VMName $SQLvmName -ScriptBlock { Rename-Computer -NewName $using:SQLvmName -Restart } -Credential $winCreds

        Get-VM *SQL* | Wait-VM -For IPAddress

        Write-Host 'Waiting for the nested Windows SQL VM to come back online...waiting for 30 seconds'
        Start-Sleep -Seconds 30

        # Wait for VM to start again
        while ((Get-VM -vmName $SQLvmName).State -ne 'Running') {
            Write-Host 'Waiting for VM to start...'
            Start-Sleep -Seconds 5
        }

        Write-Host 'VM has rebooted successfully!'
    }

    if ($env:flavor -eq 'ITPro') {
        Set-ArcBoxWindowsActivation -VMName $SQLvmName -Credential $winCreds
    }

    # Enable Windows Firewall rule for SQL Server
    Invoke-Command -VMName $SQLvmName -ScriptBlock { New-NetFirewallRule -DisplayName 'Allow SQL Server TCP 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow } -Credential $winCreds

    # Download SQL assessment preparation script
    Invoke-WebRequest ($Env:templateBaseUrl + 'artifacts/prepareSqlServerForAssessment.ps1') -OutFile $nestedVMArcBoxDir\prepareSqlServerForAssessment.ps1
    Copy-VMFile $SQLvmName -SourcePath "$Env:ArcBoxDir\prepareSqlServerForAssessment.ps1" -DestinationPath "$nestedVMArcBoxDir\prepareSqlServerForAssessment.ps1" -CreateFullPath -FileSource Host -Force
    Invoke-Command -VMName $SQLvmName -ScriptBlock { powershell -File $Using:nestedVMArcBoxDir\prepareSqlServerForAssessment.ps1 } -Credential $winCreds
    Invoke-Command -VMName $SQLvmName -Credential $winCreds -ArgumentList $nestedGuestPassword -ScriptBlock {
        param([string]$Password)
        Import-Module SqlServer -Force -ErrorAction Stop
        $server = New-Object Microsoft.SqlServer.Management.Smo.Server('.')
        $login = $server.Logins['sa']
        if ($null -eq $login) {
            throw "The SQL Server 'sa' login was not found."
        }
        $login.ChangePassword($Password)
    } -ErrorAction Stop

    # Copy installation script to nested Windows VMs
    Write-Output 'Transferring installation script to nested Windows VMs...'
    Copy-VMFile $SQLvmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force

    Write-Header 'Onboarding Arc-enabled servers'

    # Onboarding the nested VMs as Azure Arc-enabled servers
    Write-Output 'Onboarding the nested Windows VMs as Azure Arc-enabled servers'
    $accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
    Invoke-Command -VMName $SQLvmName -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        & "$Using:nestedVMArcBoxDir\installArcAgent.ps1" -accessToken $using:accessToken -tenantId $Using:tenantId -subscriptionId $Using:subscriptionId -resourceGroup $Using:resourceGroup -azureLocation $Using:azureLocation
    } -Credential $winCreds -ErrorAction Stop

    # Wait for the Arc-enabled server installation to be completed
    $retryCount = 0
    do {
        $ArcServer = Get-AzConnectedMachine -Name $SQLvmName -ResourceGroupName $resourceGroup
        if (($null -ne $ArcServer) -and ($ArcServer.ProvisioningState -eq 'Succeeded')) {
            Write-Host 'Onboarding the nested SQL VM as Azure Arc-enabled server successful.'
            $azConnectedMachineId = $ArcServer.Id
            break;
        } else {
            $retryCount = $retryCount + 1
            if ($retryCount -gt 5) {
                Write-Host "WARNING: Timeout exceeded for onboarding nested SQL VM as Azure Arc-enabled server ... Retry count: $retryCount."
                throw 'Timed out onboarding the nested SQL VM.'
            } else {
                Write-Host "Waiting for onboarding nested SQL VM as Azure Arc-enabled server ... Retry count: $retryCount"
                Start-Sleep(30)
            }
        }
    } while ($retryCount -le 5)

    # Create SQL server extension as policy to auto deployment is disabled
    Write-Host "Installing SQL Server extension on the Arc-enabled Server.`n"
    Install-ArcBoxSqlExtension -MachineName $SQLvmName -LicenseType Paid

    Write-Host "Installing Azure Monitoring Agent extension.`n"
    Install-ArcBoxServerExtension -MachineName $SQLvmName -Name AzureMonitorWindowsAgent -Publisher Microsoft.Azure.Monitor
    Write-Host 'Azure Monitoring Agent extension installation complete.'

    # Get access token to make ARM REST API call for SQL server BPA and migration assessments
    $token = (az account get-access-token --subscription $subscriptionId --query accessToken --output tsv)
    $headers = @{'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }

    # Create custom log analytics table for SQL assessment
    Write-Host "Creating Log Analytis workspace table for SQL best practices assessment.`n"
    az monitor log-analytics workspace table create --resource-group $resourceGroup --workspace-name $Env:workspaceName -n SqlAssessment_CL --columns RawData=string TimeGenerated=datetime --only-show-errors

    # Verify if ArcBox SQL resource is created
    Write-Host "Enabling SQL server best practices assessment.`n"
    $bpaDeploymentTemplateUrl = "$Env:templateBaseUrl/artifacts/sqlbpa.json"
    az deployment group create --resource-group $resourceGroup --template-uri $bpaDeploymentTemplateUrl --parameters workspaceName=$Env:workspaceName vmName=$SQLvmName arcSubscriptionId=$subscriptionId

    # Run Best practices assessment
    Write-Host "Execute SQL server best practices assessment.`n"

    # Wait for a minute to finish everyting and run assessment
    Start-Sleep(60)

    $armRestApiEndpoint = "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$SQLvmName/extensions/WindowsAgent.SqlServer?api-version=2019-08-02-preview"

    # Build API request payload
    $worspaceResourceId = "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.operationalinsights/workspaces/$Env:workspaceName".ToLower()
    $sqlExtensionId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$SQLvmName/extensions/WindowsAgent.SqlServer"
    $sqlbpaPayloadTemplate = "$Env:templateBaseUrl/artifacts/sqlbpa.payload.json"
    $settingsSaveTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $apiPayload = (Invoke-WebRequest -Uri $sqlbpaPayloadTemplate).Content -replace '{{RESOURCEID}}', $sqlExtensionId -replace '{{LOCATION}}', $azureLocation -replace '{{WORKSPACEID}}', $worspaceResourceId -replace '{{SAVETIME}}', $settingsSaveTime

    # Call REST API to run best practices assessment
    $httpResp = Invoke-WebRequest -Method Patch -Uri $armRestApiEndpoint -Body $apiPayload -Headers $headers
    if (($httpResp.StatusCode -eq 200) -or ($httpResp.StatusCode -eq 202)) {
        Write-Host 'Arc-enabled SQL server best practices assessment executed. Wait for assessment to complete to view results.'
    } else {
        <# Action when all if and elseif conditions are false #>
        Write-Host 'SQL Best Practices Assessment faild. Please refer troubleshooting guide to run manually.'
    }

    # Run SQL Server Azure Migration Assessment
    Write-Host "Enabling SQL Server Azure Migration Assessment.`n"
    $migrationApiURL = 'https://management.azure.com/batch?api-version=2020-06-01'
    $assessmentName = (New-Guid).Guid
    $payLoad = @"
{"requests":[{"httpMethod":"POST","name":"$assessmentName","requestHeaderDetails":{"commandName":"Microsoft_Azure_HybridData_Platform."},"url":"https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.AzureArcData/SqlServerInstances/$SQLvmName/runMigrationAssessment?api-version=2024-05-01-preview"}]}
"@

    $httpResp = Invoke-WebRequest -Method Post -Uri $migrationApiURL -Body $payLoad -Headers $headers
    if (($httpResp.StatusCode -eq 200) -or ($httpResp.StatusCode -eq 202)) {
        Write-Host 'Arc-enabled SQL server migration assessment executed. Wait for assessment to complete to view results.'
    } else {
        <# Action when all if and elseif conditions are false #>
        Write-Host 'SQL Server Migration Assessment faild. Please refer troubleshooting guide to run manually.'
    }

    #Install SQLAdvancedThreatProtection solution
    Write-Host "Installing SQLAdvancedThreatProtection Log Analytics solution.`n"
    az monitor log-analytics solution create --resource-group $resourceGroup --solution-type SQLAdvancedThreatProtection --workspace $Env:workspaceName --only-show-errors

    #Install SQLVulnerabilityAssessment solution
    Write-Host "Install SQLVulnerabilityAssessment Log Analytics solution.`n"
    az monitor log-analytics solution create --resource-group $resourceGroup --solution-type SQLVulnerabilityAssessment --workspace $Env:workspaceName --only-show-errors

    # Update Azure Monitor data collection rule template with Log Analytics workspace resource ID
    $sqlDefenderDcrFile = "$Env:ArcBoxDir\defendersqldcrtemplate.json"
    (Get-Content -Path $sqlDefenderDcrFile) -replace '{LOGANLYTICS_WORKSPACEID}', $workspaceResourceID | Set-Content -Path $sqlDefenderDcrFile

    # Create data collection rules for Defender for SQL
    Write-Host "Creating Azure Monitor data collection rule.`n"
    $dcrName = 'Jumpstart-DefenderForSQL-DCR'
    az monitor data-collection rule create --resource-group $resourceGroup --location $env:azureLocation --name $dcrName --rule-file $sqlDefenderDcrFile

    # Associate DCR with Azure Arc-enabled Server resource
    Write-Host "Creating Azure Monitor data collection rule assocation for Arc-enabled server.`n"
    $dcrRuleId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    az monitor data-collection rule association create --name "$SQLvmName" --rule-id $dcrRuleId --resource $azConnectedMachineId

    # Test Defender for SQL
    Write-Header "Simulating SQL threats to generate alerts from Defender for Cloud.`n"
    $remoteScriptFileFile = "$Env:ArcBoxDir\testDefenderForSQL.ps1"
    Copy-VMFile $SQLvmName -SourcePath "$Env:ArcBoxDir\SqlAdvancedThreatProtectionShell.psm1" -DestinationPath "$Env:ArcBoxDir\SqlAdvancedThreatProtectionShell.psm1" -CreateFullPath -FileSource Host -Force
    Copy-VMFile $SQLvmName -SourcePath "$Env:ArcBoxDir\testDefenderForSQL.ps1" -DestinationPath $remoteScriptFileFile -CreateFullPath -FileSource Host -Force
    Invoke-Command -VMName $SQLvmName -ScriptBlock { powershell -File $Using:remoteScriptFileFile } -Credential $winCreds

    # Enable least privileged access
    Write-Host "Enabling Arc-enabled SQL server least privileged access.`n"
    az sql server-arc extension feature-flag set --name LeastPrivilege --enable true --resource-group $resourceGroup --machine-name $SQLvmName

    # Enable automated backups
    Write-Host "Enabling Arc-enabled SQL server automated backups.`n"
    az sql server-arc backups-policy set --name $SQLvmName --resource-group $resourceGroup --retention-days 31 --full-backup-days 7 --diff-backup-hours 12 --tlog-backup-mins 5

    # Onboard nested Windows and Linux VMs to Azure Arc
    if ($Env:flavor -eq 'ITPro') {
        Write-Header 'Fetching Nested VMs'

        $Win19Sql16vmName = 'win19sql16'

        $Win22Sql19vmName = 'win22sql19'

        $Win25Sql25vmName = 'win25sql25'

        $Ubuntu01vmName = 'ubu24sql25'
        $Ubuntu01vmvhdPath = "${Env:ArcBoxVMDir}\$namingPrefix-Ubuntu-01.vhdx"

        $Ubuntu02vmName = 'ubu24'
        $Ubuntu02vmvhdPath = "${Env:ArcBoxVMDir}\$namingPrefix-Ubuntu-02.vhdx"
        $UbuntuVMNames = @($Ubuntu01vmName, $Ubuntu02vmName)

        $files = 'ArcBox-Win2K19.vhdx;ArcBox-Win2K22.vhdx;ArcBox-Win2K25.vhdx;ArcBox-Ubuntu-01.vhdx;ArcBox-Ubuntu-02.vhdx;'

        $DeploymentProgressString = 'Downloading and configuring nested VMs'

        $tags = Get-AzResourceGroup -Name $env:resourceGroup | Select-Object -ExpandProperty Tags

        if ($null -ne $tags) {
            $tags['DeploymentProgress'] = $DeploymentProgressString
        } else {
            $tags = @{'DeploymentProgress' = $DeploymentProgressString }
        }

        $null = Set-AzResourceGroup -ResourceGroupName $env:resourceGroup -Tag $tags
        $null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $env:resourceGroup -ResourceType 'microsoft.compute/virtualmachines' -Tag $tags -Force

        $Env:AZCOPY_BUFFER_GB = 4
        foreach ($file in ($files -split ';' | Where-Object { $_ })) {
            $destinationPath = Join-Path $Env:ArcBoxVMDir ($file -replace '^ArcBox', $namingPrefix)
            Save-ArcBoxGuestDisk -SourceName $file -DestinationPath $destinationPath
        }

        # Update disk IOPS and throughput after downloading nested VMs (note: a disk's performance tier can be downgraded only once every 12 hours)
        az disk update --resource-group $env:resourceGroup --name $existingVMDisk.Name --disk-iops-read-write $existingVMDisk.DiskIOPSReadWrite --disk-mbps-read-write $existingVMDisk.DiskMBpsReadWrite

        # Create the nested VMs if not already created
        Write-Header 'Create Hyper-V VMs'
        $serversDscConfigurationFile = "$Env:ArcBoxDscDir\virtual_machines_itpro.dsc.yml"
        (Get-Content -Path $serversDscConfigurationFile) -replace 'namingPrefixStage', $namingPrefix | Set-Content -Path $serversDscConfigurationFile
        winget configure --file C:\ArcBox\DSC\virtual_machines_itpro.dsc.yml --accept-configuration-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            throw "ITPro guest configuration failed (WinGet exit code $LASTEXITCODE)."
        }

        foreach ($vmName in @($SQLvmName, $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName, $Ubuntu01vmName, $Ubuntu02vmName)) {
            Set-ArcBoxGuestLifecycle -VMName $vmName
        }

        Write-Header 'Creating VM Credentials'
        # Use the shared ArcBox password for all nested guest accounts.
        $nestedLinuxUsername = 'jumpstart'
        foreach ($vmName in @($Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)) {
            $null = Set-ArcBoxWindowsGuestPassword -VMName $vmName -Password $nestedGuestPassword
        }

        # Restarting Windows VM Network Adapters
        Write-Header 'Restarting Network Adapters'
        Start-Sleep -Seconds 5
        Invoke-Command -VMName $Win19Sql16vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
        Invoke-Command -VMName $Win22Sql19vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
        Invoke-Command -VMName $Win25Sql25vmName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
        Start-Sleep -Seconds 10

        # Rename the nested Windows guests to names that include their OS and SQL Server versions.
        Write-Header 'Renaming the nested Windows VMs'
        $windowsVMNames = @($Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)
        $windowsVMsToRestart = foreach ($vmName in $windowsVMNames) {
            $renameRequired = Invoke-Command -VMName $vmName -ScriptBlock {
                if ($env:computername -ine $using:vmName) {
                    Rename-Computer -NewName $using:vmName | Out-Null
                    $true
                } else {
                    $false
                }
            } -Credential $winCreds
            if ($renameRequired) {
                $vmName
            }
        }

        Write-Host 'Waiting for the nested Windows VMs to come back online...'

        if ($windowsVMsToRestart) {
            Restart-VM -Name $windowsVMsToRestart -Force
        }
        Get-VM -Name $windowsVMNames | Wait-VM -For Heartbeat -Timeout 600 -ErrorAction Stop

        # Getting the Ubuntu nested VM IP address
        $Ubuntu01VmIp = Get-VM -Name $Ubuntu01vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0
        $Ubuntu02VmIp = Get-VM -Name $Ubuntu02vmName | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses | Select-Object -Index 0

        # Configuring SSH for accessing Linux VMs
        Write-Output 'Generating SSH key for accessing nested Linux VMs'

        $null = New-Item -Path ~ -Name .ssh -ItemType Directory -Force
        if (-not (Test-Path "$Env:USERPROFILE\.ssh\id_rsa")) {
            ssh-keygen -t rsa -N '' -f $Env:USERPROFILE\.ssh\id_rsa
            if ($LASTEXITCODE -ne 0) { throw 'Failed to generate the nested guest SSH key.' }
        }
        if (-not (Test-Path "$Env:USERPROFILE\.ssh\id_rsa.pub")) {
            throw 'The nested guest SSH public key is missing; preserve the private key and recover its public key before retrying.'
        }

        Copy-Item -Path "$Env:USERPROFILE\.ssh\id_rsa.pub" -Destination "$Env:TEMP\authorized_keys"

        # Automatically accept unseen keys but will refuse connections for changed or invalid hostkeys.
        Add-Content -Path "$Env:USERPROFILE\.ssh\config" -Value 'StrictHostKeyChecking=accept-new'

        Get-VM -Name $UbuntuVMNames | Wait-VM -For Heartbeat -Timeout 600 -ErrorAction Stop
        Copy-ArcBoxLinuxGuestFile -VMName $UbuntuVMNames -SourcePath "$Env:TEMP\authorized_keys" -DestinationDirectory "/home/$nestedLinuxUsername/.ssh"

        foreach ($guest in @(
            @{ Name = $Ubuntu01vmName; IP = $Ubuntu01VmIp },
            @{ Name = $Ubuntu02vmName; IP = $Ubuntu02VmIp }
        )) {
            Invoke-Command -HostName $guest.IP -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername -ArgumentList $guest.Name -ErrorAction Stop -ScriptBlock {
                param([string]$Name)
                $output = sudo -n hostnamectl set-hostname $Name 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Could not rename the Ubuntu guest: $($output -join ' ')" }
                $output = sudo -n systemctl enable --now ssh 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Could not enable Ubuntu OpenSSH: $($output -join ' ')" }
            }
        }

        Get-VM -Name $UbuntuVMNames | Wait-VM -For IPAddress -Timeout 600 -ErrorAction Stop

        Write-Host 'Waiting for the nested Linux VMs to come back online...waiting for 10 seconds'

        Start-Sleep -Seconds 10

        # Copy installation script to nested Windows VMs
        Write-Output 'Transferring installation script to nested Windows VMs...'
        Copy-VMFile $Win19Sql16vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
        Copy-VMFile $Win22Sql19vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
        Copy-VMFile $Win25Sql25vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force
        Copy-VMFile $Win19Sql16vmName -SourcePath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -DestinationPath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -CreateFullPath -FileSource Host -Force
        Copy-VMFile $Win22Sql19vmName -SourcePath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -DestinationPath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -CreateFullPath -FileSource Host -Force
        Copy-VMFile $Win25Sql25vmName -SourcePath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -DestinationPath "$Env:ArcBoxDir\InstallNestedSqlServer.ps1" -CreateFullPath -FileSource Host -Force

        Write-Header 'Installing SQL Server on nested Windows VMs'
        $sqlMode = if ([string]::IsNullOrWhiteSpace($Env:nestedSqlMode)) { 'Developer' } else { $Env:nestedSqlMode }
        foreach ($sqlGuest in @(
            @{ Name = $Win19Sql16vmName; Version = '2016' }
            @{ Name = $Win22Sql19vmName; Version = '2019' }
            @{ Name = $Win25Sql25vmName; Version = '2025' }
        )) {
            $tags = Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Select-Object -ExpandProperty Tags
            if ($null -eq $tags) { $tags = @{} }
            $tags['DeploymentProgress'] = "Installing SQL Server $($sqlGuest.Version) on $($sqlGuest.Name)"
            $null = Set-AzResourceGroup -ResourceGroupName $resourceGroup -Tag $tags -ErrorAction Stop
            Invoke-Command -VMName $sqlGuest.Name -ScriptBlock {
                param($version, $mode)
                $ErrorActionPreference = 'Stop'
                & "$Using:nestedVMArcBoxDir\InstallNestedSqlServer.ps1" -SqlVersion $version -InstallationMode $mode
            } -ArgumentList $sqlGuest.Version, $sqlMode -Credential $winCreds -ErrorAction Stop
            $restartRequired = Invoke-Command -VMName $sqlGuest.Name -Credential $winCreds -ErrorAction Stop -ScriptBlock {
                param($version)
                Test-Path "$env:ProgramData\ArcBox\SQLServer$version\RestartRequired"
            } -ArgumentList $sqlGuest.Version
            if ($restartRequired) {
                Restart-VM -Name $sqlGuest.Name -Force -ErrorAction Stop
                Get-VM -Name $sqlGuest.Name | Wait-VM -For Heartbeat -Timeout 600 -ErrorAction Stop
                $guestReady = $false
                for ($attempt = 0; $attempt -lt 60; $attempt++) {
                    try {
                        Invoke-Command -VMName $sqlGuest.Name -Credential $winCreds -ErrorAction Stop -ScriptBlock { $null = Get-Service MSSQLSERVER -ErrorAction Stop }
                        $guestReady = $true
                        break
                    } catch {
                        if ($attempt -eq 59) { throw }
                        Start-Sleep -Seconds 10
                    }
                }
                if (-not $guestReady) { throw "Guest $($sqlGuest.Name) did not become ready after SQL setup restart." }
                Invoke-Command -VMName $sqlGuest.Name -Credential $winCreds -ErrorAction Stop -ScriptBlock {
                    param($version, $mode)
                    $ErrorActionPreference = 'Stop'
                    Remove-Item "$env:ProgramData\ArcBox\SQLServer$version\RestartRequired" -Force
                    & "$Using:nestedVMArcBoxDir\InstallNestedSqlServer.ps1" -SqlVersion $version -InstallationMode $mode
                } -ArgumentList $sqlGuest.Version, $sqlMode
            }
        }

        # Update Linux VM onboarding script connect to Azure Arc, get new token as it might have been expired by the time execution reached this line.
        $accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
        (Get-Content -Path "$agentScript\installArcAgentUbuntu.sh" -Raw).Replace("`r`n", "`n") -replace '\$accessToken', $accessToken -replace '\$resourceGroup', $resourceGroup -replace '\$tenantId', $Env:tenantId -replace '\$azureLocation', $Env:azureLocation -replace '\$subscriptionId', $subscriptionId | Set-Content -Path "$agentScript\installArcAgentModifiedUbuntu.sh" -NoNewline

        # Copy installation script to nested Linux VMs
        Write-Output 'Transferring installation script to nested Linux VMs...'

        Copy-ArcBoxLinuxGuestFile -VMName $UbuntuVMNames -SourcePath "$agentScript\installArcAgentModifiedUbuntu.sh" -DestinationDirectory "/home/$nestedLinuxUsername"

        Write-Output 'Activating operating system on Windows VMs...'
        foreach ($vmName in @($Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)) {
            Set-ArcBoxWindowsActivation -VMName $vmName -Credential $winCreds
        }

        Write-Header 'Onboarding Arc-enabled servers'

        # Onboarding the nested VMs as Azure Arc-enabled servers
        Write-Output 'Onboarding the nested Windows VMs as Azure Arc-enabled servers'
        Invoke-Command -VMName $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            & "$Using:nestedVMArcBoxDir\installArcAgent.ps1" -accessToken $using:accessToken -tenantId $Using:tenantId -subscriptionId $Using:subscriptionId -resourceGroup $Using:resourceGroup -azureLocation $Using:azureLocation
        } -Credential $winCreds -ErrorAction Stop

        Write-Header 'Installing SQL Server extensions on Arc-enabled Windows VMs'
        foreach ($additionalSqlMachine in @($Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)) {
            Install-ArcBoxSqlExtension -MachineName $additionalSqlMachine -LicenseType LicenseOnly
        }

        Write-Output 'Onboarding the nested Linux VMs as an Azure Arc-enabled servers'
        $UbuntuSessions = New-PSSession -HostName $Ubuntu01VmIp, $Ubuntu02VmIp -KeyFilePath "$Env:USERPROFILE\.ssh\id_rsa" -UserName $nestedLinuxUsername -ConnectingTimeout 60000 -ErrorAction Stop
        Invoke-Command -Session $UbuntuSessions -ScriptBlock {
            param([string]$Password)
            $username = $using:nestedLinuxUsername
            "$username`:$Password" | sudo chpasswd
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to set the shared password for Linux guest user '$username'."
            }
        } -ArgumentList $nestedGuestPassword -ErrorAction Stop
        Invoke-Command -Session $UbuntuSessions -ErrorAction Stop -ScriptBlock {
            sudo -n sh "/home/$using:nestedLinuxUsername/installArcAgentModifiedUbuntu.sh" 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message } else { Write-Host ([string]$_) }
            }
            if ($LASTEXITCODE -ne 0) { throw "Linux Arc onboarding failed (exit code $LASTEXITCODE)." }
        }

        Write-Header 'Installing SQL Server 2025 on ubu24sql25'
        $null = Update-AzTag -ResourceId "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" -Operation Merge -Tag @{ DeploymentProgress = 'Installing SQL Server 2025 on ubu24sql25' } -ErrorAction Stop
        Copy-ArcBoxLinuxGuestFile -VMName $Ubuntu01vmName -SourcePath "$Env:ArcBoxDir\InstallNestedSqlServerUbuntu.sh" -DestinationDirectory "/home/$nestedLinuxUsername"
        $sqlSession = $UbuntuSessions | Where-Object ComputerName -eq $Ubuntu01VmIp
        if ($null -eq $sqlSession) { throw 'The Ubuntu SQL guest session is missing.' }
        Invoke-Command -Session $sqlSession -ArgumentList $nestedGuestPassword, $sqlMode -ErrorAction Stop -ScriptBlock {
            param([string]$Password, [string]$Mode)
            $Password | sudo -n timeout --kill-after=30s 90m bash /home/jumpstart/InstallNestedSqlServerUbuntu.sh $Mode 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message } else { Write-Host ([string]$_) }
            }
            if ($LASTEXITCODE -ne 0) { throw "Ubuntu SQL setup failed (exit code $LASTEXITCODE)." }
        }
        Install-ArcBoxServerExtension -MachineName $Ubuntu01vmName -Name 'LinuxAgent.SqlServer' -Publisher 'Microsoft.AzureData' -Settings @{
            LicenseType = 'LicenseOnly'
            SqlManagement = @{ IsEnabled = $true }
        }
        $null = Update-AzTag -ResourceId "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" -Operation Merge -Tag @{ DeploymentProgress = 'Configuring Arc inventory, SSH and OpenTelemetry' } -ErrorAction Stop
        $linuxManagementSessions = @{
            $Ubuntu01vmName = $sqlSession
            $Ubuntu02vmName = $UbuntuSessions | Where-Object ComputerName -eq $Ubuntu02VmIp
        }
        Set-ArcBoxServerManagement -WindowsMachines @($SQLvmName, $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName) -LinuxMachines $UbuntuVMNames -LinuxSessions $linuxManagementSessions
        $sshPublicKey = Get-Content "$Env:USERPROFILE\.ssh\id_rsa.pub" -Raw -ErrorAction Stop
        Invoke-Command -VMName @($SQLvmName, $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName) -Credential $winCreds -ArgumentList $sshPublicKey -ErrorAction Stop -ScriptBlock {
            param([string]$PublicKey)
            $ErrorActionPreference = 'Stop'
            $path = "$env:ProgramData\ssh\administrators_authorized_keys"
            if (-not (Test-Path -LiteralPath $path) -or (Get-Content -LiteralPath $path) -notcontains $PublicKey.Trim()) {
                Add-Content -LiteralPath $path -Value $PublicKey.Trim() -Encoding ascii
            }
            $acl = [System.Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
            }
            Set-Acl -LiteralPath $path -AclObject $acl
            Set-Service sshd -StartupType Automatic
            Start-Service sshd
            $sshRule = Get-NetFirewallRule -Name 'ArcBox-SSH' -ErrorAction SilentlyContinue
            if ($null -eq $sshRule) {
                New-NetFirewallRule -Name 'ArcBox-SSH' -DisplayName 'ArcBox SSH from lab subnet' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress '10.10.1.0/24' | Out-Null
            } else {
                $sshRule | Set-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress '10.10.1.0/24'
            }
        }

        Write-Header 'Installing Dependency Agent for Arc-enabled Windows servers'
        $VMs = @($SQLvmName, $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)
        $VMs | ForEach-Object -Parallel {

            $null = Connect-AzAccount -Identity -Tenant $using:tenantId -Subscription $using:subscriptionId -Scope Process -WarningAction SilentlyContinue

            $vm = $PSItem

            Write-Output "Invoking installation on $vm"

            # Install Dependency Agent
            $null = New-AzConnectedMachineExtension -ResourceGroupName $using:resourceGroup -MachineName $vm -Name DependencyAgentWindows -Publisher Microsoft.Azure.Monitoring.DependencyAgent -ExtensionType DependencyAgentWindows -Location $using:azureLocation -Settings @{"enableAMA" = $true} -NoWait

        }

        Write-Header 'Enabling SSH access and triggering update assessment for Arc-enabled servers'
        $VMs = @($SQLvmName, $Ubuntu01vmName, $Ubuntu02vmName, $Win19Sql16vmName, $Win22Sql19vmName, $Win25Sql25vmName)
        $VMs | ForEach-Object -Parallel {
            $null = Connect-AzAccount -Identity -Tenant $using:tenantId -Subscription $using:subscriptionId -Scope Process -WarningAction SilentlyContinue

            $vm = $PSItem
            $connectedMachine = Get-AzConnectedMachine -Name $vm -ResourceGroupName $using:resourceGroup -SubscriptionId $using:subscriptionId
            $connectedMachineEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15").Content | ConvertFrom-Json

            if (-not ($connectedMachineEndpoint.properties | Where-Object { $_.type -eq 'default' -and $_.provisioningState -eq 'Succeeded' })) {
                Write-Output "Creating default endpoint for $($connectedMachine.Name)"
                $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload '{"properties": {"type": "default"}}'
            }
            $connectedMachineSshEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15").Content | ConvertFrom-Json

            if (-not ($connectedMachineSshEndpoint.properties | Where-Object { $_.serviceName -eq 'SSH' -and $_.provisioningState -eq 'Succeeded' })) {
                Write-Output "Enabling SSH on $($connectedMachine.Name)"
                $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15" -Payload '{"properties": {"serviceName": "SSH", "port": 22}}'
            } else {
                Write-Output "SSH already enabled on $($connectedMachine.Name)"
            }

            Write-Output "Triggering Update Manager assessment on $($connectedMachine.Name)"
            $null = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$($connectedMachine.Name)/assessPatches?api-version=2020-08-15-preview" -Payload '{}'

        }
    } elseif ($Env:flavor -eq 'DataOps') {
        Write-Header 'Enabling SSH access to Arc-enabled servers'
        $null = Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId -Scope Process -WarningAction SilentlyContinue
        $connectedMachine = Get-AzConnectedMachine -Name $SQLvmName -ResourceGroupName $resourceGroup -SubscriptionId $subscriptionId
        $connectedMachineEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15").Content | ConvertFrom-Json
        if (-not ($connectedMachineEndpoint.properties | Where-Object { $_.type -eq 'default' -and $_.provisioningState -eq 'Succeeded' })) {
            Write-Output "Creating default endpoint for $($connectedMachine.Name)"
            $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default?api-version=2023-03-15" -Payload '{"properties": {"type": "default"}}'
        }

        $connectedMachineSshEndpoint = (Invoke-AzRestMethod -Method get -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15").Content | ConvertFrom-Json
        if (-not ($connectedMachineSshEndpoint.properties | Where-Object { $_.serviceName -eq 'SSH' -and $_.provisioningState -eq 'Succeeded' })) {
            Write-Output "Enabling SSH on $($connectedMachine.Name)"
            $null = Invoke-AzRestMethod -Method put -Path "$($connectedMachine.Id)/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15" -Payload '{"properties": {"serviceName": "SSH", "port": 22}}'
        } else {
            Write-Output "SSH already enabled on $($connectedMachine.Name)"
        }

        Write-Output "Triggering Update Manager assessment on $($connectedMachine.Name)"
        $null = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.HybridCompute/machines/$($connectedMachine.Name)/assessPatches?api-version=2020-08-15-preview" -Payload '{}'

    }

}

# Triggering Azure Policy compliance scan
Write-Header 'Triggering Azure Policy compliance scan'
$policyScan = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation?api-version=2019-10-01" -ErrorAction Stop
if ($policyScan.StatusCode -notin @(200, 202, 204)) {
    throw "Azure Policy scan submission failed (HTTP $($policyScan.StatusCode))."
}
Write-Host 'Azure Policy compliance scan submitted.'

#Changing to Jumpstart ArcBox wallpaper
Write-Header 'Changing wallpaper'

# bmp file is required for BGInfo
Convert-JSImageToBitMap -SourceFilePath "$Env:ArcBoxDir\wallpaper.png" -DestinationFilePath "$Env:ArcBoxDir\wallpaper.bmp"

Set-JSDesktopBackground -ImagePath "$Env:ArcBoxDir\wallpaper.bmp"

if ($Env:flavor -eq 'ITPro') {

    Write-Header 'Running tests to verify infrastructure'

    & "$Env:ArcBoxTestsDir\Invoke-Test.ps1"

}

Write-Header 'Removing Logon Task'
if ($null -ne (Get-ScheduledTask -TaskName 'ArcServersLogonScript' -ErrorAction SilentlyContinue)) {
    Unregister-ScheduledTask -TaskName 'ArcServersLogonScript' -Confirm:$false
}
} catch {
    $setupError = $_
    try {
        $tags = Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Select-Object -ExpandProperty Tags
        if ($null -eq $tags) { $tags = @{} }
        $tags['DeploymentProgress'] = 'Failed'
        $tags['DeploymentStatus'] = 'VM setup failed. Inspect C:\ArcBox\Logs\ArcServersLogonScript.log.'
        $null = Set-AzResourceGroup -ResourceGroupName $resourceGroup -Tag $tags -ErrorAction Stop
    } catch {
        Write-Warning "Could not publish VM setup failure: $($_.Exception.Message)"
    }
    throw $setupError
} finally {
    Stop-Transcript -ErrorAction Continue
}
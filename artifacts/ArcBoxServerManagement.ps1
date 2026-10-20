function Invoke-ArcBoxServerAz {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --subscription $env:subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Arc server operation '$($Arguments[0]) $($Arguments[1])' failed (Azure CLI exit code $LASTEXITCODE)."
    }
    return $result
}

function Get-ArcBoxWindowsKmsKey {
    param(
        [Parameter(Mandatory)][string]$BuildNumber,
        [Parameter(Mandatory)][string]$Caption
    )

    $keys = @{
        '17763-Standard' = 'N69G4-B89J2-4G8F4-WWYCC-J464C'
        '17763-Datacenter' = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
        '20348-Standard' = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'
        '20348-Datacenter' = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33'
        '26100-Standard' = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'
        '26100-Datacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
    }
    if ($Caption -notmatch 'Windows Server .*\b(Standard|Datacenter)\b' -or $Caption -match 'Evaluation') {
        throw "Unsupported Windows activation edition '$Caption'; edition conversion is not automatic."
    }
    $key = $keys["$BuildNumber-$($Matches[1])"]
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Unsupported Windows activation build '$BuildNumber'."
    }
    return $key
}

function Set-ArcBoxWindowsActivation {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    $os = Invoke-Command -VMName $VMName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object BuildNumber, Caption
    }
    $key = Get-ArcBoxWindowsKmsKey -BuildNumber $os.BuildNumber -Caption $os.Caption
    Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $key -ErrorAction Stop -ScriptBlock {
        param([string]$Key)
        $ErrorActionPreference = 'Stop'
        $windowsApplication = '55c92734-d682-4d71-983e-d6ec3f16059f'
        $licensed = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$windowsApplication'" |
            Where-Object { $_.LicenseStatus -eq 1 -and $_.Description -like '*VOLUME_KMSCLIENT*' -and $_.PartialProductKey -eq $Key.Substring($Key.Length - 5) })
        if ($licensed.Count -gt 0) { return }

        foreach ($arguments in @(@('-ipk', $Key), @('-skms', 'kms.core.windows.net'))) {
            & cscript.exe //NoLogo "$env:windir\System32\slmgr.vbs" @arguments | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Windows activation command '$($arguments[0])' failed (exit code $LASTEXITCODE)." }
        }
        $deadline = (Get-Date).AddMinutes(5)
        do {
            & cscript.exe //NoLogo "$env:windir\System32\slmgr.vbs" -ato | Out-Null
            $activationExitCode = $LASTEXITCODE
            $licensed = @(Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$windowsApplication'" |
                Where-Object { $_.LicenseStatus -eq 1 -and $_.Description -like '*VOLUME_KMSCLIENT*' -and $_.PartialProductKey -eq $Key.Substring($Key.Length - 5) })
            if ($licensed.Count -gt 0) { return }
            if ($activationExitCode -ne 0 -and $activationExitCode -ne -1073418124) {
                throw "Windows activation command '-ato' failed (exit code $activationExitCode)."
            }
            Write-Warning "Waiting for Windows KMS activation (last exit code $activationExitCode)."
            Start-Sleep -Seconds 15
        } while ((Get-Date) -lt $deadline)
        throw 'Windows did not report an activated KMS client license within the activation timeout.'
    }
}

function Copy-ArcBoxLinuxGuestFile {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$VMName,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Guest file-copy source does not exist: $SourcePath" }
    foreach ($machine in $VMName) {
        $deadline = (Get-Date).AddMinutes(3)
        while ($true) {
            try {
                Copy-VMFile -Name $machine -SourcePath $SourcePath -DestinationPath $DestinationDirectory -FileSource Host -Force -CreateFullPath -ErrorAction Stop
                break
            } catch {
                if ($_.Exception.Message -notmatch '0x80004005' -or (Get-Date) -ge $deadline) { throw }
                Write-Warning "Guest file copy on '$machine' returned 0x80004005; retrying within the startup deadline."
                Start-Sleep -Seconds 5
            }
        }
    }
}

function Get-ArcBoxServerExtensions {
    param([Parameter(Mandatory)][string]$MachineName)

    $url = "https://management.azure.com/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.HybridCompute/machines/$MachineName/extensions?api-version=2024-07-10"
    return (Invoke-ArcBoxServerAz -Arguments @('rest', '--method', 'get', '--url', $url, '--output', 'json') | ConvertFrom-Json).value
}

function Repair-ArcBoxLinuxChangeTracking {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version
    )

    Invoke-Command -Session $Session -ArgumentList $Version -ErrorAction Stop -ScriptBlock {
        param([string]$Version)
        $path = "/var/lib/waagent/Microsoft.Azure.ChangeTrackingAndInventory.ChangeTracking-Linux-$Version"
        $output = sudo -n timeout --kill-after=30s 300s sh -c 'cd "$1" && ./cta_linux_handler install && ./cta_linux_handler enable && systemctl is-active --quiet cxp && systemctl is-enabled --quiet cxp' sh $path 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Linux Change Tracking service recovery failed (exit code $LASTEXITCODE): $($output -join "`n")"
        }
    }
}

function Install-ArcBoxServerExtension {
    param(
        [Parameter(Mandatory)][string]$MachineName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Publisher,
        [hashtable]$Settings,
        [System.Management.Automation.Runspaces.PSSession]$LinuxGuestSession
    )

    $canRepairLinuxService = $Name -eq 'ChangeTracking-Linux' -and
        $Publisher -eq 'Microsoft.Azure.ChangeTrackingAndInventory' -and $null -ne $LinuxGuestSession
    $missingServicePattern = 'Failed to enable unit: Unit file cxp\.service does not exist\.'
    $serviceRepairAttempted = $false
    $extension = @(Get-ArcBoxServerExtensions -MachineName $MachineName | Where-Object name -eq $Name)
    if ($extension.Count -gt 1) { throw "Multiple extensions named '$Name' on '$MachineName'." }
    if ($extension.Count -eq 1 -and $extension[0].properties.provisioningState -in @('Failed', 'Canceled')) {
        if (-not ($canRepairLinuxService -and $extension[0].properties.provisioningState -eq 'Failed' -and
            $extension[0].properties.publisher -eq $Publisher -and
            $extension[0].properties.instanceView.status.message -match $missingServicePattern)) {
            throw "Existing extension '$Name' on '$MachineName' is failed; repair it before retrying."
        }
    }
    if ($extension.Count -eq 0) {
        $arguments = @('connectedmachine', 'extension', 'create', '--resource-group', $env:resourceGroup,
            '--machine-name', $MachineName, '--name', $Name, '--publisher', $Publisher, '--type', $Name,
            '--location', $env:azureLocation, '--enable-auto-upgrade', 'true', '--no-wait', '--output', 'none')
        $settingsPath = Join-Path $env:ArcBoxDir ("ExtensionSettings-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            if ($null -ne $Settings) {
                $Settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8 -ErrorAction Stop
                $arguments += @('--settings', "@$settingsPath")
            }
            $createOutput = @(& az @arguments --subscription $env:subscriptionId --only-show-errors 2>&1)
            $createExitCode = $LASTEXITCODE
            if ($createExitCode -ne 0) {
                if (($createOutput -join "`n") -notmatch '\bHCRP409\b') {
                    throw "Could not create extension '$Name' on '$MachineName' (Azure CLI exit code $createExitCode): $($createOutput -join "`n")"
                }
                # Policy may have created the same extension after our initial read.
                $concurrent = @(Get-ArcBoxServerExtensions -MachineName $MachineName | Where-Object { $_.name -eq $Name -and $_.properties.publisher -eq $Publisher })
                if ($concurrent.Count -ne 1 -or $concurrent[0].properties.provisioningState -notin @('Creating', 'Updating', 'Succeeded')) {
                    throw "Could not create extension '$Name' on '$MachineName' (Azure CLI exit code $createExitCode): $($createOutput -join "`n")"
                }
                Write-Warning "Extension '$Name' on '$MachineName' was concurrently created; waiting for that deployment."
            }
        } finally {
            if (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction Stop }
        }
    }
    $deadline = (Get-Date).AddMinutes(20)
    do {
        $extension = @(Get-ArcBoxServerExtensions -MachineName $MachineName | Where-Object name -eq $Name)
        $state = if ($extension.Count -eq 1) { $extension[0].properties.provisioningState } else { '' }
        if ($state -eq 'Succeeded') { return }
        if ($state -in @('Failed', 'Canceled')) {
            if ($state -eq 'Failed' -and $canRepairLinuxService -and
                $extension[0].properties.publisher -eq $Publisher -and
                $extension[0].properties.instanceView.status.message -match $missingServicePattern) {
                if (-not $serviceRepairAttempted) {
                    $serviceRepairAttempted = $true
                    Write-Warning "Change Tracking on '$MachineName' did not install cxp.service; retrying the downloaded Microsoft installer once."
                    Repair-ArcBoxLinuxChangeTracking -Session $LinuxGuestSession -Version $extension[0].properties.typeHandlerVersion
                }
            } else {
                throw "Extension '$Name' on '$MachineName' entered '$state': $($extension[0].properties.instanceView.status.message)"
            }
        }
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for extension '$Name' on '$MachineName' (last state '$state')."
}

function Set-ArcBoxServerManagement {
    param(
        [Parameter(Mandatory)][string[]]$WindowsMachines,
        [Parameter(Mandatory)][string[]]$LinuxMachines,
        [hashtable]$LinuxSessions
    )

    $machines = @($WindowsMachines) + @($LinuxMachines)
    if (@($machines | Sort-Object -Unique).Count -ne $machines.Count) { throw 'Arc management requires unique machine names; refusing to skip a guest through duplicate targets.' }
    foreach ($machine in $machines) {
        $os = if ($WindowsMachines -contains $machine) { 'Windows' } else { 'Linux' }
        Install-ArcBoxServerExtension -MachineName $machine -Name "AzureMonitor${os}Agent" -Publisher 'Microsoft.Azure.Monitor'
        $linuxSession = if ($null -ne $LinuxSessions -and $os -eq 'Linux') { $LinuxSessions[$machine] } else { $null }
        Install-ArcBoxServerExtension -MachineName $machine -Name "ChangeTracking-$os" -Publisher 'Microsoft.Azure.ChangeTrackingAndInventory' -LinuxGuestSession $linuxSession
        if ($os -eq 'Windows') {
            Install-ArcBoxServerExtension -MachineName $machine -Name 'WindowsOpenSSH' -Publisher 'Microsoft.Azure.OpenSSH'
        }
        $machineId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.HybridCompute/machines/$machine"
        foreach ($rule in @('OTel', 'Inventory', "Logs-$os")) {
            $ruleId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.Insights/dataCollectionRules/$env:namingPrefix-$rule"
            $null = Invoke-ArcBoxServerAz -Arguments @('monitor', 'data-collection', 'rule', 'association', 'create',
                '--name', "ArcBox-$rule", '--rule-id', $ruleId, '--resource', $machineId, '--output', 'none')
        }
        Set-ArcBoxBaselineAudit -MachineName $machine -OS $os
        $endpointPath = "$machineId/providers/Microsoft.HybridConnectivity/endpoints/default"
        foreach ($request in @(
            @{ Path = "${endpointPath}?api-version=2023-03-15"; Body = '{"properties":{"type":"default"}}' },
            @{ Path = "$endpointPath/serviceconfigurations/SSH?api-version=2023-03-15"; Body = '{"properties":{"serviceName":"SSH","port":22}}' }
        )) {
            $response = Invoke-AzRestMethod -Method PUT -Path $request.Path -Payload $request.Body -ErrorAction Stop
            if ($response.StatusCode -notin @(200, 201, 202)) { throw "Arc SSH configuration failed on '$machine' (HTTP $($response.StatusCode))." }
        }
    }
}

function Set-ArcBoxBaselineAudit {
    param([Parameter(Mandatory)][string]$MachineName, [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$OS)

    $machineId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.HybridCompute/machines/$MachineName"
    $assignmentPath = "$machineId/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments"
    if ($null -ne (Get-ArcBoxBaselineAssignment -MachineName $MachineName -OS $OS)) { return }

    $definitionId = if ($OS -eq 'Windows') { '72650e9f-97bc-4b2a-ab5f-9781a9fcecbc' } else { 'fc9b3da7-8347-4380-8e70-0a0361d8dedd' }
    $definition = Invoke-ArcBoxServerAz -Arguments @('policy', 'definition', 'show', '--name', $definitionId, '--output', 'json') | ConvertFrom-Json
    $metadata = $definition.metadata.guestConfiguration
    if ($metadata.name -ne "Azure${OS}Baseline" -or [string]::IsNullOrWhiteSpace($metadata.version)) { throw "The $OS built-in baseline metadata is invalid." }
    $parameters = @($metadata.configurationParameter.PSObject.Properties | ForEach-Object {
        $parameter = $definition.parameters.($_.Name)
        if ($null -eq $parameter -or $null -eq $parameter.defaultValue) { throw "The built-in baseline parameter '$($_.Name)' has no default." }
        @{ name = $_.Value; value = $parameter.defaultValue }
    })
    $payload = @{
        properties = @{
            context = 'AzurePolicy'
            guestConfiguration = @{
                name = $metadata.name
                version = $metadata.version
                assignmentType = 'Audit'
                configurationParameter = $parameters
            }
        }
    } | ConvertTo-Json -Depth 15
    $response = Invoke-AzRestMethod -Method PUT -Path "$assignmentPath/$($metadata.name)?api-version=2024-04-05" -Payload $payload -ErrorAction Stop
    if ($response.StatusCode -notin @(200, 201, 202)) { throw "Could not create the audit-only baseline assignment on '$MachineName' (HTTP $($response.StatusCode))." }
}

function Get-ArcBoxBaselineAssignment {
    param([Parameter(Mandatory)][string]$MachineName, [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$OS)

    $path = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.HybridCompute/machines/$MachineName/providers/Microsoft.GuestConfiguration/guestConfigurationAssignments/Azure${OS}Baseline?api-version=2024-04-05"
    try {
        $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
    } catch {
        $httpResponse = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $httpResponse -and $null -ne $httpResponse.Value -and $httpResponse.Value.StatusCode -eq 404) {
            Write-Host "No $OS audit baseline assignment exists yet on $MachineName."
            return $null
        }
        throw
    }
    if ($response.StatusCode -eq 404) {
        Write-Host "No $OS audit baseline assignment exists yet on $MachineName."
        return $null
    }
    if ($response.StatusCode -ne 200) { throw "Could not read baseline assignment on '$MachineName' (HTTP $($response.StatusCode))." }
    return $response.Content | ConvertFrom-Json
}

function Wait-ArcBoxBaselineReport {
    param([Parameter(Mandatory)][string]$MachineName, [Parameter(Mandatory)][ValidateSet('Windows', 'Linux')][string]$OS)

    $deadline = (Get-Date).AddMinutes(30)
    do {
        $baseline = Get-ArcBoxBaselineAssignment -MachineName $MachineName -OS $OS
        if ($baseline.properties.complianceStatus -in @('Compliant', 'NonCompliant')) { return $baseline.properties.complianceStatus }
        Write-Host "Waiting for an evaluated $OS baseline report on $MachineName."
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    throw "No evaluated $OS baseline report was returned for $MachineName."
}

function Invoke-ArcBoxLogQuery {
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$Query)

    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
    if ($null -ne $result.Error) { throw "Log Analytics query failed: $($result.Error.Message)" }
    return @($result.Results)
}

function Get-ArcBoxOtelMetrics {
    param([Parameter(Mandatory)][string]$Query)

    $accountId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.Monitor/accounts/$env:namingPrefix-monitor"
    $account = Invoke-ArcBoxServerAz -Arguments @('rest', '--method', 'get', '--url', "https://management.azure.com${accountId}?api-version=2023-04-03", '--output', 'json') | ConvertFrom-Json
    $endpoint = $account.properties.metrics.prometheusQueryEndpoint
    if ([string]::IsNullOrWhiteSpace($endpoint)) { throw 'Azure Monitor workspace has no Prometheus query endpoint.' }
    $token = (Get-AzAccessToken -ResourceUrl 'https://prometheus.monitor.azure.com' -AsSecureString -ErrorAction Stop).Token
    $response = Invoke-RestMethod -Uri "$($endpoint.TrimEnd('/'))/api/v1/query?query=$([uri]::EscapeDataString($Query))" -Authentication Bearer -Token $token -ErrorAction Stop
    if ($response.status -ne 'success') { throw "OTel query failed with status '$($response.status)'." }
    return @($response.data.result)
}

function Wait-ArcBoxServerTelemetry {
    param([Parameter(Mandatory)][string[]]$MachineNames, [switch]$InventoryOnly, [string]$ProbeName)

    if (-not $InventoryOnly -and $ProbeName -notmatch '^ArcBoxInventoryProbe[a-f0-9]{8}$') {
        throw 'A unique ArcBoxInventoryProbe name is required to verify new change records.'
    }
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $env:resourceGroup -Name $env:workspaceName -ErrorAction Stop
    $deadline = (Get-Date).AddMinutes(60)
    do {
        $missing = [System.Collections.Generic.List[string]]::new()
        $metricNames = @('system.cpu.time', 'system.memory.usage', 'system.disk.io', 'system.network.io')
        $metrics = @()
        if (-not $InventoryOnly) {
            foreach ($metricName in $metricNames) {
                $metrics += @(Get-ArcBoxOtelMetrics -Query "{`"$metricName`"}")
            }
        }
        foreach ($machine in $MachineNames) {
            $id = "/subscriptions/$env:subscriptionId/resourcegroups/$env:resourceGroup/providers/microsoft.hybridcompute/machines/$machine".ToLowerInvariant()
            $tables = if ($InventoryOnly) { @('Heartbeat', 'ConfigurationData') } else { @('Heartbeat', 'ConfigurationData', 'ConfigurationChange') }
            foreach ($table in $tables) {
                $filter = if ($table -eq 'ConfigurationChange') { "| where tostring(pack_all()) contains '$ProbeName'" } else { '' }
                $rows = @(Invoke-ArcBoxLogQuery -WorkspaceId $workspace.CustomerId -Query "union isfuzzy=true $table, (datatable(TimeGenerated:datetime, _ResourceId:string)[]) | where TimeGenerated > ago(2h) | where tolower(_ResourceId) == '$id' $filter | take 1")
                if ($rows.Count -eq 0) { $missing.Add("$machine/$table") }
            }
            if ($InventoryOnly) { continue }
            $osLog = if ($machine -in @('ubu24sql25', 'ubu24')) { 'Syslog' } else { 'Event' }
            $rows = @(Invoke-ArcBoxLogQuery -WorkspaceId $workspace.CustomerId -Query "union isfuzzy=true $osLog, (datatable(TimeGenerated:datetime, _ResourceId:string)[]) | where TimeGenerated > ago(2h) | where tolower(_ResourceId) == '$id' | take 1")
            if ($rows.Count -eq 0) { $missing.Add("$machine/$osLog") }
            foreach ($metric in $metricNames) {
                $samples = @($metrics | Where-Object {
                    $_.metric.__name__ -eq $metric -and
                    @($_.metric.PSObject.Properties | Where-Object Value -IEQ $id).Count -gt 0 -and
                    [double]$_.value[0] -gt [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds()
                })
                if ($samples.Count -eq 0) { $missing.Add("$machine/$metric") }
            }
        }
        if ($missing.Count -eq 0) { return }
        Write-Host "Waiting for actual server telemetry: $($missing -join ', ')"
        Start-Sleep -Seconds 60
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for server telemetry: $($missing -join ', ')"
}

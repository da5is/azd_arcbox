BeforeDiscovery {
    $VMs = @('win22sql22', 'ubu24sql25', 'ubu24', 'win19sql16', 'win22sql19', 'win25sql25')
    $SqlVMs = @(
        @{ Name = 'win19sql16'; MajorVersion = 13; DatabaseName = 'AdventureWorksLT2016' }
        @{ Name = 'win22sql19'; MajorVersion = 15; DatabaseName = 'AdventureWorksLT2019' }
        @{ Name = 'win25sql25'; MajorVersion = 17; DatabaseName = 'AdventureWorksLT2025' }
    )
}

BeforeAll {
    . "$env:ArcBoxDir\ArcBoxServerManagement.ps1"
    $null = Connect-AzAccount -Identity -Tenant $env:tenantId -Subscription $env:subscriptionId
    $keyVault = Get-AzKeyVault -ResourceGroupName $env:resourceGroup -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $keyVault) { throw 'ArcBox Key Vault was not found.' }
    $sharedPassword = Get-AzKeyVaultSecret -VaultName $keyVault.VaultName -Name windowsAdminPassword -AsPlainText -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($sharedPassword)) { throw 'ArcBox shared password is empty.' }
    $managementCredentials = [pscredential]::new('Administrator', (ConvertTo-SecureString $sharedPassword -AsPlainText -Force))
}

Describe "<vm>" -ForEach $VMs {
    BeforeAll { $vm = $_ }
    It 'VM exists' {
        Get-VM -Name $vm | Should -Not -BeNullOrEmpty
    }
    It 'VM is running' {
        (Get-VM -Name $vm).State | Should -Be 'Running'
    }
    It 'Azure Arc Connected Machine exists' {
        Get-AzConnectedMachine -Name $vm -ResourceGroupName $env:resourceGroup -SubscriptionId $env:subscriptionId | Should -Not -BeNullOrEmpty
    }
    It 'Azure Arc Connected Machine is connected' {
        (Get-AzConnectedMachine -Name $vm -ResourceGroupName $env:resourceGroup -SubscriptionId $env:subscriptionId).Status | Should -Be 'Connected'
    }
}

Describe 'Nested SQL Server on <Name>' -ForEach $SqlVMs {
    BeforeAll { $sqlVM = $_ }
    It 'has SQL Server major version <MajorVersion> and both sample databases' {
        $result = Invoke-Command -VMName $sqlVM.Name -Credential $managementCredentials -ErrorAction Stop -ScriptBlock {
            param($databaseName)
            Import-Module SqlServer -ErrorAction Stop
            Invoke-Sqlcmd -ServerInstance '.' -Query @"
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    ISNULL(DB_ID(N'$databaseName'), 0) AS SampleDatabaseId,
    ISNULL(DB_ID(N'ArchiveDB'), 0) AS ArchiveDatabaseId;
"@ -TrustServerCertificate -ErrorAction Stop
        } -ArgumentList $sqlVM.DatabaseName
        $result.MajorVersion | Should -Be $sqlVM.MajorVersion
        $result.SampleDatabaseId | Should -BeGreaterThan 0
        $result.ArchiveDatabaseId | Should -BeGreaterThan 0
        $mode = if ([string]::IsNullOrWhiteSpace($env:nestedSqlMode)) { 'Developer' } else { $env:nestedSqlMode }
        if ($mode -eq 'Evaluation') {
            $result.Edition | Should -Match 'Evaluation|^(Standard|Enterprise) Edition\b'
            $result.Edition | Should -Not -Match 'Developer'
        } else {
            $result.Edition | Should -BeLike "*$mode*"
        }
    }
}

Describe 'Arc management on <_>' -ForEach $VMs {
    BeforeAll {
        $machine = $_
        $os = if ($machine -in @('ubu24sql25', 'ubu24')) { 'Linux' } else { 'Windows' }
        $machineId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup/providers/Microsoft.HybridCompute/machines/$machine"
    }
    It 'has successful AMA, Change Tracking and platform SSH configuration' {
        $extensions = @(Get-ArcBoxServerExtensions -MachineName $machine)
        $names = @("AzureMonitor${os}Agent", "ChangeTracking-$os")
        if ($os -eq 'Windows') { $names += 'WindowsOpenSSH' }
        foreach ($name in $names) {
            $extension = @($extensions | Where-Object name -eq $name)
            $extension.Count | Should -Be 1
            $extension[0].properties.provisioningState | Should -Be 'Succeeded'
        }
        $serviceUrl = "https://management.azure.com$machineId/providers/Microsoft.HybridConnectivity/endpoints/default/serviceconfigurations/SSH?api-version=2023-03-15"
        $service = Invoke-ArcBoxServerAz -Arguments @('rest', '--method', 'get', '--url', $serviceUrl, '--output', 'json') | ConvertFrom-Json
        $service.properties.serviceName | Should -Be 'SSH'
        $service.properties.port | Should -Be 22
    }
    It 'has every expected DCR association' {
        $url = "https://management.azure.com$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11"
        $associations = (Invoke-ArcBoxServerAz -Arguments @('rest', '--method', 'get', '--url', $url, '--output', 'json') | ConvertFrom-Json).value
        foreach ($rule in @('OTel', 'Inventory', "Logs-$os")) {
            @($associations | Where-Object { $_.properties.dataCollectionRuleId -like "*/$env:namingPrefix-$rule" }).Count | Should -Be 1
        }
    }
    It 'has an evaluated audit baseline report' {
        Wait-ArcBoxBaselineReport -MachineName $machine -OS $os | Should -BeIn @('Compliant', 'NonCompliant')
    }
    It 'has the expected hostname and a running SSH server over actual SSH' {
        $ip = Get-VM -Name $machine | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses |
            Where-Object { $_ -match '^10\.10\.1\.' } | Select-Object -First 1
        $ip | Should -Not -BeNullOrEmpty
        $user = if ($os -eq 'Windows') { 'Administrator' } else { 'jumpstart' }
        $result = & ssh -i "$env:USERPROFILE\.ssh\id_rsa" -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "$user@$ip" hostname
        $LASTEXITCODE | Should -Be 0
        ($result -join '').Trim() | Should -Be $machine
        if ($os -eq 'Windows') {
            $license = Invoke-Command -VMName $machine -Credential $managementCredentials -ErrorAction Stop -ScriptBlock {
                Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
                    Where-Object { $_.PartialProductKey -and $_.LicenseStatus -eq 1 -and $_.Description -like '*VOLUME_KMSCLIENT*' }
            }
            @($license).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Ubuntu SQL and non-SQL separation' {
    BeforeAll {
        $linuxSessions = foreach ($name in @('ubu24sql25', 'ubu24')) {
            $ip = Get-VM -Name $name | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses |
                Where-Object { $_ -match '^10\.10\.1\.' } | Select-Object -First 1
            New-PSSession -HostName $ip -UserName jumpstart -KeyFilePath "$env:USERPROFILE\.ssh\id_rsa" -ErrorAction Stop
        }
    }
    AfterAll { if ($linuxSessions) { Remove-PSSession -Session $linuxSessions } }
    It 'serves SQL 2025 in the selected edition with both sample databases and a bounded memory footprint' {
        $edition = Invoke-Command -Session $linuxSessions[0] -ArgumentList $sharedPassword -ErrorAction Stop -ScriptBlock {
            param([string]$Password)
            $env:SQLCMDPASSWORD = $Password
            try {
                $query = @'
SET NOCOUNT ON;
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) <> 17 THROW 51000, 'Incorrect SQL major version', 1;
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name=N'AdventureWorksLT2025' AND state=0) THROW 51000, 'Missing AdventureWorks', 1;
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name=N'ArchiveDB' AND state=0 AND recovery_model_desc=N'FULL') THROW 51000, 'Missing ArchiveDB', 1;
IF NOT EXISTS (SELECT 1 FROM ArchiveDB.sys.columns WHERE object_id=OBJECT_ID(N'ArchiveDB.dbo.Records') AND name=N'Chart' AND system_type_id=165 AND max_length=-1 AND is_filestream=0) THROW 51000, 'Incorrect Linux ArchiveDB storage', 1;
BEGIN TRANSACTION;
DECLARE @id uniqueidentifier=NEWID();
INSERT ArchiveDB.dbo.Records (Id, SerialNumber, Chart) VALUES (@id, -2147483648, 0x417263426F78);
IF NOT EXISTS (SELECT 1 FROM ArchiveDB.dbo.Records WHERE Id=@id AND Chart=0x417263426F78) THROW 51000, 'Binary read failed', 1;
ROLLBACK;
IF NOT EXISTS (SELECT 1 FROM AdventureWorksLT2025.SalesLT.Customer) THROW 51000, 'Sample data is empty', 1;
SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128));
'@
                $result = & /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W -Q $query
                if ($LASTEXITCODE -ne 0) { throw 'Linux SQL database acceptance query failed.' }
                $memory = sudo -n python3 -c 'import configparser; c=configparser.ConfigParser(); c.read("/var/opt/mssql/mssql.conf"); print(c.get("memory","memorylimitmb"))' 2>&1
                if ($LASTEXITCODE -ne 0 -or ($memory -join '').Trim() -ne '2048') { throw 'Linux SQL memory limit is not 2048 MB.' }
                $result
            } finally { Remove-Item Env:SQLCMDPASSWORD }
        }
        if ($env:nestedSqlMode -eq 'Evaluation') {
            ($edition -join '') | Should -Match 'Evaluation|^(Standard|Enterprise) Edition\b'
        } else {
            ($edition -join '') | Should -Match 'Developer'
        }
        @(Get-ArcBoxServerExtensions -MachineName ubu24sql25 | Where-Object name -eq 'LinuxAgent.SqlServer')[0].properties.provisioningState | Should -Be 'Succeeded'
    }
    It 'keeps ubu24 free of SQL Server and SQL-specific extensions' {
        Invoke-Command -Session $linuxSessions[1] -ErrorAction Stop -ScriptBlock {
            $null = dpkg-query -W mssql-server 2>$null
            if ($LASTEXITCODE -eq 0) { throw 'SQL Server was unexpectedly installed on ubu24.' }
            $null = systemctl cat mssql-server 2>$null
            if ($LASTEXITCODE -eq 0) { throw 'A SQL Server service exists on ubu24.' }
        } | Should -BeNullOrEmpty
        @(Get-ArcBoxServerExtensions -MachineName ubu24 | Where-Object name -eq 'LinuxAgent.SqlServer').Count | Should -Be 0
    }
}

Describe 'Six-guest monitoring data and memory headroom' {
    It 'receives real inventory, test changes, OS logs and fresh OTel metrics from every guest' {
        $windows = @('win22sql22', 'win19sql16', 'win22sql19', 'win25sql25')
        $allMachines = $windows + @('ubu24sql25', 'ubu24')
        Wait-ArcBoxServerTelemetry -MachineNames $allMachines -InventoryOnly
        $probe = 'ArcBoxInventoryProbe' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sessions = @()
        try {
            Invoke-Command -VMName $windows -Credential $managementCredentials -ArgumentList $probe -ErrorAction Stop -ScriptBlock {
                param([string]$Probe)
                New-Service -Name $Probe -BinaryPathName "$env:windir\System32\cmd.exe /c exit 0" -StartupType Manual -ErrorAction Stop | Out-Null
                eventcreate.exe /T WARNING /ID 100 /L APPLICATION /SO ArcBoxInventoryProbe /D 'ArcBox monitoring acceptance probe' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not emit the monitoring probe event.' }
            }
            foreach ($name in @('ubu24sql25', 'ubu24')) {
                $ip = Get-VM -Name $name | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses |
                    Where-Object { $_ -match '^10\.10\.1\.' } | Select-Object -First 1
                $sessions += New-PSSession -HostName $ip -UserName jumpstart -KeyFilePath "$env:USERPROFILE\.ssh\id_rsa" -ErrorAction Stop
            }
            Invoke-Command -Session $sessions -ArgumentList $probe -ErrorAction Stop -ScriptBlock {
                param([string]$Probe)
                "[Unit]`nDescription=$Probe`n[Service]`nType=oneshot`nRemainAfterExit=yes`nExecStart=/usr/bin/true`n" | sudo -n tee "/etc/systemd/system/$Probe.service" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not create the service inventory probe.' }
                sudo -n systemctl daemon-reload
                if ($LASTEXITCODE -ne 0) { throw 'Could not reload the service inventory probe.' }
                sudo -n systemctl start "$Probe.service"
                if ($LASTEXITCODE -ne 0) { throw 'Could not start the service inventory probe.' }
                logger -p user.warning -t ArcBoxInventoryProbe 'ArcBox monitoring acceptance probe'
                if ($LASTEXITCODE -ne 0) { throw 'Could not emit the monitoring probe log.' }
            }
            Wait-ArcBoxServerTelemetry -MachineNames $allMachines -ProbeName $probe
        } finally {
            Invoke-Command -VMName $windows -Credential $managementCredentials -ArgumentList $probe -ErrorAction Stop -ScriptBlock {
                param([string]$Probe)
                if (Get-Service -Name $Probe -ErrorAction SilentlyContinue) {
                    sc.exe delete $Probe | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the service inventory probe.' }
                }
            }
            if ($sessions.Count -gt 0) {
                try {
                    Invoke-Command -Session $sessions -ArgumentList $probe -ErrorAction Stop -ScriptBlock {
                        param([string]$Probe)
                        sudo -n systemctl stop "$Probe.service"
                        if ($LASTEXITCODE -ne 0) { throw 'Could not stop the service inventory probe.' }
                        sudo -n rm -f "/etc/systemd/system/$Probe.service"
                        if ($LASTEXITCODE -ne 0) { throw 'Could not remove the service inventory probe.' }
                        sudo -n systemctl daemon-reload
                        if ($LASTEXITCODE -ne 0) { throw 'Could not reload services after removing the inventory probe.' }
                    }
                } finally { Remove-PSSession -Session $sessions }
            }
        }
        (Get-VM -Name $allMachines | Measure-Object MemoryStartup -Sum).Sum | Should -Be (24GB)
    }

    It 'retains more than 2 GB of host headroom during concurrent SQL queries on all five SQL guests' {
        $query = @'
DECLARE @until datetime2=DATEADD(second,30,SYSDATETIME()), @n bigint;
WHILE SYSDATETIME()<@until
    SELECT @n=COUNT_BIG(*) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
'@
        $jobs = @()
        $session = $null
        try {
            $jobs += Invoke-Command -VMName @('win22sql22', 'win19sql16', 'win22sql19', 'win25sql25') -Credential $managementCredentials -AsJob -ArgumentList $query -ErrorAction Stop -ScriptBlock {
                param([string]$Query)
                Import-Module SqlServer -ErrorAction Stop
                Invoke-Sqlcmd -ServerInstance '.' -Query $Query -TrustServerCertificate -QueryTimeout 120 -ErrorAction Stop
            }
            $ip = Get-VM -Name ubu24sql25 | Select-Object -ExpandProperty NetworkAdapters | Select-Object -ExpandProperty IPAddresses |
                Where-Object { $_ -match '^10\.10\.1\.' } | Select-Object -First 1
            $session = New-PSSession -HostName $ip -UserName jumpstart -KeyFilePath "$env:USERPROFILE\.ssh\id_rsa" -ErrorAction Stop
            $jobs += Invoke-Command -Session $session -AsJob -ArgumentList $sharedPassword, $query -ErrorAction Stop -ScriptBlock {
                param([string]$Password, [string]$Query)
                $env:SQLCMDPASSWORD = $Password
                try {
                    & /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -t 120 -Q $Query
                    if ($LASTEXITCODE -ne 0) { throw 'Concurrent Linux SQL query failed.' }
                } finally { Remove-Item Env:SQLCMDPASSWORD }
            }
            $deadline = (Get-Date).AddMinutes(3)
            do {
                (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory | Should -BeGreaterThan 2097152
                Start-Sleep -Seconds 2
                $running = @($jobs | Where-Object State -in @('Running', 'NotStarted'))
            } while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)
            $running.Count | Should -Be 0
            foreach ($job in $jobs) {
                Receive-Job -Job $job -ErrorAction Stop | Out-Null
                $job.State | Should -Be 'Completed'
            }
            @(Get-VM -Name @('win22sql22', 'win19sql16', 'win22sql19', 'win25sql25', 'ubu24sql25', 'ubu24') | Where-Object State -ne Running).Count | Should -Be 0
        } finally {
            foreach ($job in $jobs) {
                if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction Stop }
                Remove-Job -Job $job -Force -ErrorAction Stop
            }
            if ($null -ne $session) { Remove-PSSession -Session $session }
        }
    }
}

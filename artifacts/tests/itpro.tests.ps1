
BeforeDiscovery {
    $namingPrefix = $env:namingPrefix
    $VMs = @('win22sql22', "$namingPrefix-Ubuntu-01", "$namingPrefix-Ubuntu-02", 'win19sql16', 'win22sql19', 'win25sql25')
    $SqlVMs = @(
        @{ Name = 'win19sql16'; MajorVersion = 13; DatabaseName = 'AdventureWorksLT2016' }
        @{ Name = 'win22sql19'; MajorVersion = 15; DatabaseName = 'AdventureWorksLT2019' }
        @{ Name = 'win25sql25'; MajorVersion = 17; DatabaseName = 'AdventureWorksLT2025' }
    )
}

# Assert that the Hyper-V virtual machines in $VMs exists, are running and connected as Azure Arc-enabled servers

Describe "<vm>" -ForEach $VMs {
    BeforeAll {
        $vm = $_
    }
    It "VM exists" {
        $vmobject = Get-VM -Name $vm
        $vmobject | Should -Not -BeNullOrEmpty
    }
    It "VM is running" {
        $vmobject = Get-VM -Name $vm
        $vmobject.State | Should -Be "Running"
    }
    It "Azure Arc Connected Machine exists" {
        $connectedMachine = Get-AzConnectedMachine -Name $vm -ResourceGroupName $env:resourceGroup -SubscriptionId $env:subscriptionId
        $connectedMachine | Should -Not -BeNullOrEmpty
    }
    It "Azure Arc Connected Machine is connected" {
        $connectedMachine = Get-AzConnectedMachine -Name $vm -ResourceGroupName $env:resourceGroup -SubscriptionId $env:subscriptionId
        $connectedMachine.Status | Should -Be "Connected"
    }
}

Describe "Nested SQL Server on <Name>" -ForEach $SqlVMs {
    BeforeAll {
        $sqlVM = $_
        $null = Connect-AzAccount -Identity -Tenant $env:tenantId -Subscription $env:subscriptionId
        $keyVault = Get-AzKeyVault -ResourceGroupName $env:resourceGroup -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $keyVault) {
            throw "Could not find the ArcBox Key Vault in resource group '$env:resourceGroup'."
        }
        $nestedGuestPassword = Get-AzKeyVaultSecret -VaultName $keyVault.VaultName -Name 'windowsAdminPassword' -AsPlainText -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($nestedGuestPassword)) {
            throw "Key Vault '$($keyVault.VaultName)' returned an empty windowsAdminPassword; nested guest checks cannot continue."
        }
        $password = ConvertTo-SecureString $nestedGuestPassword -AsPlainText -Force
        $credentials = [System.Management.Automation.PSCredential]::new('Administrator', $password)
    }

    It "has SQL Server major version <MajorVersion> and both sample databases" {
        $result = Invoke-Command -VMName $sqlVM.Name -Credential $credentials -ScriptBlock {
            param($databaseName)
            Import-Module SqlServer -Force
            Invoke-Sqlcmd -ServerInstance '.' -Query @"
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    ISNULL(DB_ID(N'$databaseName'), 0) AS SampleDatabaseId,
    ISNULL(DB_ID(N'ArchiveDB'), 0) AS ArchiveDatabaseId;
"@ -TrustServerCertificate
        } -ArgumentList $sqlVM.DatabaseName

        $result.MajorVersion | Should -Be $sqlVM.MajorVersion
        $result.SampleDatabaseId | Should -BeGreaterThan 0
        $result.ArchiveDatabaseId | Should -BeGreaterThan 0
    }
}

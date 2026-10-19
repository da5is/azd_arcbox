#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.6.0' }

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $root 'artifacts\ArcBoxServerManagement.ps1')
    function az { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) throw 'Unexpected Azure CLI call.' }
    function Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'Unexpected Azure REST call.' }
    function cscript.exe { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) throw 'Unexpected activation call.' }
    function Copy-VMFile { param($Name, $SourcePath, $DestinationPath, $FileSource, [switch]$Force, [switch]$CreateFullPath) throw 'Unexpected Hyper-V file copy.' }
    function Install-ArcBoxSqlExtension { param($MachineName, $LicenseType) throw 'Unexpected SQL extension call.' }
}

Describe 'Windows KMS version and edition selection' {
    It 'selects the published KMS key for build <Build> and edition <Edition>' -ForEach @(
        @{ Build = '17763'; Edition = 'Standard'; Key = 'N69G4-B89J2-4G8F4-WWYCC-J464C' },
        @{ Build = '17763'; Edition = 'Datacenter'; Key = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG' },
        @{ Build = '20348'; Edition = 'Standard'; Key = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H' },
        @{ Build = '20348'; Edition = 'Datacenter'; Key = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33' },
        @{ Build = '26100'; Edition = 'Standard'; Key = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832' },
        @{ Build = '26100'; Edition = 'Datacenter'; Key = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' }
    ) {
        Get-ArcBoxWindowsKmsKey -BuildNumber $Build -Caption "Microsoft Windows Server 2022 $Edition" | Should -Be $Key
    }
    It 'rejects unrecognized or Evaluation editions without conversion' {
        { Get-ArcBoxWindowsKmsKey -BuildNumber 20348 -Caption 'Windows Server 2022 Standard Evaluation' } | Should -Throw '*edition conversion is not automatic*'
        { Get-ArcBoxWindowsKmsKey -BuildNumber 20348 -Caption 'Windows 11 Pro' } | Should -Throw '*Unsupported*'
        { Get-ArcBoxWindowsKmsKey -BuildNumber 99999 -Caption 'Windows Server Standard' } | Should -Throw '*Unsupported*'
    }
    It 'includes the prebuilt SQL guest and verifies actual Windows licensing state' {
        $source = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $source | Should -Match 'Set-ArcBoxWindowsActivation -VMName \$SQLvmName'
        $source.IndexOf('Set-ArcBoxWindowsActivation -VMName $SQLvmName') | Should -BeGreaterThan $source.IndexOf("Write-Host 'VM has rebooted successfully!'")
        (Get-Content (Join-Path $root 'artifacts\ArcBoxServerManagement.ps1') -Raw) | Should -Match 'LicenseStatus -eq 1'
    }
    It 'does not accept cscript success without an activated Windows license' {
        $script:activationClock = 0
        Mock Get-Date {
            $script:activationClock++
            [datetime]'2026-01-01' + [timespan]::FromMinutes(10 * ($script:activationClock - 1))
        }
        Mock Start-Sleep {}
        Mock Invoke-Command {
            if ($ScriptBlock.ToString() -match 'Win32_OperatingSystem') { return @{ BuildNumber = '20348'; Caption = 'Windows Server 2022 Standard' } }
            & $ScriptBlock @ArgumentList
        }
        Mock Get-CimInstance { }
        Mock cscript.exe { $global:LASTEXITCODE = 0 }
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'UnitTestPassword1!' -AsPlainText -Force))
        { Set-ArcBoxWindowsActivation -VMName win22sql22 -Credential $credential } | Should -Throw '*did not report an activated*'
        Should -Invoke cscript.exe -Exactly -Times 3
    }
    It 'retries only transient KMS contact failure and requires the resulting activated license' {
        $script:licenseReads = 0
        $script:activationAttempts = 0
        Mock Invoke-Command {
            if ($ScriptBlock.ToString() -match 'Win32_OperatingSystem') { return @{ BuildNumber = '20348'; Caption = 'Windows Server 2022 Standard' } }
            & $ScriptBlock @ArgumentList
        }
        Mock Get-CimInstance {
            $script:licenseReads++
            if ($script:licenseReads -ge 3) { @{ LicenseStatus = 1; Description = 'VOLUME_KMSCLIENT'; PartialProductKey = 'VMK7H' } }
        }
        Mock cscript.exe {
            $global:LASTEXITCODE = 0
            if ($Arguments -contains '-ato') {
                $script:activationAttempts++
                if ($script:activationAttempts -eq 1) { $global:LASTEXITCODE = -1073418124 }
            }
        }
        Mock Start-Sleep {}
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'UnitTestPassword1!' -AsPlainText -Force))
        { Set-ArcBoxWindowsActivation -VMName win22sql22 -Credential $credential } | Should -Not -Throw
        $script:activationAttempts | Should -Be 2
        Should -Invoke Start-Sleep -Exactly -Times 1
    }
}

Describe 'Arc extension provisioning safeguards' {
    BeforeEach {
        $script:savedArcBoxDir = $env:ArcBoxDir
        $env:ArcBoxDir = $TestDrive
        Mock Start-Sleep {}
    }
    AfterEach { $env:ArcBoxDir = $script:savedArcBoxDir }
    It 'reuses successful extensions without modifying licenses or settings' {
        Mock Get-ArcBoxServerExtensions { [pscustomobject]@{ name = 'LinuxAgent.SqlServer'; properties = @{ provisioningState = 'Succeeded' } } }
        Mock Invoke-ArcBoxServerAz { throw 'Must not create or update.' }
        Install-ArcBoxServerExtension -MachineName ubu24sql25 -Name LinuxAgent.SqlServer -Publisher Microsoft.AzureData -Settings @{ LicenseType = 'LicenseOnly' }
        Should -Invoke Invoke-ArcBoxServerAz -Times 0
    }
    It 'surfaces terminal extension failure instead of reporting readiness' {
        Mock Get-ArcBoxServerExtensions { [pscustomobject]@{ name = 'AzureMonitorLinuxAgent'; properties = @{ provisioningState = 'Failed' } } }
        { Install-ArcBoxServerExtension -MachineName ubu24 -Name AzureMonitorLinuxAgent -Publisher Microsoft.Azure.Monitor } | Should -Throw '*repair it before retrying*'
    }
    It 'polls an initially invisible extension and uses a settings file' {
        $script:reads = 0
        Mock Get-ArcBoxServerExtensions {
            $script:reads++
            if ($script:reads -gt 2) { [pscustomobject]@{ name = 'LinuxAgent.SqlServer'; properties = @{ provisioningState = 'Succeeded' } } }
        }
        Mock az {
            $settingsIndex = [array]::IndexOf($Arguments, '--settings')
            $settingsIndex | Should -BeGreaterThan 0
            $path = $Arguments[$settingsIndex + 1].TrimStart('@')
            (Get-Content $path -Raw | ConvertFrom-Json).LicenseType | Should -Be 'LicenseOnly'
            $global:LASTEXITCODE = 0
        }
        Install-ArcBoxServerExtension -MachineName ubu24sql25 -Name LinuxAgent.SqlServer -Publisher Microsoft.AzureData -Settings @{ LicenseType = 'LicenseOnly' }
        $script:reads | Should -Be 3
        @(Get-ChildItem $TestDrive -Filter 'ExtensionSettings-*.json').Count | Should -Be 0
    }
    It 'does not swallow native extension creation failures' {
        Mock Get-ArcBoxServerExtensions { }
        Mock az { $global:LASTEXITCODE = 1 }
        { Install-ArcBoxServerExtension -MachineName ubu24 -Name AzureMonitorLinuxAgent -Publisher Microsoft.Azure.Monitor } | Should -Throw '*Could not create extension*'
    }
    It 'reuses an extension concurrently created by policy after a create conflict' {
        $script:reads = 0
        Mock Get-ArcBoxServerExtensions {
            $script:reads++
            if ($script:reads -gt 1) { [pscustomobject]@{ name = 'AzureMonitorLinuxAgent'; properties = @{ publisher = 'Microsoft.Azure.Monitor'; provisioningState = 'Succeeded' } } }
        }
        Mock az { $global:LASTEXITCODE = 1 }
        { Install-ArcBoxServerExtension -MachineName ubu24 -Name AzureMonitorLinuxAgent -Publisher Microsoft.Azure.Monitor } | Should -Not -Throw
    }
    It 'bounds pending extension polling' {
        $script:clockReads = 0
        $script:extensionReads = 0
        Mock Get-Date {
            $script:clockReads++
            [datetime]'2026-01-01' + [timespan]::FromMinutes(30 * ($script:clockReads - 1))
        }
        Mock Get-ArcBoxServerExtensions {
            $script:extensionReads++
            if ($script:extensionReads -gt 1) { [pscustomobject]@{ name = 'AzureMonitorLinuxAgent'; properties = @{ provisioningState = 'Creating' } } }
        }
        Mock az { $global:LASTEXITCODE = 0 }
        { Install-ArcBoxServerExtension -MachineName ubu24 -Name AzureMonitorLinuxAgent -Publisher Microsoft.Azure.Monitor } | Should -Throw '*Timed out*'
    }
    It 'rejects telemetry checks without a unique current-run change probe' {
        { Wait-ArcBoxServerTelemetry -MachineNames ubu24 } | Should -Throw '*unique ArcBoxInventoryProbe*'
    }
    It 'queries native OTel metric names explicitly rather than an unsupported wildcard selector' {
        $source = Get-Content (Join-Path $root 'artifacts\ArcBoxServerManagement.ps1') -Raw
        $source | Should -Not -Match '__name__=~'
        $source | Should -Match "system.cpu.time', 'system.memory.usage', 'system.disk.io', 'system.network.io"
        $source | Should -Match 'Get-ArcBoxOtelMetrics -Query "\{`"\$metricName`"\}"'
    }
}

Describe 'Six-machine management orchestration' {
    It 'installs the correct per-OS extensions and associates all rules without a Linux WindowsOpenSSH extension' {
        Mock Install-ArcBoxServerExtension {}
        Mock Set-ArcBoxBaselineAudit {}
        Mock Invoke-ArcBoxServerAz {}
        Mock Invoke-AzRestMethod { @{ StatusCode = 200 } }
        Set-ArcBoxServerManagement -WindowsMachines @('win22sql22', 'win19sql16', 'win22sql19', 'win25sql25') -LinuxMachines @('ubu24sql25', 'ubu24')
        Should -Invoke Install-ArcBoxServerExtension -Times 4 -Exactly -ParameterFilter { $Name -eq 'WindowsOpenSSH' -and $MachineName -like 'win*' }
        Should -Invoke Install-ArcBoxServerExtension -Times 0 -Exactly -ParameterFilter { $Name -eq 'WindowsOpenSSH' -and $MachineName -like 'ubu*' }
        Should -Invoke Install-ArcBoxServerExtension -Times 6 -Exactly -ParameterFilter { $Name -like 'AzureMonitor*Agent' }
        Should -Invoke Install-ArcBoxServerExtension -Times 6 -Exactly -ParameterFilter { $Name -like 'ChangeTracking-*' }
        Should -Invoke Invoke-ArcBoxServerAz -Times 18 -Exactly
        Should -Invoke Invoke-AzRestMethod -Times 12 -Exactly
        Should -Invoke Set-ArcBoxBaselineAudit -Times 6 -Exactly
    }
    It 'rejects duplicate targets before making any cloud changes' {
        Mock Install-ArcBoxServerExtension {}
        { Set-ArcBoxServerManagement -WindowsMachines @('win25sql25', 'win19sql16', 'win22sql19', 'win25sql25') -LinuxMachines @('ubu24sql25', 'ubu24') } | Should -Throw '*unique machine names*'
        Should -Invoke Install-ArcBoxServerExtension -Times 0
    }
    It 'preserves the prebuilt SQL target through the actual caller loop and management invocation' {
        $source = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $loop = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Body.Extent.Text -match 'Install-ArcBoxSqlExtension'
        }, $true)
        $management = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-ArcBoxServerManagement'
        }, $true)
        $SQLvmName = 'win22sql22'
        $Win19Sql16vmName = 'win19sql16'
        $Win22Sql19vmName = 'win22sql19'
        $Win25Sql25vmName = 'win25sql25'
        $UbuntuVMNames = @('ubu24sql25', 'ubu24')
        Mock Install-ArcBoxSqlExtension {}
        Mock Set-ArcBoxServerManagement { $script:actualTargets = @($WindowsMachines) + @($LinuxMachines) }
        & ([scriptblock]::Create($loop.Extent.Text))
        & ([scriptblock]::Create($management.Extent.Text))
        $SQLvmName | Should -BeExactly 'win22sql22'
        $script:actualTargets.Count | Should -Be 6
        @($script:actualTargets | Sort-Object -Unique).Count | Should -Be 6
        $script:actualTargets | Should -Contain 'win22sql22'
    }
}

Describe 'Explicit audit baseline guest assignment' {
    It 'creates missing audit assignments from built-in metadata without applying settings' {
        Mock Get-ArcBoxBaselineAssignment { $null }
        Mock Invoke-ArcBoxServerAz {
            '{"metadata":{"guestConfiguration":{"name":"AzureWindowsBaseline","version":"1.*","configurationParameter":{"BaselineSettings":"AzureWindowsBaseline;BaselineSettings"}}},"parameters":{"BaselineSettings":{"defaultValue":"built-in-defaults"}}}'
        } -ParameterFilter { $Arguments[0] -eq 'policy' }
        Mock Invoke-AzRestMethod {
            $body = $Payload | ConvertFrom-Json
            $body.properties.guestConfiguration.assignmentType | Should -Be 'Audit'
            $body.properties.guestConfiguration.configurationParameter[0].value | Should -Be 'built-in-defaults'
            @{ StatusCode = 201 }
        }
        Set-ArcBoxBaselineAudit -MachineName win19sql16 -OS Windows
        Should -Invoke Invoke-AzRestMethod -Exactly -Times 1
    }
    It 'preserves existing baseline assignments' {
        Mock Get-ArcBoxBaselineAssignment { @{ name = 'AzureWindowsBaseline' } }
        Mock Invoke-AzRestMethod { throw 'Must not replace an existing assignment.' }
        Set-ArcBoxBaselineAudit -MachineName win22sql22 -OS Windows
        Should -Invoke Invoke-AzRestMethod -Times 0
    }
    It 'reads the actual per-machine report instead of a collection that omits explicit assignments' {
        Mock Invoke-AzRestMethod { @{ StatusCode = 200; Content = '{"name":"AzureWindowsBaseline","properties":{"complianceStatus":"NonCompliant"}}' } }
        Mock Invoke-ArcBoxServerAz { throw 'Must not use the incomplete assignment collection.' }
        Wait-ArcBoxBaselineReport -MachineName win19sql16 -OS Windows | Should -Be 'NonCompliant'
        Should -Invoke Invoke-AzRestMethod -Exactly -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Path -like '*/guestConfigurationAssignments/AzureWindowsBaseline?api-version=*' }
    }
    It 'treats only an actual 404 as a missing assignment' {
        Mock Invoke-AzRestMethod { @{ StatusCode = 404 } }
        Get-ArcBoxBaselineAssignment -MachineName win19sql16 -OS Windows | Should -BeNullOrEmpty
        Mock Invoke-AzRestMethod { @{ StatusCode = 403 } }
        { Get-ArcBoxBaselineAssignment -MachineName win19sql16 -OS Windows } | Should -Throw '*HTTP 403*'
        Mock Invoke-AzRestMethod { throw 'Transport unavailable' }
        { Get-ArcBoxBaselineAssignment -MachineName win19sql16 -OS Windows } | Should -Throw '*Transport unavailable*'
    }
}

Describe 'Linux guest file-copy startup readiness' {
    BeforeEach {
        $script:source = Join-Path $TestDrive 'authorized_keys'
        Set-Content -LiteralPath $script:source -Value 'public-test-key'
        Mock Start-Sleep {}
    }
    It 'retries the observed 0x80004005 startup failure with the exact directory destination' {
        $script:copies = 0
        Mock Copy-VMFile {
            $script:copies++
            if ($script:copies -eq 1) { throw 'Unspecified error (0x80004005)' }
        }
        Copy-ArcBoxLinuxGuestFile -VMName ubu24 -SourcePath $script:source -DestinationDirectory '/home/jumpstart/.ssh'
        Should -Invoke Copy-VMFile -Exactly -Times 2 -ParameterFilter { $DestinationPath -eq '/home/jumpstart/.ssh' -and $Name -eq 'ubu24' -and $CreateFullPath }
    }
    It 'does not retry unrelated copy errors' {
        Mock Copy-VMFile { throw 'Access denied (0x80070005)' }
        { Copy-ArcBoxLinuxGuestFile -VMName ubu24 -SourcePath $script:source -DestinationDirectory '/home/jumpstart/.ssh' } | Should -Throw '*Access denied*'
        Should -Invoke Copy-VMFile -Exactly -Times 1
    }
    It 'bounds retries even if integration services report healthy' {
        $script:clock = 0
        Mock Get-Date {
            $script:clock++
            [datetime]'2026-01-01' + [timespan]::FromMinutes(5 * ($script:clock - 1))
        }
        Mock Copy-VMFile { throw 'Unspecified error (0x80004005)' }
        { Copy-ArcBoxLinuxGuestFile -VMName ubu24 -SourcePath $script:source -DestinationDirectory '/home/jumpstart/.ssh' } | Should -Throw '*0x80004005*'
        Should -Invoke Start-Sleep -Exactly -Times 0
    }
}

Describe 'ITPro management infrastructure and naming' {
    It 'assigns only audit baselines to Arc machines, excluding the Azure host' {
        $template = Get-Content (Join-Path $root 'ARM\mgmt\policyAzureArcBuiltins.json') -Raw | ConvertFrom-Json
        $baselines = @($template.resources | Where-Object name -eq "[variables('computeBaselines')[copyIndex()].name]")
        $baselines.Count | Should -Be 1
        $baselines[0].properties.parameters.effect.value | Should -Be 'AuditIfNotExists'
        $baselines[0].properties.parameters.IncludeArcMachines.value | Should -Be 'true'
        $baselines[0].properties.resourceSelectors[0].selectors[0].in | Should -Contain 'Microsoft.HybridCompute/machines'
    }
    It 'declares native OTel and inventory streams without collecting file contents' {
        $template = Get-Content (Join-Path $root 'ARM\mgmt\arcServerMonitoring.json') -Raw | ConvertFrom-Json
        $otel = $template.resources | Where-Object name -eq "[format('{0}-OTel', parameters('namingPrefix'))]"
        $otel.properties.dataSources.performanceCountersOTel[0].streams | Should -Contain 'Microsoft-OtelPerfMetrics'
        $otel.properties.destinations.monitoringAccounts.Count | Should -Be 1
        $template.variables.changeStreams | Should -Contain 'Microsoft-ConfigurationData'
        $source = Get-Content (Join-Path $root 'bicep\mgmt\arcServerMonitoring.bicep') -Raw
        $source | Should -Match 'enableFiles: false'
        $source | Should -Match 'enableRegistry: false'
    }
    It 'activates the workspace solution and both tables before creating the inventory rule' {
        $template = Get-Content (Join-Path $root 'ARM\mgmt\arcServerMonitoring.json') -Raw | ConvertFrom-Json
        $solution = @($template.resources | Where-Object type -eq 'Microsoft.OperationsManagement/solutions')
        $solution.Count | Should -Be 1
        $solution[0].plan.product | Should -Be 'OMSGallery/ChangeTracking'
        $tables = @($template.resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces/tables')
        $tables.Count | Should -Be 1
        $tables[0].copy.count | Should -Be "[length(createArray('ConfigurationChange', 'ConfigurationData'))]"
        ($tables[0].dependsOn -join '') | Should -Match 'Microsoft.OperationsManagement/solutions'
        $inventory = $template.resources | Where-Object name -eq "[format('{0}-Inventory', parameters('namingPrefix'))]"
        ($inventory.dependsOn -join '') | Should -Match 'inventoryTables'
    }
    It 'budgets exactly 24 GB across the six named guests and retains source image names' {
        $source = Get-Content (Join-Path $root 'artifacts\dsc\virtual_machines_itpro.dsc.yml') -Raw
        $source | Should -Match '(?s)Name: ubu24sql25.*?VhdPath: [^\r\n]+Ubuntu-01\.vhdx.*?StartupMemory: ''4GB'''
        $source | Should -Match '(?s)Name: ubu24\s.*?VhdPath: [^\r\n]+Ubuntu-02\.vhdx.*?StartupMemory: ''2GB'''
        $sql = Get-Content (Join-Path $root 'artifacts\dsc\virtual_machines_sql.dsc.yml') -Raw
        $sum = ([regex]::Matches("$source`n$sql", "StartupMemory: '(\d+)GB'") | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum).Sum
        $sum | Should -Be 24
        $logon = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $logon | Should -Not -Match 'Get-VM \*Ubuntu\*'
        $logon | Should -Match 'sudo -n hostnamectl set-hostname \$Name 2>&1'
        $logon | Should -Match 'Install-ArcBoxServerExtension -MachineName \$Ubuntu01vmName -Name ''LinuxAgent.SqlServer'''
        $logon | Should -Not -Match 'Install-ArcBoxServerExtension -MachineName \$Ubuntu02vmName -Name ''LinuxAgent.SqlServer'''
        $agent = Get-Content (Join-Path $root 'artifacts\installArcAgentUbuntu.sh') -Raw
        $agent | Should -Match 'ArcServerResourceName=\$\(hostname\)'
        $agent | Should -Not -Match 'hostname \|sed'
    }
    It 'gives the client only workspace-scoped metrics query access before bootstrap' {
        $source = Get-Content (Join-Path $root 'bicep\clientVm\clientVm.bicep') -Raw
        $source | Should -Match '(?s)vmBootstrap.*?dependsOn: \[.*?vmMetricsReader'
        $source | Should -Match '(?s)resource vmMetricsReader.*?scope: metricsWorkspace'
    }
    It 'allows guest SSH on any network profile only from the internal lab subnet' {
        $source = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $source | Should -Match "New-NetFirewallRule -Name 'ArcBox-SSH'[^\r\n]+-Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress '10.10.1.0/24'"
        $source | Should -Match "Set-NetFirewallRule[^\r\n]+-Profile Any -Protocol TCP -LocalPort 22 -RemoteAddress '10.10.1.0/24'"
    }
    It 'installs the Log Analytics query module explicitly for ITPro' {
        $source = Get-Content (Join-Path $root 'artifacts\Bootstrap.ps1') -Raw
        $source | Should -Match '(?s)if \(\$flavor -eq "ITPro"\) \{\s+\$modules \+= "Az.OperationalInsights"'
    }
}

Describe 'Linux native stderr over PowerShell remoting' {
    BeforeAll {
        $source = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $rename = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                $node.ScriptBlock.Extent.Text -match 'param\(\[string\]\$Name\)' -and
                $node.ScriptBlock.Extent.Text -match 'hostnamectl'
        }, $true)
        $renameScript = [scriptblock]::Create($rename.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
        function sudo {
            param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
            Write-Error 'Synchronizing state of ssh.service with SysV service script.' -ErrorAction Continue
            $global:LASTEXITCODE = 0
        }
    }
    It 'does not treat informational stderr with exit zero as remote failure' {
        { $ErrorActionPreference = 'Stop'; & $renameScript ubu24sql25 } | Should -Not -Throw
    }
    It 'still rejects an actual SSH enable failure' {
        Mock sudo { $global:LASTEXITCODE = if ($Arguments -contains 'systemctl') { 1 } else { 0 } }
        { & $renameScript ubu24sql25 } | Should -Throw '*Could not enable Ubuntu OpenSSH*'
    }
    It 'merges installer and onboarding stderr while explicitly checking native exit codes' {
        $source | Should -Match '(?m)InstallNestedSqlServerUbuntu.sh \$Mode 2>&1 \| ForEach-Object'
        $source | Should -Match 'Linux Arc onboarding failed \(exit code \$LASTEXITCODE\)'
    }
    It 'generates the onboarding shell artifact with no CR bytes on Windows' {
        $pipeline = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Set-Content' -and
                $node.Extent.Text -match 'installArcAgentModifiedUbuntu.sh'
        }, $true).Parent
        $agentScript = Join-Path $TestDrive 'agents'
        $null = New-Item -Path $agentScript -ItemType Directory
        Copy-Item (Join-Path $root 'artifacts\installArcAgentUbuntu.sh') (Join-Path $agentScript 'installArcAgentUbuntu.sh')
        $accessToken = 'synthetic-test-token'
        $resourceGroup = 'test-rg'
        $subscriptionId = '00000000-0000-0000-0000-000000000001'
        & ([scriptblock]::Create($pipeline.Extent.Text))
        $bytes = [IO.File]::ReadAllBytes((Join-Path $agentScript 'installArcAgentModifiedUbuntu.sh'))
        $bytes.Length | Should -BeGreaterThan 0
        $bytes | Should -Not -Contain 13
    }
}

Describe 'Ubuntu SQL sample parity and installer contracts' {
    BeforeAll { $source = Get-Content (Join-Path $root 'artifacts\InstallNestedSqlServerUbuntu.sh') -Raw }
    It 'uses the supported repository and SQL 2025 Developer identifier' {
        $source | Should -Match 'ubuntu/24\.04/mssql-server-2025\.list'
        $source | Should -Match 'MSSQL_PID=EnterpriseDeveloper'
        $source | Should -Match 'Developer\|Evaluation'
        $source | Should -Match "ProductMajorVersion.*<> 17"
    }

    Describe 'Linux SQL configured memory verification' {
        BeforeAll {
            $source = Get-Content (Join-Path $root 'artifacts\tests\itpro.tests.ps1') -Raw
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
            $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$memory' -and $node.Right.Extent.Text -match 'configparser'
            }, $true)
            $guard = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Extent.Text -match 'Linux SQL memory limit is not 2048 MB'
            }, $true)
            $check = [scriptblock]::Create("$($assignment.Extent.Text)`n$($guard.Extent.Text)")
            function sudo { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) throw 'Unexpected memory query.' }
        }
        It 'accepts only the exact configured 2048-MB value' {
            Mock sudo { $global:LASTEXITCODE = 0; '2048' }
            { & $check } | Should -Not -Throw
            Mock sudo { $global:LASTEXITCODE = 0; '20480' }
            { & $check } | Should -Throw '*not 2048 MB*'
        }
    }
    It 'receives the secret on stdin and enforces bounded setup and SQL memory' {
        $source | Should -Match 'IFS= read -r MSSQL_SA_PASSWORD'
        $source | Should -Match 'timeout --kill-after=30s 15m'
        $source | Should -Match 'memory\.memorylimitmb 2048'
        $source | Should -Not -Match '\-P[ =].*PASSWORD'
        $source | Should -Not -Match 'set -x'
    }
    It 'restores the matching sample without assuming backup logical filenames' {
        $source | Should -Match 'AdventureWorksLT2025\.bak'
        $source | Should -Match 'RESTORE FILELISTONLY'
        $source | Should -Not -Match 'AdventureWorksLT2025_Data'
        $source | Should -Match 'IF DB_ID\(N''ArchiveDB''\) IS NULL'
        $source | Should -Not -Match 'DROP DATABASE'
    }
    It 'creates the matching ArchiveDB schema with supported binary storage and full recovery' {
        $source | Should -Match 'Id uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE'
        $source | Should -Match 'SerialNumber int UNIQUE'
        $source | Should -Match 'Chart varbinary\(max\) NULL'
        $source | Should -Not -Match 'CONTAINS FILESTREAM|varbinary\(max\) FILESTREAM'
        $source | Should -Match 'ALTER DATABASE \[ArchiveDB\] SET RECOVERY FULL'
        $source | Should -Match 'BEGIN TRANSACTION'
        $source | Should -Match 'ROLLBACK'
        $source | Should -Match 'SalesLT.Customer'
    }
}

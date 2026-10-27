#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.6.0' }

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $root 'artifacts\ArcBoxWindows2016.ps1')
    function Get-VM { param($Name) }
    function Get-VMHardDiskDrive { param([Parameter(ValueFromPipeline)]$VM) }
    function New-VHD { param($Path, $SizeBytes, [switch]$Dynamic) }
    function Mount-VHD { param($Path, [switch]$PassThru) }
    function Dismount-VHD { param($Path) }
    function Get-WindowsImage { param($ImagePath, $Index) }
    function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) }
    function Get-Disk { param([Parameter(ValueFromPipeline)]$InputObject) }
    function Initialize-Disk { param([Parameter(ValueFromPipeline)]$InputObject, $PartitionStyle) }
    function New-Partition { param($DiskNumber, $Size, $GptType, [switch]$AssignDriveLetter, [switch]$UseMaximumSize) }
    function Format-Volume { param([Parameter(ValueFromPipeline)]$InputObject, $FileSystem, [switch]$Confirm) }
    function Copy-VMFile { param($Name, $SourcePath, $DestinationPath, $FileSource, [switch]$CreateFullPath, [switch]$Force) }
    function Restart-VM { param($Name, [switch]$Force) }
    function Wait-VM { param($For, $Timeout) }
    function cscript.exe { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    function New-TestProcess {
        param([int]$ExitCode = 0, [bool]$Completes = $true)
        $process = [pscustomobject]@{ Id = 12345; ExitCode = $ExitCode; Completes = $Completes }
        $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $this.Completes }
        $process | Add-Member ScriptMethod Refresh {}
        $process
    }
}

Describe 'Windows Server 2016 evaluation disk construction' {
    BeforeEach {
        $mediaDirectory = New-Item -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -ItemType Directory
        $destination = Join-Path $mediaDirectory.FullName 'ArcBox-Win2K16.vhdx'
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'Test<&>Password1!' -AsPlainText -Force))
        Mock Get-VM {}
        Mock Get-VMHardDiskDrive {}
        Mock Get-Item { [pscustomobject]@{ Length = 6972221440 } } -ParameterFilter { $LiteralPath -like '*.iso*' }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'test media' }
        Mock Mount-DiskImage { [pscustomobject]@{ ImagePath = $ImagePath } }
        Mock Dismount-DiskImage {}
        Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'I' } }
        Mock Get-WindowsImage {
            if ($Index) {
                [pscustomobject]@{
                    ImageIndex = $Index; EditionId = 'ServerDatacenterEval'; Build = 14393; Architecture = 9
                    InstallationType = $(if ($Index -eq 1) { 'Server Core' } else { 'Server' })
                }
            } else {
                [pscustomobject]@{ ImageIndex = 1 }
                [pscustomobject]@{ ImageIndex = 2 }
            }
        }
        Mock New-VHD { $null = New-Item -Path $Path -ItemType File }
        Mock Mount-VHD { [pscustomobject]@{ Path = $Path } }
        Mock Dismount-VHD {}
        Mock Get-Disk { [pscustomobject]@{ Number = 12345 } }
        Mock Initialize-Disk {}
        Mock New-Partition { [pscustomobject]@{ DiskNumber = $DiskNumber } }
        Mock Format-Volume { [pscustomobject]@{ DriveLetter = 'TestDrive' } }
        Mock Set-Acl {
            if ($LiteralPath -like '*Unattend.xml') {
                (Get-Content -LiteralPath $LiteralPath -Raw) | Should -BeNullOrEmpty
                $AclObject.AreAccessRulesProtected | Should -BeTrue
            }
        }
        Mock Start-Process { New-TestProcess }
        Mock Stop-Process {}
    }
    It 'builds a UEFI disk from the Desktop Experience image and safely escapes the runtime password' {
        Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential
        Test-Path -LiteralPath $destination | Should -BeTrue
        Test-Path -LiteralPath "$destination.building.vhdx" | Should -BeFalse
        [xml]$answer = Get-Content -LiteralPath 'TestDrive:\Windows\Panther\Unattend.xml' -Raw
        $answer.unattend.settings[0].component.ComputerName | Should -Be 'win16sql16'
        $answer.unattend.settings[1].component[1].UserAccounts.AdministratorPassword.Value | Should -Be 'Test<&>Password1!'
        Should -Invoke Set-Acl -Exactly -Times 2
        Should -Invoke New-VHD -Exactly -Times 1 -ParameterFilter { $SizeBytes -eq 60GB -and $Dynamic }
        Should -Invoke Initialize-Disk -Exactly -Times 1 -ParameterFilter { $PartitionStyle -eq 'GPT' }
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter {
            $FilePath -like '*\dism.exe' -and $ArgumentList -contains '/Index:2' -and $ArgumentList -contains '/CheckIntegrity'
        }
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter {
            $FilePath -like '*\bcdboot.exe' -and $ArgumentList -contains 'UEFI'
        }
        Should -Invoke Dismount-VHD -Exactly -Times 1
        Should -Invoke Dismount-DiskImage -Exactly -Times 1
    }
    It 'reuses a completed disk without downloading or mounting media' {
        $null = New-Item -Path $destination -ItemType File
        Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Mount-DiskImage -Times 0
    }
    It 'refuses an attached target or an unresolved interrupted build' {
        Mock Get-VM { [pscustomobject]@{ Name = 'test' } }
        Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = $destination } }
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*attached*'
        Mock Get-VMHardDiskDrive {}
        $null = New-Item -Path "$destination.building.vhdx" -ItemType File
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*interrupted image build*'
        Should -Invoke Invoke-WebRequest -Times 0
    }
    It 'cleans up an incomplete ISO download without mounting it' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value partial; throw 'Download failed' }
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*Download failed*'
        Test-Path (Join-Path $mediaDirectory.FullName 'WindowsServer2016Evaluation.iso.download') | Should -BeFalse
        Should -Invoke Mount-DiskImage -Times 0
    }
    It 'rejects the wrong Windows image instead of relabeling it' {
        Mock Get-WindowsImage {
            if ($Index) {
                [pscustomobject]@{ ImageIndex = 1; EditionId = 'ServerDatacenterEval'; InstallationType = 'Server'; Build = 17763; Architecture = 9 }
            } else { [pscustomobject]@{ ImageIndex = 1 } }
        }
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*exactly one Windows Server 2016*'
        Should -Invoke New-VHD -Times 0
        Should -Invoke Dismount-DiskImage -Exactly -Times 1
    }
    It 'does not publish a disk after <Tool> fails and always detaches temporary media' -ForEach @(
        @{ Tool = 'dism.exe' }, @{ Tool = 'bcdboot.exe' }
    ) {
        $script:failingTool = $Tool
        Mock Start-Process { New-TestProcess -ExitCode $(if ($FilePath.EndsWith($script:failingTool)) { 50 } else { 0 }) }
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*exit code 50*'
        Test-Path -LiteralPath $destination | Should -BeFalse
        Test-Path -LiteralPath "$destination.building.vhdx" | Should -BeFalse
        Should -Invoke Dismount-VHD -Exactly -Times 1
        Should -Invoke Dismount-DiskImage -Exactly -Times 1
    }
    It 'bounds image application and stops only the timed-out process' {
        Mock Start-Process { New-TestProcess -Completes $false }
        { Save-ArcBoxWindows2016Disk -DestinationPath $destination -Credential $credential } | Should -Throw '*60-minute limit*'
        Should -Invoke Stop-Process -Exactly -Times 1 -ParameterFilter { $Id -eq 12345 -and $Force }
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
}

Describe 'Windows Server 2016 first boot and prerequisites' {
    BeforeEach {
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'TestPassword1!' -AsPlainText -Force))
        Mock Invoke-Command { & $ScriptBlock @ArgumentList }
        Mock Get-CimInstance { @{ BuildNumber = '14393'; Caption = 'Microsoft Windows Server 2016 Datacenter Evaluation' } }
        Mock Start-Sleep {}
    }
    It 'removes runtime answer files only after successful first boot with the expected OS' {
        $script:removedPaths = @()
        Mock Test-Path { $true }
        Mock Remove-Item { $script:removedPaths += $LiteralPath }
        Wait-ArcBoxWindows2016Guest -Credential $credential
        $script:removedPaths | Should -Contain 'C:\Windows\Panther\Unattend.xml'
        $script:removedPaths | Should -Contain 'C:\Windows\Panther\Unattend\Unattend.xml'
    }
    It 'does not accept an existing guest running the wrong Windows version' {
        Mock Get-CimInstance { @{ BuildNumber = '17763'; Caption = 'Microsoft Windows Server 2019 Datacenter' } }
        { Wait-ArcBoxWindows2016Guest -Credential $credential } | Should -Throw '*must run Windows Server 2016*'
    }
    It 'bounds first-boot authentication waits' {
        $script:clock = 0
        Mock Get-Date { $script:clock++; [datetime]'2026-01-01' + [timespan]::FromMinutes(20 * ($script:clock - 1)) }
        Mock Invoke-Command { throw 'Guest not ready' }
        { Wait-ArcBoxWindows2016Guest -Credential $credential } | Should -Throw '*within 15 minutes*'
    }
    It 'installs signed .NET 4.8, restarts, then verifies prerequisites before SQL and Arc' {
        $script:frameworkInstalled = $false
        Mock Wait-ArcBoxWindows2016Guest {}
        Mock Get-ItemProperty { @{ Release = $(if ($script:frameworkInstalled) { 528049 } else { 394802 }) } } -ParameterFilter { $Name -eq 'Release' }
        Mock Test-Path { $false }
        Mock Invoke-WebRequest {}
        Mock Move-Item {}
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } } }
        Mock Copy-VMFile {}
        Mock Start-Process { $script:frameworkInstalled = $true; New-TestProcess -ExitCode 3010 }
        Mock Restart-VM {}
        Mock Get-VM {}
        Mock Wait-VM {}
        Mock New-ItemProperty {}
        Initialize-ArcBoxWindows2016Guest -Credential $credential -MediaDirectory $TestDrive
        Should -Invoke Copy-VMFile -Exactly -Times 1 -ParameterFilter { $Name -eq 'win16sql16' -and $DestinationPath -eq 'C:\ArcBox\ndp48.exe' }
        Should -Invoke Restart-VM -Exactly -Times 1 -ParameterFilter { $Name -eq 'win16sql16' }
        Should -Invoke Wait-ArcBoxWindows2016Guest -Exactly -Times 2
        Should -Invoke New-ItemProperty -Exactly -Times 4
    }
    It 'rejects an unsigned framework installer before copying it into the guest' {
        Mock Wait-ArcBoxWindows2016Guest {}
        Mock Get-ItemProperty { @{ Release = 394802 } }
        Mock Test-Path { $true }
        Mock Get-AuthenticodeSignature { @{ Status = 'NotSigned' } }
        Mock Copy-VMFile {}
        { Initialize-ArcBoxWindows2016Guest -Credential $credential -MediaDirectory $TestDrive } | Should -Throw '*valid Microsoft Corporation signature*'
        Should -Invoke Copy-VMFile -Times 0
    }
    It 'does not reinstall .NET or restart an already prepared guest on retries' {
        Mock Wait-ArcBoxWindows2016Guest {}
        Mock Get-ItemProperty { @{ Release = 528049 } }
        Mock Invoke-WebRequest { throw 'Must not download on retry.' }
        Mock Restart-VM {}
        Mock New-ItemProperty {}
        Initialize-ArcBoxWindows2016Guest -Credential $credential -MediaDirectory $TestDrive
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Restart-VM -Times 0
    }
}

Describe 'Scoped Windows Server 2016 evaluation activation' {
    BeforeEach {
        $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'TestPassword1!' -AsPlainText -Force))
        Mock Invoke-Command { & $ScriptBlock @ArgumentList }
        Mock Get-CimInstance { @{ BuildNumber = '14393'; Caption = 'Microsoft Windows Server 2016 Datacenter Evaluation' } } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        Mock cscript.exe { $global:LASTEXITCODE = 0 }
    }
    It 'reuses an activated, unexpired evaluation without installing a KMS key' {
        Mock Get-CimInstance { @{ LicenseStatus = 1; Description = 'Windows, TIMEBASED_EVAL channel'; GracePeriodRemaining = 259200 } } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
        Set-ArcBoxWindows2016EvaluationActivation -Credential $credential
        Should -Invoke cscript.exe -Times 0
    }
    It 'requires actual unexpired evaluation state even after activation returns success' -ForEach @(
        @{ Status = 0; Remaining = 259200; Channel = 'TIMEBASED_EVAL' },
        @{ Status = 1; Remaining = 0; Channel = 'TIMEBASED_EVAL' },
        @{ Status = 1; Remaining = 259200; Channel = 'VOLUME_KMSCLIENT' }
    ) {
        $script:license = @{ LicenseStatus = $Status; Description = $Channel; GracePeriodRemaining = $Remaining }
        Mock Get-CimInstance { $script:license } -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
        { Set-ArcBoxWindows2016EvaluationActivation -Credential $credential } | Should -Throw '*activated, unexpired evaluation license*'
        Should -Invoke cscript.exe -Exactly -Times 1 -ParameterFilter { $Arguments -contains '-ato' -and $Arguments -notcontains '-ipk' -and $Arguments -notcontains '-skms' }
    }
    It 'rejects evaluation activation for any other OS pairing' {
        Mock Get-CimInstance { @{ BuildNumber = '17763'; Caption = 'Microsoft Windows Server 2019 Datacenter Evaluation' } } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        { Set-ArcBoxWindows2016EvaluationActivation -Credential $credential } | Should -Throw '*restricted to Windows Server 2016*'
        Should -Invoke cscript.exe -Times 0
    }
    It 'surfaces an activation failure instead of accepting the trial as licensed' {
        Mock Get-CimInstance {} -ParameterFilter { $ClassName -eq 'SoftwareLicensingProduct' }
        Mock cscript.exe { $global:LASTEXITCODE = 5 }
        { Set-ArcBoxWindows2016EvaluationActivation -Credential $credential } | Should -Throw '*activation failed (exit code 5)*'
    }
}

Describe 'ITPro Windows image and SQL version wiring' {
    It 'rejects the previous guest pair rather than reusing its disks for a different SQL/OS pairing' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $guard = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -like "*'win19sql16', 'win22sql19'*"
        }, $true)
        Mock Get-VM { [pscustomobject]@{ Name = 'win19sql16' } }
        { & ([scriptblock]::Create($guard.Extent.Text)) } | Should -Throw '*new ITPro environment*'
    }
    It 'uses matching images and SQL versions while retaining all management targets' {
        $source = Get-Content (Join-Path $root 'artifacts\ArcServersLogonScript.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        foreach ($variable in @('$Win16Sql16vmName', '$Win19Sql19vmName', '$Win25Sql25vmName')) {
            $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $variable
            }, $true)
            . ([scriptblock]::Create($assignment.Extent.Text))
        }
        $loop = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'sqlGuest'
        }, $true)
        $guests = @(& ([scriptblock]::Create($loop.Condition.Extent.Text)))
        $guests[0].Name | Should -Be 'win16sql16'
        $guests[0].Version | Should -Be '2016'
        $guests[1].Name | Should -Be 'win19sql19'
        $guests[1].Version | Should -Be '2019'
        $configuration = Get-Content (Join-Path $root 'artifacts\dsc\virtual_machines_itpro.dsc.yml') -Raw
        $configuration | Should -Match '(?s)Name: win16sql16\s+SwitchName: [^\r\n]+\s+VhdPath: [^\r\n]+Win2K16\.vhdx'
        $configuration | Should -Match '(?s)Name: win19sql19\s+SwitchName: [^\r\n]+\s+VhdPath: [^\r\n]+Win2K19\.vhdx'
        $source | Should -Not -Match "ArcBox-Win2K22\.vhdx"
        $source | Should -Match 'Set-ArcBoxWindows2016EvaluationActivation -Credential \$winCreds'
        $source | Should -Match '(?s)foreach \(\$vmName in @\(\$Win19Sql19vmName, \$Win25Sql25vmName\)\) \{\s+Set-ArcBoxWindowsActivation'
        $bootstrap = Get-Content (Join-Path $root 'artifacts\Bootstrap.ps1') -Raw
        $bootstrap | Should -Match 'artifacts/ArcBoxWindows2016.ps1'
    }
}

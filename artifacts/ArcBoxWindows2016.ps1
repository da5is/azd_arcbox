function Save-ArcBoxWindows2016Disk {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][pscredential]$Credential
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Write-Host "Reusing Windows Server 2016 guest disk $DestinationPath."
        return
    }
    $temporaryPath = "$DestinationPath.building.vhdx"
    $attachedDisks = @(Get-VM -ErrorAction Stop | Get-VMHardDiskDrive -ErrorAction Stop)
    if ($attachedDisks.Path -contains $DestinationPath -or $attachedDisks.Path -contains $temporaryPath) {
        throw 'Refusing to build over an attached Windows Server 2016 guest disk.'
    }
    if (Test-Path -LiteralPath $temporaryPath) {
        throw "An interrupted image build exists at '$temporaryPath'. Verify it is detached before removing that incomplete file and retrying."
    }
    $isoPath = Join-Path (Split-Path $DestinationPath -Parent) 'WindowsServer2016Evaluation.iso'
    if (-not (Test-Path -LiteralPath $isoPath)) {
        try {
            Invoke-WebRequest -Uri 'https://software-static.download.prss.microsoft.com/pr/download/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO' -OutFile "$isoPath.download" -TimeoutSec 3600 -ErrorAction Stop
            if ((Get-Item -LiteralPath "$isoPath.download" -ErrorAction Stop).Length -ne 6972221440) {
                throw 'The Windows Server 2016 evaluation ISO download is incomplete or has changed.'
            }
            Move-Item -LiteralPath "$isoPath.download" -Destination $isoPath -ErrorAction Stop
        } finally {
            if (Test-Path -LiteralPath "$isoPath.download") { Remove-Item -LiteralPath "$isoPath.download" -Force -ErrorAction Stop }
        }
    }
    if ((Get-Item -LiteralPath $isoPath -ErrorAction Stop).Length -ne 6972221440) {
        throw "Invalid cached Windows Server 2016 ISO at '$isoPath'; remove it before retrying."
    }

    $isoMounted = $false
    $vhdMounted = $false
    try {
        $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
        $isoMounted = $true
        $volume = $iso | Get-Volume -ErrorAction Stop | Where-Object DriveLetter | Select-Object -First 1
        if ($null -eq $volume) { throw 'The Windows Server 2016 ISO has no mounted volume.' }
        $wimPath = "$($volume.DriveLetter):\sources\install.wim"
        $images = @(Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop | ForEach-Object {
            Get-WindowsImage -ImagePath $wimPath -Index $_.ImageIndex -ErrorAction Stop
        } | Where-Object {
            $_.EditionId -eq 'ServerDatacenterEval' -and $_.InstallationType -eq 'Server' -and
            $_.Build -eq 14393 -and $_.Architecture -eq 9
        })
        if ($images.Count -ne 1) { throw 'Expected exactly one Windows Server 2016 Datacenter Evaluation Desktop Experience x64 image.' }

        $null = New-VHD -Path $temporaryPath -SizeBytes 60GB -Dynamic -ErrorAction Stop
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
        }
        Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
        $vhd = Mount-VHD -Path $temporaryPath -PassThru -ErrorAction Stop
        $vhdMounted = $true
        $disk = $vhd | Get-Disk -ErrorAction Stop
        $disk | Initialize-Disk -PartitionStyle GPT -ErrorAction Stop
        $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter -ErrorAction Stop |
            Format-Volume -FileSystem FAT32 -Confirm:$false -ErrorAction Stop
        $null = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -ErrorAction Stop
        $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop |
            Format-Volume -FileSystem NTFS -Confirm:$false -ErrorAction Stop
        $windowsRoot = "$($windows.DriveLetter):\"
        $process = Start-Process -FilePath "$env:windir\System32\dism.exe" -ArgumentList @(
            '/Apply-Image', "/ImageFile:`"$wimPath`"", "/Index:$($images[0].ImageIndex)",
            "/ApplyDir:$windowsRoot", '/CheckIntegrity', '/Quiet'
        ) -PassThru -ErrorAction Stop
        if (-not $process.WaitForExit(3600000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            throw 'Windows Server 2016 image application exceeded the 60-minute limit.'
        }
        $process.Refresh()
        if ($process.ExitCode -ne 0) { throw "Windows Server 2016 image application failed (DISM exit code $($process.ExitCode))." }
        # Newer host BCDBoot can select EFI_EX files absent from the Server 2016 image.
        $process = Start-Process -FilePath "${windowsRoot}Windows\System32\bcdboot.exe" -ArgumentList @(
            "`"${windowsRoot}Windows`"", '/s', "$($efi.DriveLetter):", '/f', 'UEFI'
        ) -PassThru -ErrorAction Stop
        if (-not $process.WaitForExit(300000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            throw 'Windows Server 2016 boot configuration exceeded the five-minute limit.'
        }
        $process.Refresh()
        if ($process.ExitCode -ne 0) { throw "Windows Server 2016 boot configuration failed (BCDBoot exit code $($process.ExitCode))." }

        # This runtime-only answer file contains the shared secret; restrict access before writing it.
        $answerPath = Join-Path $windowsRoot 'Windows\Panther\Unattend.xml'
        $null = New-Item -Path (Split-Path $answerPath -Parent) -ItemType Directory -Force -ErrorAction Stop
        $null = New-Item -Path $answerPath -ItemType File -Force -ErrorAction Stop
        Set-Acl -LiteralPath $answerPath -AclObject $acl -ErrorAction Stop
        $password = [System.Security.SecurityElement]::Escape($Credential.GetNetworkCredential().Password)
        @"
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>win16sql16</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>1</ProtectYourPC></OOBE>
      <UserAccounts><AdministratorPassword><Value>$password</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
    </component>
  </settings>
</unattend>
"@ | Set-Content -LiteralPath $answerPath -Encoding utf8 -NoNewline -ErrorAction Stop
        Dismount-VHD -Path $temporaryPath -ErrorAction Stop
        $vhdMounted = $false
        Move-Item -LiteralPath $temporaryPath -Destination $DestinationPath -ErrorAction Stop
    } finally {
        if ($vhdMounted) { Dismount-VHD -Path $temporaryPath -ErrorAction Stop }
        if ($isoMounted) { Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop }
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop }
    }
}

function Wait-ArcBoxWindows2016Guest {
    param([Parameter(Mandatory)][pscredential]$Credential)

    $deadline = (Get-Date).AddMinutes(15)
    do {
        try {
            $os = Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
                Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object BuildNumber, Caption
            }
            break
        } catch {
            if ((Get-Date) -ge $deadline) { throw 'Windows Server 2016 did not finish first-boot setup within 15 minutes.' }
            Start-Sleep -Seconds 10
        }
    } while ($true)
    if ($os.BuildNumber -ne '14393' -or $os.Caption -notmatch 'Windows Server 2016 Datacenter Evaluation') {
        throw 'win16sql16 must run Windows Server 2016 Datacenter Evaluation, build 14393.'
    }
    Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        foreach ($path in @('C:\Windows\Panther\Unattend.xml', 'C:\Windows\Panther\Unattend\Unattend.xml')) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        }
    }
}

function Initialize-ArcBoxWindows2016Guest {
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$MediaDirectory
    )

    Wait-ArcBoxWindows2016Guest -Credential $Credential
    $needsFramework = Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release -lt 528040
    }
    if ($needsFramework) {
        $installerPath = Join-Path $MediaDirectory 'ndp48-x86-x64-allos-enu.exe'
        if (-not (Test-Path -LiteralPath $installerPath)) {
            try {
                Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2088631' -OutFile "$installerPath.download" -TimeoutSec 900 -ErrorAction Stop
                Move-Item -LiteralPath "$installerPath.download" -Destination $installerPath -ErrorAction Stop
            } finally {
                if (Test-Path -LiteralPath "$installerPath.download") { Remove-Item -LiteralPath "$installerPath.download" -Force -ErrorAction Stop }
            }
        }
        $signature = Get-AuthenticodeSignature -FilePath $installerPath -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw 'The .NET Framework 4.8 installer does not have a valid Microsoft Corporation signature.'
        }
        Copy-VMFile -Name win16sql16 -SourcePath $installerPath -DestinationPath 'C:\ArcBox\ndp48.exe' -FileSource Host -CreateFullPath -Force -ErrorAction Stop
        Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $process = Start-Process -FilePath 'C:\ArcBox\ndp48.exe' -ArgumentList '/q', '/norestart' -PassThru -ErrorAction Stop
            if (-not $process.WaitForExit(900000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                throw '.NET Framework 4.8 installation exceeded the 15-minute limit.'
            }
            $process.Refresh()
            if ($process.ExitCode -notin @(0, 3010)) { throw ".NET Framework 4.8 installation failed (exit code $($process.ExitCode))." }
        }
        Restart-VM -Name win16sql16 -Force -ErrorAction Stop
        Get-VM -Name win16sql16 | Wait-VM -For Heartbeat -Timeout 600 -ErrorAction Stop
        Wait-ArcBoxWindows2016Guest -Credential $Credential
    }
    Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $release = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release
        if ([int]$release -lt 528040) { throw '.NET Framework 4.8 is required before SQL and Arc setup.' }
        foreach ($path in @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')) {
            $null = New-ItemProperty -Path $path -Name SchUseStrongCrypto -Value 1 -PropertyType DWord -Force -ErrorAction Stop
            $null = New-ItemProperty -Path $path -Name SystemDefaultTlsVersions -Value 1 -PropertyType DWord -Force -ErrorAction Stop
        }
    }
}

function Set-ArcBoxWindows2016EvaluationActivation {
    param([Parameter(Mandatory)][pscredential]$Credential)

    Invoke-Command -VMName win16sql16 -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.BuildNumber -ne '14393' -or $os.Caption -notmatch 'Windows Server 2016 Datacenter Evaluation') {
            throw 'Evaluation activation is restricted to Windows Server 2016 Datacenter Evaluation.'
        }
        $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'"
        $license = @(Get-CimInstance SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
            Where-Object { $_.LicenseStatus -eq 1 -and $_.Description -like '*TIMEBASED_EVAL*' -and $_.GracePeriodRemaining -gt 0 })
        if ($license.Count -gt 0) { return }
        & cscript.exe //NoLogo "$env:windir\System32\slmgr.vbs" -ato | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Windows Server 2016 evaluation activation failed (exit code $LASTEXITCODE)." }
        $license = @(Get-CimInstance SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
            Where-Object { $_.LicenseStatus -eq 1 -and $_.Description -like '*TIMEBASED_EVAL*' -and $_.GracePeriodRemaining -gt 0 })
        if ($license.Count -eq 0) { throw 'Windows Server 2016 did not report an activated, unexpired evaluation license.' }
    }
}

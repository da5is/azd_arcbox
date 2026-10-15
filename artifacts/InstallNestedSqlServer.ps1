param(
    [Parameter(Mandatory)]
    [ValidateSet('2016', '2019', '2025')]
    [string]$SqlVersion,
    [ValidateSet('Developer', 'Evaluation')]
    [string]$InstallationMode = 'Developer'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$versions = @{
    '2016' = @{
        MajorVersion = 13
        IsoUrl = 'https://download.microsoft.com/download/f/9/8/f982347c-fee3-4b3e-a8dc-c95383aa3020/sql16_sp3_dlc/en-us/SQLServer2016SP3-FullSlipstream-x64-ENU-DEV.iso'
        EvaluationBootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=799011&clcid=0x409&culture=en-us&country=us'
        ServicePackUrl = 'https://download.microsoft.com/download/a/7/7/a77b5753-8fe7-4804-bfc5-591d9a626c98/SQLServer2016SP3-KB5003279-x64-ENU.exe'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2016.bak'
        DatabaseName = 'AdventureWorksLT2016'
    }
    '2019' = @{
        MajorVersion = 15
        BootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=866662&clcid=0x409&culture=en-us&country=us'
        EvaluationBootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=866664&clcid=0x409&culture=en-us&country=us'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2019.bak'
        DatabaseName = 'AdventureWorksLT2019'
    }
    '2025' = @{
        MajorVersion = 17
        BootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=2344711&clcid=0x409&culture=en-us&country=us'
        EvaluationBootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=2342429&clcid=0x409&culture=en-us&country=us'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2025.bak'
        DatabaseName = 'AdventureWorksLT2025'
    }
}
$version = $versions[$SqlVersion]
$installDirectory = Join-Path $Env:ProgramData "ArcBox\SQLServer$SqlVersion"
$null = New-Item -Path $installDirectory -ItemType Directory -Force

function Assert-SqlEdition {
    param([Parameter(Mandatory)][string]$Edition)

    if ($InstallationMode -eq 'Evaluation' -and $Edition -match '^(Standard|Enterprise) Edition\b') {
        Write-Output "SQL Server $SqlVersion has been manually converted to '$Edition'; Arc licensing remains separately configured."
        return
    }
    if ($Edition -notlike "*$InstallationMode*") {
        throw "SQL Server $SqlVersion expects $InstallationMode, found '$Edition'. Changing the deployment option does not convert an existing instance."
    }
}

function Save-SqlDownload {
    param([string]$Uri, [string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return
    }
    $partialPath = "$Path.partial"
    Write-Output "Downloading SQL Server $SqlVersion artifact to $Path."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partialPath -TimeoutSec 3600
        Move-Item -LiteralPath $partialPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }
    }
}

function Invoke-SqlSetupProcess {
    param([string]$FilePath, [string[]]$Arguments)

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(3600000)) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not stop timed-out SQL Server $SqlVersion installer tree (PID $($process.Id))."
        }
        throw "SQL Server $SqlVersion process '$FilePath' exceeded the 60-minute limit."
    }
    $process.Refresh()
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "SQL Server $SqlVersion process '$FilePath' failed with exit code $($process.ExitCode)."
    }
    if ($process.ExitCode -eq 3010) {
        $null = New-Item -Path (Join-Path $installDirectory 'RestartRequired') -ItemType File -Force
        Write-Warning "SQL Server $SqlVersion setup requires a guest restart before database provisioning."
    }
}

function Invoke-SqlServerSetup {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SqlVersionInfo
    )

    $mediaEdition = if ($InstallationMode -eq 'Developer') { 'Developer' } else { 'Evaluation' }
    $mediaDirectory = if ($mediaEdition -eq 'Developer') { $installDirectory } else { Join-Path $installDirectory 'Evaluation' }
    $null = New-Item -Path $mediaDirectory -ItemType Directory -Force
    $isoPath = Join-Path $mediaDirectory "SQLServer$SqlVersion.iso"
    if ($SqlVersion -eq '2016' -and $InstallationMode -eq 'Developer') {
        Save-SqlDownload -Uri $SqlVersionInfo.IsoUrl -Path $isoPath
    } elseif (-not (Test-Path $isoPath)) {
        $bootstrapperName = if ($mediaEdition -eq 'Developer') { "SQLServer$SqlVersion-SSEI-Dev.exe" } else { "SQLServer$SqlVersion-SSEI-Eval.exe" }
        $bootstrapper = Join-Path $mediaDirectory $bootstrapperName
        $bootstrapperUrl = if ($mediaEdition -eq 'Developer') { $SqlVersionInfo.BootstrapperUrl } else { $SqlVersionInfo.EvaluationBootstrapperUrl }
        Save-SqlDownload -Uri $bootstrapperUrl -Path $bootstrapper

        $downloadArguments = @(
            '/Action=Download'
            '/MediaType=ISO'
            "/MediaPath=`"$mediaDirectory`""
            '/Quiet'
            '/Language=en-US'
        )
        Invoke-SqlSetupProcess -FilePath $bootstrapper -Arguments $downloadArguments

        $downloadedIso = Get-ChildItem -Path $mediaDirectory -Filter '*.iso' | Select-Object -First 1
        if ($null -eq $downloadedIso) {
            throw "The SQL Server $SqlVersion download tool completed without creating an ISO."
        }
        if ($downloadedIso.FullName -ne $isoPath) {
            Move-Item -Path $downloadedIso.FullName -Destination $isoPath -Force
        }
    }

    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
    try {
        $volume = $diskImage | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
        if ($null -eq $volume) {
            throw "Couldn't find a drive for the SQL Server $SqlVersion installation ISO."
        }

        $setupPath = "$($volume.DriveLetter):\setup.exe"
        if (-not (Test-Path $setupPath)) {
            throw "SQL Server $SqlVersion setup.exe wasn't found on the mounted ISO."
        }

        $configurationPath = Join-Path $installDirectory 'ConfigurationFile.ini'
        @'
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE
INSTANCENAME="MSSQLSERVER"
INSTANCEID="MSSQLSERVER"
QUIET="True"
IACCEPTSQLSERVERLICENSETERMS="True"
SQLSYSADMINACCOUNTS="BUILTIN\Administrators"
TCPENABLED="1"
FILESTREAMLEVEL="2"
FILESTREAMSHARENAME="MSSQLSERVER"
'@ | Set-Content -Path $configurationPath -Encoding ASCII

        $setupArguments = @(
            '/Q'
            "/ConfigurationFile=`"$configurationPath`""
            '/IACCEPTSQLSERVERLICENSETERMS'
        )
        if ($SqlVersion -eq '2016' -and $mediaEdition -eq 'Evaluation') {
            # Evaluation media can be SP2; integrate SP3 rather than losing patch-level coverage.
            $updateDirectory = Join-Path $mediaDirectory 'Updates'
            $null = New-Item -Path $updateDirectory -ItemType Directory -Force
            Save-SqlDownload -Uri $SqlVersionInfo.ServicePackUrl -Path (Join-Path $updateDirectory 'SQLServer2016SP3-KB5003279-x64-ENU.exe')
            $setupArguments += '/UpdateEnabled=True', "/UpdateSource=`"$updateDirectory`""
        }
        Invoke-SqlSetupProcess -FilePath $setupPath -Arguments $setupArguments
    } finally {
        Dismount-DiskImage -ImagePath $isoPath
    }
}

$sqlService = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if ($null -eq $sqlService) {
    Write-Output "Installing SQL Server $SqlVersion (mode: $InstallationMode)."
    Invoke-SqlServerSetup -SqlVersionInfo $version
} else {
    Write-Output "SQL Server service already exists; verifying SQL Server $SqlVersion."
}

if (Test-Path (Join-Path $installDirectory 'RestartRequired')) {
    Write-Output "Returning to the Hyper-V host for SQL Server $SqlVersion guest restart."
    return
}

$deadline = (Get-Date).AddMinutes(10)
do {
    $sqlService = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    if ($null -ne $sqlService -and $sqlService.Status -eq 'Running') {
        break
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)

if ($null -eq $sqlService -or $sqlService.Status -ne 'Running') {
    throw "The SQL Server $SqlVersion Database Engine service didn't start."
}

$moduleJob = Start-Job -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module -Name SqlServer -AllowClobber -Force -Scope AllUsers
}
try {
    if (-not (Wait-Job -Job $moduleJob -Timeout 900)) {
        throw 'SQL PowerShell module installation exceeded the 15-minute limit.'
    }
    Receive-Job -Job $moduleJob -ErrorAction Stop
    if ($moduleJob.State -ne 'Completed') {
        throw "SQL PowerShell module installation ended in state '$($moduleJob.State)'."
    }
} finally {
    if ($moduleJob.State -eq 'Running') { Stop-Job -Job $moduleJob }
    Remove-Job -Job $moduleJob -Force
}
Import-Module SqlServer -Force
$PSDefaultParameterValues['Invoke-Sqlcmd:AbortOnError'] = $true

$serverInfo = Invoke-Sqlcmd -ServerInstance '.' -Query @'
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS ProductLevel,
    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS DataPath,
    CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS LogPath,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS BackupPath;
'@ -TrustServerCertificate

if ([int]$serverInfo.MajorVersion -ne $version.MajorVersion) {
    throw "Expected SQL Server $SqlVersion (major version $($version.MajorVersion)), found major version $($serverInfo.MajorVersion)."
}
Assert-SqlEdition -Edition $serverInfo.Edition
if ($SqlVersion -eq '2016' -and $serverInfo.ProductLevel -ne 'SP3') {
    throw "SQL Server 2016 requires SP3, found '$($serverInfo.ProductLevel)'. Apply SP3 before continuing."
}

$dataPath = $serverInfo.DataPath
if ([string]::IsNullOrWhiteSpace($dataPath)) {
    $dataPath = "C:\Program Files\Microsoft SQL Server\MSSQL$($version.MajorVersion).MSSQLSERVER\MSSQL\DATA"
}
$logPath = $serverInfo.LogPath
if ([string]::IsNullOrWhiteSpace($logPath)) {
    $logPath = $dataPath
}
$backupPath = $serverInfo.BackupPath
if ([string]::IsNullOrWhiteSpace($backupPath)) {
    $backupPath = "C:\Program Files\Microsoft SQL Server\MSSQL$($version.MajorVersion).MSSQLSERVER\MSSQL\Backup"
}
$null = New-Item -Path $backupPath -ItemType Directory -Force

$firewallRule = Get-NetFirewallRule -DisplayName 'Allow SQL Server TCP 1433' -ErrorAction SilentlyContinue
if ($null -eq $firewallRule) {
    New-NetFirewallRule -DisplayName 'Allow SQL Server TCP 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
}

Invoke-Sqlcmd -ServerInstance '.' -Query "EXEC sys.sp_configure N'filestream_access_level', 2; RECONFIGURE;" -TrustServerCertificate
Restart-Service -Name MSSQLSERVER -Force
(Get-Service -Name MSSQLSERVER).WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

$backupPath = Join-Path $backupPath "$($version.DatabaseName).bak"
Save-SqlDownload -Uri $version.BackupUrl -Path $backupPath

$databaseExists = Invoke-Sqlcmd -ServerInstance '.' -Query "SELECT ISNULL(DB_ID(N'$($version.DatabaseName)'), 0) AS DatabaseId;" -TrustServerCertificate
if ([int]$databaseExists.DatabaseId -eq 0) {
    $fileList = @(Invoke-Sqlcmd -ServerInstance '.' -Query "RESTORE FILELISTONLY FROM DISK = N'$backupPath';" -TrustServerCertificate)
    if ($fileList.Count -eq 0) {
        throw "The AdventureWorks backup for SQL Server $SqlVersion contains no database files."
    }

    $moveClauses = [System.Collections.Generic.List[string]]::new()
    $dataFileIndex = 0
    $logFileIndex = 0
    foreach ($file in $fileList) {
        $logicalName = ([string]$file.LogicalName).Replace("'", "''")
        switch ($file.Type) {
            'D' {
                $dataFileIndex++
                $extension = if ($dataFileIndex -eq 1) { 'mdf' } else { 'ndf' }
                $fileName = "$($version.DatabaseName)_data$dataFileIndex.$extension"
            }
            'L' {
                $logFileIndex++
                $fileName = "$($version.DatabaseName)_log$logFileIndex.ldf"
            }
            default {
                throw "Unsupported file type '$($file.Type)' in the AdventureWorks backup."
            }
        }
        $destination = if ($file.Type -eq 'L') { Join-Path $logPath $fileName } else { Join-Path $dataPath $fileName }
        $moveClauses.Add("MOVE N'$logicalName' TO N'$destination'")
    }

    $restoreQuery = "RESTORE DATABASE [$($version.DatabaseName)] FROM DISK = N'$backupPath' WITH $($moveClauses -join ', '), RECOVERY, STATS=5;"
    Invoke-Sqlcmd -ServerInstance '.' -Query $restoreQuery -QueryTimeout 1800 -TrustServerCertificate
}

$sampleRecoveryQuery = "ALTER DATABASE [$($version.DatabaseName)] SET RECOVERY FULL;"
Invoke-Sqlcmd -ServerInstance '.' -Query $sampleRecoveryQuery -TrustServerCertificate

$archiveDataPath = Join-Path $dataPath 'ArchiveDB.mdf'
$archiveLogPath = Join-Path $logPath 'ArchiveDB_log.ldf'
$archiveFileStreamPath = Join-Path $dataPath 'ArchiveDB_FileStream'
$archiveDatabaseQuery = @"
IF DB_ID(N'ArchiveDB') IS NULL
BEGIN
    CREATE DATABASE [ArchiveDB]
    ON PRIMARY (NAME = N'Arch1', FILENAME = N'$archiveDataPath'),
    FILEGROUP [FileStreamGroup1] CONTAINS FILESTREAM
        (NAME = N'Arch3', FILENAME = N'$archiveFileStreamPath')
    LOG ON (NAME = N'Archlog1', FILENAME = N'$archiveLogPath');
END;
GO
IF OBJECT_ID(N'ArchiveDB.dbo.Records', N'U') IS NULL
BEGIN
    CREATE TABLE [ArchiveDB].[dbo].[Records]
    (
        [Id] uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE,
        [SerialNumber] int UNIQUE,
        [Chart] varbinary(max) FILESTREAM NULL
    );
END;
GO
ALTER DATABASE [ArchiveDB] SET RECOVERY FULL;
"@
Invoke-Sqlcmd -ServerInstance '.' -Query $archiveDatabaseQuery -TrustServerCertificate

$verification = Invoke-Sqlcmd -ServerInstance '.' -Query @"
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    ISNULL(DB_ID(N'$($version.DatabaseName)'), 0) AS AdventureWorksDatabaseId,
    ISNULL(DB_ID(N'ArchiveDB'), 0) AS ArchiveDatabaseId;
"@ -TrustServerCertificate

if ([int]$verification.AdventureWorksDatabaseId -le 0 -or [int]$verification.ArchiveDatabaseId -le 0) {
    throw "SQL Server $SqlVersion installation completed without both sample databases."
}

Write-Output "SQL Server $SqlVersion ($($serverInfo.Edition)) is running with $($version.DatabaseName) and ArchiveDB. Edition conversion, Software Assurance licensing, and ESU enrollment remain manual."

param(
    [Parameter(Mandatory)]
    [ValidateSet('2016', '2019', '2025')]
    [string]$SqlVersion
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$versions = @{
    '2016' = @{
        MajorVersion = 13
        IsoUrl = 'https://download.microsoft.com/download/f/9/8/f982347c-fee3-4b3e-a8dc-c95383aa3020/sql16_sp3_dlc/en-us/SQLServer2016SP3-FullSlipstream-x64-ENU-DEV.iso'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2016.bak'
        DatabaseName = 'AdventureWorksLT2016'
    }
    '2019' = @{
        MajorVersion = 15
        BootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=866662&clcid=0x409&culture=en-us&country=us'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2019.bak'
        DatabaseName = 'AdventureWorksLT2019'
    }
    '2025' = @{
        MajorVersion = 17
        BootstrapperUrl = 'https://go.microsoft.com/fwlink/?linkid=2344711&clcid=0x409&culture=en-us&country=us'
        BackupUrl = 'https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2025.bak'
        DatabaseName = 'AdventureWorksLT2025'
    }
}
$version = $versions[$SqlVersion]
$installDirectory = Join-Path $Env:ProgramData "ArcBox\SQLServer$SqlVersion"
$null = New-Item -Path $installDirectory -ItemType Directory -Force

function Invoke-SqlServerSetup {
    param(
        [Parameter(Mandatory)]
        [hashtable]$SqlVersionInfo
    )

    $isoPath = Join-Path $installDirectory "SQLServer$SqlVersion.iso"
    if ($SqlVersion -eq '2016') {
        if (-not (Test-Path $isoPath)) {
            Invoke-WebRequest -UseBasicParsing -Uri $SqlVersionInfo.IsoUrl -OutFile $isoPath
        }
    } else {
        $bootstrapper = Join-Path $installDirectory "SQLServer$SqlVersion-SSEI-Dev.exe"
        if (-not (Test-Path $bootstrapper)) {
            Invoke-WebRequest -UseBasicParsing -Uri $SqlVersionInfo.BootstrapperUrl -OutFile $bootstrapper
        }

        $downloadArguments = @(
            '/Action=Download'
            '/MediaType=ISO'
            "/MediaPath=$installDirectory"
            '/Quiet'
            '/Language=en-US'
        )
        $download = Start-Process -FilePath $bootstrapper -ArgumentList $downloadArguments -Wait -PassThru
        if ($download.ExitCode -ne 0) {
            throw "SQL Server $SqlVersion media download failed with exit code $($download.ExitCode)."
        }

        $downloadedIso = Get-ChildItem -Path $installDirectory -Filter '*.iso' | Select-Object -First 1
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
            "/ConfigurationFile=$configurationPath"
            '/IACCEPTSQLSERVERLICENSETERMS'
        )
        $setup = Start-Process -FilePath $setupPath -ArgumentList $setupArguments -Wait -PassThru
        if ($setup.ExitCode -notin @(0, 3010)) {
            throw "SQL Server $SqlVersion setup failed with exit code $($setup.ExitCode)."
        }
    } finally {
        Dismount-DiskImage -ImagePath $isoPath
        Remove-Item -Path $isoPath -Force -ErrorAction SilentlyContinue
    }
}

$sqlService = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if ($null -eq $sqlService) {
    Write-Output "Installing SQL Server $SqlVersion Developer Edition."
    Invoke-SqlServerSetup -SqlVersionInfo $version
} else {
    Write-Output "SQL Server service already exists; verifying SQL Server $SqlVersion."
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

Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name SqlServer -AllowClobber -Force -Scope AllUsers
Import-Module SqlServer -Force

$serverInfo = Invoke-Sqlcmd -ServerInstance '.' -Query @'
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS DataPath,
    CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS LogPath,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS BackupPath;
'@ -TrustServerCertificate

if ([int]$serverInfo.MajorVersion -ne $version.MajorVersion) {
    throw "Expected SQL Server $SqlVersion (major version $($version.MajorVersion)), found major version $($serverInfo.MajorVersion)."
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

$backupPath = Join-Path $backupPath "$($version.DatabaseName).bak"
if (-not (Test-Path $backupPath)) {
    Invoke-WebRequest -UseBasicParsing -Uri $version.BackupUrl -OutFile $backupPath
}

$databaseExists = Invoke-Sqlcmd -ServerInstance '.' -Query "SELECT DB_ID(N'$($version.DatabaseName)') AS DatabaseId;" -TrustServerCertificate
if ($null -eq $databaseExists.DatabaseId) {
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
    Invoke-Sqlcmd -ServerInstance '.' -Query $restoreQuery -QueryTimeout 0 -TrustServerCertificate
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
IF OBJECT_ID(N'ArchiveDB.dbo.Records', N'U') IS NULL
BEGIN
    CREATE TABLE [ArchiveDB].[dbo].[Records]
    (
        [Id] uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE,
        [SerialNumber] int UNIQUE,
        [Chart] varbinary(max) FILESTREAM NULL
    );
END;
ALTER DATABASE [ArchiveDB] SET RECOVERY FULL;
"@
Invoke-Sqlcmd -ServerInstance '.' -Query $archiveDatabaseQuery -TrustServerCertificate

$verification = Invoke-Sqlcmd -ServerInstance '.' -Query @"
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    DB_ID(N'$($version.DatabaseName)') AS AdventureWorksDatabaseId,
    DB_ID(N'ArchiveDB') AS ArchiveDatabaseId;
"@ -TrustServerCertificate

if ($null -eq $verification.AdventureWorksDatabaseId -or $null -eq $verification.ArchiveDatabaseId) {
    throw "SQL Server $SqlVersion installation completed without both sample databases."
}

Write-Output "SQL Server $SqlVersion is running with $($version.DatabaseName) and ArchiveDB."

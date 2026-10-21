$ErrorActionPreference = 'Stop'

$Env:ArcBoxDir = 'C:\ArcBox'
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$tenantId = $env:tenantId
$subscriptionId = $env:subscriptionId
$resourceGroup = $env:resourceGroup

function Install-ArcBoxBgInfo {
    $toolsDirectory = Join-Path $env:ArcBoxDir 'Tools'
    $null = New-Item -Path $toolsDirectory -ItemType Directory -Force -ErrorAction Stop
    $stagingDirectory = Join-Path $toolsDirectory ("BGInfo-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDirectory -ItemType Directory -ErrorAction Stop
    try {
        $archive = Join-Path $stagingDirectory 'BGInfo.zip'
        Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/BGInfo.zip' -OutFile $archive -TimeoutSec 300 -MaximumRetryCount 2 -RetryIntervalSec 5 -ErrorAction Stop
        Expand-Archive -LiteralPath $archive -DestinationPath $stagingDirectory -ErrorAction Stop
        $executable = Join-Path $stagingDirectory 'Bginfo64.exe'
        $signature = Get-AuthenticodeSignature -LiteralPath $executable -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw 'BGInfo executable does not have a valid Microsoft Corporation signature.'
        }
        Move-Item -LiteralPath $executable -Destination (Join-Path $toolsDirectory 'Bginfo64.exe') -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-ArcBoxWinGetConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    winget configure --file $Path --accept-configuration-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet configuration '$Path' failed (exit code $LASTEXITCODE). Inspect the WinGet provisioning log before retrying."
    }
}

$logFilePath = Join-Path -Path $Env:ArcBoxLogsDir -ChildPath ('WinGet-provisioning-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.log')

Start-Transcript -Path $logFilePath -Force -ErrorAction SilentlyContinue

try {
$DeploymentProgressString = "Installing WinGet packages..."

Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId

$tags = Get-AzResourceGroup -Name $resourceGroup | Select-Object -ExpandProperty Tags

if ($null -ne $tags) {
    $tags["DeploymentProgress"] = $DeploymentProgressString
} else {
    $tags = @{"DeploymentProgress" = $DeploymentProgressString}
}

$null = Set-AzResourceGroup -ResourceGroupName $resourceGroup -Tag $tags
$null = Set-AzResource -ResourceName $env:computername -ResourceGroupName $resourceGroup -ResourceType "microsoft.compute/virtualmachines" -Tag $tags -Force

# Install WinGet PowerShell modules
Install-PSResource -Name Microsoft.WinGet.Client -Scope AllUsers -Quiet -AcceptLicense -TrustRepository
Install-PSResource -Name Microsoft.WinGet.DSC -Scope AllUsers -Quiet -AcceptLicense -TrustRepository

# Install DSC resources required for ArcBox
Install-PSResource -Name DSCR_Font -Scope AllUsers -Quiet -AcceptLicense -TrustRepository
Install-PSResource -Name HyperVDsc -Scope AllUsers -Quiet -AcceptLicense -TrustRepository -Prerelease
Install-PSResource -Name NetworkingDsc -Scope AllUsers -Quiet -AcceptLicense -TrustRepository

# Update WinGet package manager to the latest version (running twice due to a known issue regarding WinAppSDK)
Repair-WinGetPackageManager -AllUsers -Force -Latest -Verbose
Repair-WinGetPackageManager -AllUsers -Force -Latest -Verbose

# Apply WinGet Configuration files
Install-ArcBoxBgInfo
Invoke-ArcBoxWinGetConfiguration -Path C:\ArcBox\DSC\common.dsc.yml

switch ($env:flavor) {
    'DevOps' { Invoke-ArcBoxWinGetConfiguration -Path C:\ArcBox\DSC\devops.dsc.yml }
    'DataOps' { Invoke-ArcBoxWinGetConfiguration -Path C:\ArcBox\DSC\dataops.dsc.yml }
    'ITPro' { Invoke-ArcBoxWinGetConfiguration -Path C:\ArcBox\DSC\itpro.dsc.yml }
}

# Start remaining logon scripts
Get-ScheduledTask *LogonScript* | Start-ScheduledTask

#Cleanup
Unregister-ScheduledTask -TaskName 'WinGetLogonScript' -Confirm:$false
} catch {
    $setupError = $_
    try {
        $tags = Get-AzResourceGroup -Name $resourceGroup -ErrorAction Stop | Select-Object -ExpandProperty Tags
        if ($null -eq $tags) { $tags = @{} }
        $tags['DeploymentProgress'] = 'Failed'
        $tags['DeploymentStatus'] = 'WinGet setup failed. Inspect C:\ArcBox\Logs\WinGet-provisioning-*.log.'
        $null = Set-AzResourceGroup -ResourceGroupName $resourceGroup -Tag $tags -ErrorAction Stop
    } catch {
        Write-Warning "Could not publish WinGet setup failure: $($_.Exception.Message)"
    }
    throw $setupError
} finally {
    Stop-Transcript -ErrorAction Continue
}
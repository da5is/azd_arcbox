#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.6.0' }

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $source = Get-Content (Join-Path $root 'artifacts\WinGet.ps1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    foreach ($name in @('Install-ArcBoxBgInfo', 'Invoke-ArcBoxWinGetConfiguration')) {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function winget { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) throw 'Unexpected WinGet call.' }
    function Get-AzResourceGroup { param($Name) throw 'Unexpected Azure read.' }
    function Set-AzResourceGroup { param($ResourceGroupName, $Tag) throw 'Unexpected Azure update.' }
    function Set-AzResource { param($ResourceName, $ResourceGroupName, $ResourceType, $Tag, [switch]$Force) throw 'Unexpected Azure update.' }
    function Connect-AzAccount { param([switch]$Identity, $Tenant, $Subscription) throw 'Unexpected Azure login.' }
    function Install-PSResource { param($Name, $Scope, [switch]$Quiet, [switch]$AcceptLicense, [switch]$TrustRepository, [switch]$Prerelease) throw 'Unexpected module install.' }
    function Repair-WinGetPackageManager { param([switch]$AllUsers, [switch]$Force, [switch]$Latest) throw 'Unexpected WinGet repair.' }
    function Get-ScheduledTask { param($TaskName) throw 'Unexpected task read.' }
    function Start-ScheduledTask { param([Parameter(ValueFromPipeline)]$InputObject) throw 'Unexpected task start.' }
    function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) throw 'Unexpected task removal.' }
}

Describe 'Verified BGInfo installation' {
    BeforeEach {
        $savedDirectory = $env:ArcBoxDir
        $env:ArcBoxDir = $TestDrive
        Mock winget { throw 'BGInfo must not use the stale WinGet manifest.' }
        Mock Invoke-WebRequest {
            $Uri | Should -Be 'https://download.sysinternals.com/files/BGInfo.zip'
            $MaximumRetryCount | Should -Be 2
            Set-Content -LiteralPath $OutFile -Value 'synthetic-archive'
        }
        Mock Expand-Archive {
            Set-Content -LiteralPath (Join-Path $DestinationPath 'Bginfo64.exe') -Value 'synthetic-executable'
        }
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } } }
    }
    AfterEach {
        $env:ArcBoxDir = $savedDirectory
        if (Test-Path (Join-Path $TestDrive 'Tools')) {
            Remove-Item -LiteralPath (Join-Path $TestDrive 'Tools') -Recurse -Force
        }
    }
    It 'installs only the Microsoft-signed x64 executable at the stable runtime path' {
        Install-ArcBoxBgInfo
        Get-Content (Join-Path $TestDrive 'Tools\Bginfo64.exe') | Should -Be 'synthetic-executable'
        @(Get-ChildItem (Join-Path $TestDrive 'Tools')).Count | Should -Be 1
        Should -Invoke Get-AuthenticodeSignature -Exactly -Times 1 -ParameterFilter { $LiteralPath -like '*Bginfo64.exe' }
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter { $ConnectionTimeoutSeconds -eq 300 -or $TimeoutSec -eq 300 }
        Should -Invoke winget -Times 0
    }
    It 'rejects a signature with status <Status>' -ForEach @(
        @{ Status = 'HashMismatch' }, @{ Status = 'NotSigned' }, @{ Status = 'NotTrusted' }
    ) {
        Mock Get-AuthenticodeSignature { @{ Status = $Status; SignerCertificate = @{ Subject = 'O=Microsoft Corporation' } } }
        { Install-ArcBoxBgInfo } | Should -Throw '*valid Microsoft Corporation signature*'
        Test-Path (Join-Path $TestDrive 'Tools\Bginfo64.exe') | Should -BeFalse
        @(Get-ChildItem (Join-Path $TestDrive 'Tools')).Count | Should -Be 0
    }
    It 'rejects an otherwise valid signature from a different publisher' {
        Mock Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Other Publisher, O=Other Publisher, C=US' } } }
        { Install-ArcBoxBgInfo } | Should -Throw '*valid Microsoft Corporation signature*'
    }
    It 'surfaces download failure and removes staging files without replacing a prior installation' {
        $null = New-Item -Path (Join-Path $TestDrive 'Tools') -ItemType Directory
        Set-Content (Join-Path $TestDrive 'Tools\Bginfo64.exe') 'original'
        Mock Invoke-WebRequest { throw 'Download failed.' }
        { Install-ArcBoxBgInfo } | Should -Throw '*Download failed*'
        Get-Content (Join-Path $TestDrive 'Tools\Bginfo64.exe') | Should -Be 'original'
        @(Get-ChildItem (Join-Path $TestDrive 'Tools')).Count | Should -Be 1
    }
    It 'does not depend on the stale rolling-download WinGet manifest or bypass hash checks' {
        (Get-Content (Join-Path $root 'artifacts\dsc\common.dsc.yml') -Raw) | Should -Not -Match 'Microsoft.Sysinternals.BGInfo'
        $source | Should -Not -Match 'ignore-security-hash|ignore.*hash'
    }
}

Describe 'WinGet configuration exit handling' {
    It 'rejects a nonzero native configuration exit code' {
        Mock winget { $global:LASTEXITCODE = -1978335215 }
        { Invoke-ArcBoxWinGetConfiguration -Path 'C:\ArcBox\DSC\common.dsc.yml' } | Should -Throw '*common.dsc.yml*exit code -1978335215*'
    }
    It 'accepts a successful configuration' {
        Mock winget { $global:LASTEXITCODE = 0 }
        Invoke-ArcBoxWinGetConfiguration -Path 'C:\ArcBox\DSC\common.dsc.yml'
        Should -Invoke winget -Exactly -Times 1 -ParameterFilter {
            $Arguments -contains 'configure' -and $Arguments -contains '--disable-interactivity'
        }
    }
}

Describe 'WinGet prerequisite failure publication and task ordering' {
    BeforeAll {
        $setup = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
        $setupScript = [scriptblock]::Create($setup.Extent.Text)
    }
    BeforeEach {
        $savedFlavor = $env:flavor
        $env:flavor = 'ITPro'
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:published = $null
        Mock Connect-AzAccount {}
        Mock Get-AzResourceGroup { @{ Tags = @{ Ownership = 'preserved' } } }
        Mock Set-AzResourceGroup { $script:published = $Tag.Clone() }
        Mock Set-AzResource {}
        Mock Install-PSResource {}
        Mock Repair-WinGetPackageManager {}
        Mock Install-ArcBoxBgInfo { $script:calls.Add('BGInfo') }
        Mock Invoke-ArcBoxWinGetConfiguration { $script:calls.Add($Path) }
        Mock Get-ScheduledTask { 'setup-task' }
        Mock Start-ScheduledTask { $script:calls.Add('Start') }
        Mock Unregister-ScheduledTask {}
        Mock Stop-Transcript {}
    }
    AfterEach { $env:flavor = $savedFlavor }
    It 'checks common and flavor configuration before starting the setup worker' {
        & $setupScript
        $script:calls | Should -Be @('BGInfo', 'C:\ArcBox\DSC\common.dsc.yml', 'C:\ArcBox\DSC\itpro.dsc.yml', 'Start')
        Should -Invoke Unregister-ScheduledTask -Exactly -Times 1
    }
    It 'publishes failure and retains the task if the common configuration fails' {
        Mock Invoke-ArcBoxWinGetConfiguration { throw 'Common configuration failed.' }
        { & $setupScript } | Should -Throw '*Common configuration failed*'
        Should -Invoke Start-ScheduledTask -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
        $script:published.DeploymentProgress | Should -Be 'Failed'
        $script:published.DeploymentStatus | Should -Match 'WinGet setup failed'
        $script:published.Ownership | Should -Be 'preserved'
    }
    It 'does not start the worker if the flavor configuration or BGInfo installation fails' -ForEach @(
        @{ Failure = 'Flavor' }, @{ Failure = 'BGInfo' }
    ) {
        if ($Failure -eq 'BGInfo') {
            Mock Install-ArcBoxBgInfo { throw 'BGInfo failed.' }
        } else {
            Mock Invoke-ArcBoxWinGetConfiguration { throw 'Flavor configuration failed.' } -ParameterFilter { $Path -like '*itpro.dsc.yml' }
        }
        { & $setupScript } | Should -Throw '*failed*'
        Should -Invoke Start-ScheduledTask -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
        $script:published.DeploymentProgress | Should -Be 'Failed'
    }
}

Describe 'Deployment results wallpaper executable' {
    BeforeAll {
        $runner = Get-Content (Join-Path $root 'artifacts\tests\Invoke-Test.ps1') -Raw
        $start = $runner.IndexOf('$bgInfoPath = ')
        $end = $runner.IndexOf('$DeploymentStatusPath = ', $start)
        $wallpaperScript = [scriptblock]::Create($runner.Substring($start, $end - $start))
    }
    BeforeEach {
        $savedArcBoxDir = $env:ArcBoxDir
        $env:ArcBoxDir = 'C:\ArcBox'
        Mock Test-Path { $true }
        Mock Start-Process { @{ ExitCode = 0 } }
    }
    AfterEach { $env:ArcBoxDir = $savedArcBoxDir }
    It 'uses the explicitly installed executable and waits for native success' {
        & $wallpaperScript
        Should -Invoke Start-Process -Exactly -Times 1 -ParameterFilter {
            $FilePath -like '*Tools\Bginfo64.exe' -and $Wait -and $PassThru
        }
    }
    It 'surfaces a missing prerequisite without relying on the process PATH' {
        Mock Test-Path { $false }
        { & $wallpaperScript } | Should -Throw '*BGInfo is missing*'
        Should -Invoke Start-Process -Times 0
    }
    It 'rejects a failed wallpaper update' {
        Mock Start-Process { @{ ExitCode = 5 } }
        { & $wallpaperScript } | Should -Throw '*BGInfo failed*exit code 5*'
    }
}

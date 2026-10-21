#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.6.0' }

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'common.ps1')

    function az {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        throw 'Unmocked Azure CLI invocation.'
    }
    function azd {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        throw 'Unmocked azd invocation.'
    }
    function ssh-keygen {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        throw 'Unmocked SSH key generation.'
    }

    $environmentNames = @(
        'AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'AZURE_RESOURCE_GROUP',
        'JS_ARCBOX_FLAVOR', 'JS_ARCBOX_TIMEOUT_MINUTES', 'JS_SSH_PUBLIC_KEY', 'JS_CUSTOM_LOCATION_RP_ID',
        'AZD_NO_PROMPT', 'JS_ARCBOX_PASSWORD', 'JS_NESTED_SQL_MODE',
        'JS_GITHUB_ACCOUNT', 'JS_GITHUB_BRANCH'
    )
    function Initialize-TestEnvironment {
        $script:savedEnvironment = @{}
        foreach ($name in $environmentNames) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $env:AZURE_ENV_NAME = 'arcbox-test'
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000001'
        $env:AZURE_LOCATION = 'eastus2'
        $env:AZURE_RESOURCE_GROUP = 'arcbox-test-rg'
        $env:JS_ARCBOX_PASSWORD = 'ArcBoxTestPassword1!'
        $env:JS_NESTED_SQL_MODE = 'Developer'
        $script:originalExitCode = $global:LASTEXITCODE
    }

    function Restore-TestEnvironment {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:originalExitCode
    }
}

Describe 'ArcBox CLI errors' {
    BeforeEach { Initialize-TestEnvironment }
    AfterEach { Restore-TestEnvironment }

    It 'does not return success-shaped output after an Azure CLI failure' {
        Mock az { $global:LASTEXITCODE = 9; 'unexpected output' }
        { Invoke-ArcBoxAz -Arguments @('group', 'show') } | Should -Throw '*exit code 9*'
    }

    It 'passes the selected subscription to every Azure CLI call' {
        Mock az { $global:LASTEXITCODE = 0; 'result' }
        Invoke-ArcBoxAz -Arguments @('account', 'show') | Should -Be 'result'
        Should -Invoke az -Exactly -Times 1 -ParameterFilter {
            $Arguments -contains '--subscription' -and $Arguments -contains $env:AZURE_SUBSCRIPTION_ID
        }
    }

    It 'surfaces failure to persist an environment setting' {
        Mock azd { $global:LASTEXITCODE = 2 }
        { Set-ArcBoxEnvironmentValue -Name JS_ARCBOX_FLAVOR -Value DevOps } | Should -Throw '*Unable to save*'
        $env:JS_ARCBOX_FLAVOR | Should -BeNullOrEmpty
    }
}

Describe 'ArcBox flavor selection' {
    BeforeEach {
        Initialize-TestEnvironment
        Mock Read-Host { throw 'Unexpected interactive prompt.' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    AfterEach { Restore-TestEnvironment }

    It 'selects <flavor> from <selection>' -ForEach @(
        @{ selection = '1'; flavor = 'ITPro' },
        @{ selection = '2'; flavor = 'DevOps' },
        @{ selection = '3'; flavor = 'DataOps' },
        @{ selection = 'ITPro'; flavor = 'ITPro' },
        @{ selection = 'devops'; flavor = 'DevOps' },
        @{ selection = ' DataOps '; flavor = 'DataOps' }
    ) {
        $script:selection = $selection
        Mock Read-Host { $script:selection }
        Select-ArcBoxFlavor -Interactive $true | Should -Be $flavor
        Should -Invoke Read-Host -Exactly -Times 1
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { $Object -like '*1. ITPro*' }
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { $Object -like '*2. DevOps*' }
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { $Object -like '*3. DataOps*' }
    }

    It 'reprompts after invalid input without silently choosing a default' {
        $script:promptCount = 0
        Mock Read-Host {
            $script:promptCount++
            if ($script:promptCount -eq 1) { 'Full' } else { '2' }
        }
        Select-ArcBoxFlavor -Interactive $true | Should -Be DevOps
        Should -Invoke Read-Host -Exactly -Times 2
        Should -Invoke Write-Warning -Exactly -Times 1
    }

    It 'cancels without choosing a flavor for <selection>' -ForEach @(
        @{ selection = '' }, @{ selection = 'q' }, @{ selection = $null }
    ) {
        $script:selection = $selection
        Mock Read-Host { $script:selection }
        { Select-ArcBoxFlavor -Interactive $true } | Should -Throw '*selection cancelled*'
        $env:JS_ARCBOX_FLAVOR | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Exactly -Times 1
    }

    It 'fails with actionable guidance when interactive input is unavailable' {
        { Select-ArcBoxFlavor -Interactive $false } | Should -Throw '*azd env set JS_ARCBOX_FLAVOR*'
        Should -Invoke Read-Host -Times 0
    }

    It 'honors an explicitly disabled prompt even with a terminal' {
        $env:AZD_NO_PROMPT = 'true'
        { Select-ArcBoxFlavor -Interactive $true } | Should -Throw '*interactive input is unavailable or disabled*'
        Should -Invoke Read-Host -Times 0
    }
}

Describe 'ArcBox SQL mode selection' {
    BeforeEach {
        Initialize-TestEnvironment
        Mock Read-Host { throw 'Unexpected interactive prompt.' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    AfterEach { Restore-TestEnvironment }

    It 'selects <mode> from <selection>' -ForEach @(
        @{ selection = '1'; mode = 'Developer' },
        @{ selection = 'dev'; mode = 'Developer' },
        @{ selection = 'Developer'; mode = 'Developer' },
        @{ selection = '2'; mode = 'Evaluation' },
        @{ selection = 'eval'; mode = 'Evaluation' },
        @{ selection = ' Evaluation '; mode = 'Evaluation' }
    ) {
        $script:selection = $selection
        Mock Read-Host { $script:selection }
        Select-ArcBoxSqlMode -Interactive $true | Should -Be $mode
        Should -Invoke Read-Host -Exactly -Times 1
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { $Object -like '*1. Developer*' }
        Should -Invoke Write-Host -Exactly -Times 1 -ParameterFilter { $Object -like '*2. Evaluation*' }
        Should -Invoke Write-Host -Exactly -Times 0 -ParameterFilter { $Object -like '*3.*' }
    }
    It 'reprompts for invalid SQL input <invalid> without defaulting to Developer' -ForEach @(
        @{ invalid = 'Enterprise' }, @{ invalid = '3' }, @{ invalid = 'byol' }
    ) {
        $script:promptCount = 0
        $script:invalidSelection = $invalid
        Mock Read-Host {
            $script:promptCount++
            if ($script:promptCount -eq 1) { $script:invalidSelection } else { 'eval' }
        }
        Select-ArcBoxSqlMode -Interactive $true | Should -Be Evaluation
        Should -Invoke Read-Host -Exactly -Times 2
        Should -Invoke Write-Warning -Exactly -Times 1
    }
    It 'cancels SQL selection for <selection>' -ForEach @(
        @{ selection = '' }, @{ selection = 'q' }, @{ selection = $null }
    ) {
        $script:selection = $selection
        Mock Read-Host { $script:selection }
        { Select-ArcBoxSqlMode -Interactive $true } | Should -Throw '*selection cancelled*'
        Should -Invoke Read-Host -Exactly -Times 1
    }
    It 'requires explicit SQL configuration without terminal input' {
        { Select-ArcBoxSqlMode -Interactive $false } | Should -Throw '*azd env set JS_NESTED_SQL_MODE*'
        Should -Invoke Read-Host -Times 0
    }
    It 'honors AZD_NO_PROMPT for SQL mode selection' {
        $env:AZD_NO_PROMPT = 'true'
        { Select-ArcBoxSqlMode -Interactive $true } | Should -Throw '*interactive input is unavailable or disabled*'
        Should -Invoke Read-Host -Times 0
    }
}

Describe 'ArcBox Evaluation artifact preflight' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
    }
    BeforeEach {
        Initialize-TestEnvironment
        $script:artifactRequests = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-WebRequest {
            $script:artifactRequests.Add($Uri)
            $artifactPath = ([uri]$Uri).AbsolutePath -replace '^.*?/artifacts/', 'artifacts/'
            [pscustomobject]@{ Content = [IO.File]::ReadAllText((Join-Path $arcboxRoot $artifactPath)) }
        }
    }
    AfterEach { Restore-TestEnvironment }

    It 'accepts matching published scripts and deployed checks' {
        Assert-ArcBoxSqlArtifacts
        $script:artifactRequests.Count | Should -Be 8
        $script:artifactRequests[0] | Should -Be 'https://raw.githubusercontent.com/da5is/azd_arcbox/main/artifacts/Bootstrap.ps1'
        Should -Invoke Invoke-WebRequest -Exactly -Times 8 -ParameterFilter { $TimeoutSec -eq 30 -and $ErrorAction -eq 'Stop' }
    }
    It 'uses the configured public account and branch' {
        $env:JS_GITHUB_ACCOUNT = 'test-owner'
        $env:JS_GITHUB_BRANCH = 'feature/sql-eval'
        Assert-ArcBoxSqlArtifacts
        $script:artifactRequests[0] | Should -Be 'https://raw.githubusercontent.com/test-owner/azd_arcbox/feature/sql-eval/artifacts/Bootstrap.ps1'
    }
    It 'ignores only Windows versus Unix line-ending differences' {
        Mock Invoke-WebRequest {
            $artifactPath = ([uri]$Uri).AbsolutePath -replace '^.*?/artifacts/', 'artifacts/'
            $source = [IO.File]::ReadAllText((Join-Path $arcboxRoot $artifactPath)).Replace("`r`n", "`n").Replace("`n", "`r`n")
            [pscustomobject]@{ Content = $source }
        }
        { Assert-ArcBoxSqlArtifacts } | Should -Not -Throw
    }
    It 'rejects stale <artifact> with actionable publishing guidance' -ForEach @(
        @{ artifact = 'Bootstrap.ps1' },
        @{ artifact = 'ArcServersLogonScript.ps1' },
        @{ artifact = 'InstallNestedSqlServer.ps1' },
        @{ artifact = 'InstallNestedSqlServerUbuntu.sh' },
        @{ artifact = 'installArcAgentUbuntu.sh' },
        @{ artifact = 'ArcBoxServerManagement.ps1' },
        @{ artifact = 'virtual_machines_itpro.dsc.yml' },
        @{ artifact = 'itpro.tests.ps1' }
    ) {
        $script:staleArtifact = $artifact
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = 'old Developer-only automation' } } -ParameterFilter {
            $Uri.AbsolutePath.EndsWith("/$script:staleArtifact")
        }
        { Assert-ArcBoxSqlArtifacts } | Should -Throw '*does not match this checkout*set JS_GITHUB_BRANCH*'
    }
    It 'does not ignore unreachable or unpublished artifact URLs' {
        Mock Invoke-WebRequest { throw '404 Not Found' }
        { Assert-ArcBoxSqlArtifacts } | Should -Throw '*Cannot verify Evaluation artifacts*404 Not Found*Publish*'
    }
}

Describe 'ArcBox shared password configuration' {
    BeforeEach {
        Initialize-TestEnvironment
        Mock Set-ArcBoxEnvironmentValue { Set-Item -Path "Env:$Name" -Value $Value }
    }
    AfterEach { Restore-TestEnvironment }

    It 'prompts securely, confirms, validates, and persists the shared password once' {
        $env:JS_ARCBOX_PASSWORD = $null
        $securePassword = ConvertTo-SecureString 'ArcBoxTestPassword1!' -AsPlainText -Force
        Mock Read-Host { $securePassword }
        Initialize-ArcBoxPassword -Interactive $true
        $env:JS_ARCBOX_PASSWORD | Should -Be 'ArcBoxTestPassword1!'
        Should -Invoke Read-Host -Exactly -Times 2 -ParameterFilter { $AsSecureString }
        Should -Invoke Set-ArcBoxEnvironmentValue -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'JS_ARCBOX_PASSWORD' -and $Value -eq 'ArcBoxTestPassword1!'
        }
    }

    It 'does not prompt again when the shared password is already configured' {
        Mock Read-Host { throw 'Unexpected password prompt.' }
        Initialize-ArcBoxPassword -Interactive $true
        Should -Invoke Read-Host -Times 0
    }

    It 'requires an explicitly configured password when prompts are unavailable' {
        $env:JS_ARCBOX_PASSWORD = $null
        { Initialize-ArcBoxPassword -Interactive $false } | Should -Throw '*No shared ArcBox password is configured*'
    }

    It 'rejects a password that does not meet the shared Windows password requirements' {
        $env:JS_ARCBOX_PASSWORD = 'too-short'
        { Initialize-ArcBoxPassword } | Should -Throw '*12-123 characters*'
    }

    It 'rejects password characters that cannot be safely substituted into the Bicep parameter file' {
        foreach ($password in @('ArcBoxTestPassword1"', 'ArcBoxTestPassword1\')) {
            $env:JS_ARCBOX_PASSWORD = $password
            { Initialize-ArcBoxPassword } | Should -Throw '*double quotes, and backslashes*'
        }
    }

    It 'rejects mismatched secure password entries without persisting either value' {
        $script:promptCount = 0
        Mock Read-Host {
            $script:promptCount++
            $value = if ($script:promptCount -eq 1) { 'ArcBoxTestPassword1!' } else { 'DifferentPassword1!' }
            ConvertTo-SecureString $value -AsPlainText -Force
        }
        $env:JS_ARCBOX_PASSWORD = $null
        { Initialize-ArcBoxPassword -Interactive $true } | Should -Throw '*did not match*'
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
}

Describe 'ArcBox shared password deployment wiring' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $parameters = Get-Content (Join-Path $arcboxRoot 'bicep\main.azd.parameters.json') -Raw -ErrorAction Stop
        $wrapper = Get-Content (Join-Path $arcboxRoot 'bicep\main.azd.bicep') -Raw -ErrorAction Stop
        $template = Get-Content (Join-Path $arcboxRoot 'bicep\main.bicep') -Raw -ErrorAction Stop
        $armTemplate = Get-Content (Join-Path $arcboxRoot 'ARM\azuredeploy.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $servers = Get-Content (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1') -Raw -ErrorAction Stop
        $sqlMi = Get-Content (Join-Path $arcboxRoot 'artifacts\DeploySQLMIADAuth.ps1') -Raw -ErrorAction Stop
    }
    It 'passes the prompted secret to both secure Bicep password parameters without generating a replacement' {
        $parameters | Should -Match '(?s)"windowsAdminPassword"\s*:\s*\{\s*"value"\s*:\s*"\$\{JS_ARCBOX_PASSWORD\}"'
        $parameters | Should -Match '(?s)"registryPassword"\s*:\s*\{\s*"value"\s*:\s*"\$\{JS_ARCBOX_PASSWORD\}"'
        $wrapper | Should -Match '@secure\(\)\s+@minLength\(12\)\s+@maxLength\(123\)\s+param windowsAdminPassword string'
        $wrapper | Should -Not -Match "type: 'generate'"
        $template | Should -Not -Match 'param (windowsAdminPassword|registryPassword) string\s*=\s*newGuid\(\)'
        $armTemplate.parameters.windowsAdminPassword.PSObject.Properties['defaultValue'] | Should -BeNullOrEmpty
        $armTemplate.parameters.registryPassword.PSObject.Properties['defaultValue'] | Should -BeNullOrEmpty
    }
    It 'uses the Key Vault password for nested guest credentials and the SQL Server connection' {
        $servers | Should -Match 'Get-AzKeyVaultSecret -VaultName .+ -Name ''windowsAdminPassword'''
        $servers | Should -Match 'Set-ArcBoxWindowsGuestPassword -VMName \$SQLvmName -Password \$nestedGuestPassword'
        $servers | Should -Match '\$login\.ChangePassword\(\$Password\)'
        $servers | Should -Match '\$username`:\$Password" \| sudo chpasswd'
        $sqlMi | Should -Match '"password": "\$AZDATA_PASSWORD"'
    }
}

Describe 'ArcBox SQL password rotation session' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $rotation = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            $node.ScriptBlock.Extent.Text -match '\$login\.ChangePassword'
        }, $true)
        if ($null -eq $rotation) { throw 'SQL password rotation script block not found.' }
        $rotatePassword = $rotation.ScriptBlock.GetScriptBlock()
    }
    BeforeEach {
        $script:sqlModuleLoaded = $false
        $script:login = [pscustomobject]@{ Password = $null }
        $script:login | Add-Member -MemberType ScriptMethod -Name ChangePassword -Value {
            param([string]$Value)
            $this.Password = $Value
        }
        Mock Import-Module { $script:sqlModuleLoaded = $true } -ParameterFilter { $Name -eq 'SqlServer' }
        Mock New-Object {
            if (-not $script:sqlModuleLoaded) { throw 'SMO is not loaded in this session.' }
            [pscustomobject]@{ Logins = @{ sa = $script:login } }
        } -ParameterFilter { $TypeName -like 'Microsoft.SqlServer.Management.Smo.Server*' }
    }
    It 'loads SMO in the password rotation session before constructing the server and changing the password' {
        & $rotatePassword 'ArcBoxTestPassword1!'
        $script:login.Password | Should -Be 'ArcBoxTestPassword1!'
        Should -Invoke Import-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'SqlServer' -and $Force -and $ErrorAction -eq 'Stop'
        }
    }
    It 'fails explicitly if the SqlServer module cannot be loaded' {
        Mock Import-Module { throw 'SqlServer module unavailable.' } -ParameterFilter { $Name -eq 'SqlServer' }
        { & $rotatePassword 'ArcBoxTestPassword1!' } | Should -Throw '*SqlServer module unavailable*'
        Should -Invoke New-Object -Times 0
        $script:login.Password | Should -BeNullOrEmpty
    }
    It 'fails explicitly when the sa login is missing' {
        Mock New-Object { [pscustomobject]@{ Logins = @{} } } -ParameterFilter {
            $TypeName -like 'Microsoft.SqlServer.Management.Smo.Server*'
        }
        { & $rotatePassword 'ArcBoxTestPassword1!' } | Should -Throw '*sa*login was not found*'
    }
}

Describe 'ArcBox prerequisites' {
    BeforeEach {
        Initialize-TestEnvironment
        $env:JS_ARCBOX_FLAVOR = 'ITPro'
        Mock Get-Command { [pscustomobject]@{ Name = $Name } }
        Mock Select-ArcBoxFlavor { throw 'Unexpected flavor selection.' }
        Mock Select-ArcBoxSqlMode { throw 'Unexpected SQL mode selection.' }
        Mock Assert-ArcBoxSqlArtifacts {}
        Mock Read-Host { throw 'Unexpected interactive prompt.' }
        Mock Set-ArcBoxEnvironmentValue { Set-Item -Path "Env:$Name" -Value $Value }
        Mock Invoke-ArcBoxAz {
            switch ($Arguments[0]) {
                'account' { '{"id":"00000000-0000-0000-0000-000000000001"}' }
                'group' { 'false' }
                'provider' {
                    if ($Arguments[1] -eq 'list') {
                        @(
                            'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault',
                            'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights',
                            'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData',
                            'Microsoft.HybridConnectivity', 'Microsoft.PolicyInsights', 'Microsoft.Kubernetes',
                            'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.ContainerService'
                        ) | ForEach-Object {
                            @{ namespace = $_; registrationState = 'Registered' }
                        } | ConvertTo-Json
                    }
                }
                'ad' { '["00000000-0000-0000-0000-000000000002"]' }
                default { throw "Unexpected mocked command: $($Arguments -join ' ')" }
            }
        }
        AfterEach { Restore-TestEnvironment }
    }

    It 'uses configured ITPro without prompting, generating SSH keys, or reading the directory' {
        Initialize-ArcBoxDeployment
        $env:JS_ARCBOX_FLAVOR | Should -Be ITPro
        Should -Invoke Select-ArcBoxFlavor -Times 0
        Should -Invoke Invoke-ArcBoxAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'ad' }
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0 -ParameterFilter { $Name -eq 'JS_SSH_PUBLIC_KEY' }
    }

    It 'persists selected <flavor> and skips the menu on subsequent runs' -ForEach @(
        @{ flavor = 'ITPro' }, @{ flavor = 'DevOps' }, @{ flavor = 'DataOps' }
    ) {
        $env:JS_ARCBOX_FLAVOR = $null
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        $env:JS_CUSTOM_LOCATION_RP_ID = '00000000-0000-0000-0000-000000000002'
        $script:selectedFlavor = $flavor
        Mock Select-ArcBoxFlavor { $script:selectedFlavor }
        Initialize-ArcBoxDeployment
        $env:JS_ARCBOX_FLAVOR | Should -Be $flavor
        Should -Invoke Set-ArcBoxEnvironmentValue -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'JS_ARCBOX_FLAVOR' -and $Value -eq $script:selectedFlavor
        }
        Initialize-ArcBoxDeployment
        Should -Invoke Select-ArcBoxFlavor -Exactly -Times 1
    }

    It 'stops before Azure operations or persistence if flavor selection fails' {
        $env:JS_ARCBOX_FLAVOR = $null
        Mock Select-ArcBoxFlavor { throw 'ArcBox flavor selection cancelled.' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*selection cancelled*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }

    It 'supports <flavor> with a supplied public key and object ID' -ForEach @(
        @{ flavor = 'ITPro' }, @{ flavor = 'DevOps' }, @{ flavor = 'DataOps' }
    ) {
        $env:JS_ARCBOX_FLAVOR = $flavor
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        $env:JS_CUSTOM_LOCATION_RP_ID = '00000000-0000-0000-0000-000000000002'
        Initialize-ArcBoxDeployment
        $env:JS_ARCBOX_FLAVOR | Should -Be $flavor
        Should -Invoke Select-ArcBoxFlavor -Times 0
        Should -Invoke Invoke-ArcBoxAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'ad' }
    }

    It 'allows an explicitly configured flavor when prompts are disabled' {
        $env:AZD_NO_PROMPT = 'true'
        Initialize-ArcBoxDeployment
        Should -Invoke Select-ArcBoxFlavor -Times 0
        Should -Invoke Read-Host -Times 0
    }

    It 'prompts for SQL mode after ITPro selection and persists it for subsequent runs' {
        $env:JS_ARCBOX_FLAVOR = $null
        $env:JS_NESTED_SQL_MODE = $null
        Mock Select-ArcBoxFlavor { 'ITPro' }
        Mock Select-ArcBoxSqlMode { 'Evaluation' }
        Initialize-ArcBoxDeployment
        $env:JS_NESTED_SQL_MODE | Should -Be Evaluation
        Should -Invoke Set-ArcBoxEnvironmentValue -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'JS_NESTED_SQL_MODE' -and $Value -eq 'Evaluation'
        }
        Initialize-ArcBoxDeployment
        Should -Invoke Select-ArcBoxFlavor -Exactly -Times 1
        Should -Invoke Select-ArcBoxSqlMode -Exactly -Times 1
    }
    It 'skips the SQL menu for configured <mode>' -ForEach @(
        @{ mode = 'Developer' }, @{ mode = 'Evaluation' }
    ) {
        $env:JS_NESTED_SQL_MODE = $mode
        $env:AZD_NO_PROMPT = 'true'
        Initialize-ArcBoxDeployment
        $env:JS_NESTED_SQL_MODE | Should -Be $mode
        Should -Invoke Select-ArcBoxSqlMode -Times 0
        Should -Invoke Read-Host -Times 0
        Should -Invoke Assert-ArcBoxSqlArtifacts -Exactly -Times $(if ($mode -eq 'Evaluation') { 1 } else { 0 })
    }
    It 'stops before Azure operations or persistence when Evaluation artifacts are stale' {
        $env:JS_NESTED_SQL_MODE = 'Evaluation'
        Mock Assert-ArcBoxSqlArtifacts { throw 'Evaluation artifact does not match this checkout.' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*does not match this checkout*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
    It 'skips SQL selection and persistence for <flavor>' -ForEach @(
        @{ flavor = 'DevOps' }, @{ flavor = 'DataOps' }
    ) {
        $env:JS_ARCBOX_FLAVOR = $flavor
        $env:JS_NESTED_SQL_MODE = $null
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        $env:JS_CUSTOM_LOCATION_RP_ID = '00000000-0000-0000-0000-000000000002'
        Initialize-ArcBoxDeployment
        Should -Invoke Select-ArcBoxSqlMode -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0 -ParameterFilter { $Name -eq 'JS_NESTED_SQL_MODE' }
    }
    It 'stops before Azure operations or persistence if SQL selection is cancelled' {
        $env:JS_NESTED_SQL_MODE = $null
        Mock Select-ArcBoxSqlMode { throw 'SQL installation mode selection cancelled.' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*selection cancelled*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
    It 'requires an explicit SQL mode for unattended ITPro deployment' {
        $env:JS_NESTED_SQL_MODE = $null
        $env:AZD_NO_PROMPT = 'true'
        Mock Select-ArcBoxSqlMode { throw "Run 'azd env set JS_NESTED_SQL_MODE <Developer|Evaluation>' before provisioning." }
        { Initialize-ArcBoxDeployment } | Should -Throw '*JS_NESTED_SQL_MODE*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
    It 'rejects an invalid configured SQL mode before Azure operations' {
        $env:JS_NESTED_SQL_MODE = 'PAYG'
        { Initialize-ArcBoxDeployment } | Should -Throw '*must be Developer or Evaluation*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
    It 'does not save a selected SQL mode when the resource group cannot be adopted' {
        $env:JS_NESTED_SQL_MODE = $null
        Mock Select-ArcBoxSqlMode { 'Evaluation' }
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz { '[]' } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*without an ArcBox azd deployment*'
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }
    It 'provides migration guidance for an environment with the removed BYOL mode' {
        $env:JS_NESTED_SQL_MODE = 'BYOL'
        { Initialize-ArcBoxDeployment } | Should -Throw '*azd env set JS_NESTED_SQL_MODE Evaluation*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }

    It 'rejects an invalid flavor before Azure operations' {
        $env:JS_ARCBOX_FLAVOR = 'Full'
        { Initialize-ArcBoxDeployment } | Should -Throw '*must be ITPro, DevOps, or DataOps*'
        Should -Invoke Invoke-ArcBoxAz -Times 0
    }

    It 'rejects invalid wait configuration before registering providers' {
        $env:JS_ARCBOX_TIMEOUT_MINUTES = 'unlimited'
        { Initialize-ArcBoxDeployment } | Should -Throw '*between 1 and 1440*'
        Should -Invoke Invoke-ArcBoxAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'provider' }
    }

    It 'refuses to adopt an unrelated resource group' {
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz { '[]' } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*without an ArcBox azd deployment*'
    }

    It 'refuses a flavor change in an existing environment' {
        $env:JS_ARCBOX_FLAVOR = 'DevOps'
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz {
            '[{"name":"arcbox","properties":{"parameters":{"flavor":{"value":"ITPro"},"resourceTags":{"value":{"azd-env-name":"arcbox-test"}}}}}]'
        } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*already deploys ITPro*'
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }

    It 'does not persist a menu selection that conflicts with an existing lab' {
        $env:JS_ARCBOX_FLAVOR = $null
        Mock Select-ArcBoxFlavor { 'DevOps' }
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz {
            '[{"name":"arcbox","properties":{"parameters":{"flavor":{"value":"ITPro"},"resourceTags":{"value":{"azd-env-name":"arcbox-test"}}}}}]'
        } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*already deploys ITPro*'
        Should -Invoke Set-ArcBoxEnvironmentValue -Times 0
    }

    It 'allows retrying an existing environment with the same flavor' {
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz {
            '[{"name":"arcbox","properties":{"parameters":{"flavor":{"value":"ITPro"},"resourceTags":{"value":{"azd-env-name":"arcbox-test"}}}}}]'
        } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        Initialize-ArcBoxDeployment
        $env:JS_ARCBOX_FLAVOR | Should -Be ITPro
    }

    It 'refuses to adopt a manually deployed ArcBox resource group' {
        Mock Invoke-ArcBoxAz { 'true' } -ParameterFilter { $Arguments[0] -eq 'group' }
        Mock Invoke-ArcBoxAz {
            '[{"name":"arcbox","properties":{"parameters":{"flavor":{"value":"ITPro"}}}}]'
        } -ParameterFilter { $Arguments[0] -eq 'deployment' }
        { Initialize-ArcBoxDeployment } | Should -Throw '*without an ArcBox azd deployment*'
    }

    It 'accepts the wait boundary <minutes>' -ForEach @(
        @{ minutes = '1' }, @{ minutes = '1440' }
    ) {
        $env:JS_ARCBOX_TIMEOUT_MINUTES = $minutes
        Get-ArcBoxTimeoutMinutes | Should -Be ([int]$minutes)
    }

    It 'rejects an out-of-range wait <minutes>' -ForEach @(
        @{ minutes = '0' }, @{ minutes = '1441' }
    ) {
        $env:JS_ARCBOX_TIMEOUT_MINUTES = $minutes
        { Get-ArcBoxTimeoutMinutes } | Should -Throw '*between 1 and 1440*'
    }

    It 'registers missing providers for DataOps' {
        $env:JS_ARCBOX_FLAVOR = 'DataOps'
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        $env:JS_CUSTOM_LOCATION_RP_ID = '00000000-0000-0000-0000-000000000002'
        Mock Invoke-ArcBoxAz { '[]' } -ParameterFilter { $Arguments[0] -eq 'provider' -and $Arguments[1] -eq 'list' }
        Mock Invoke-ArcBoxAz {} -ParameterFilter { $Arguments[0] -eq 'provider' -and $Arguments[1] -eq 'register' }
        Initialize-ArcBoxDeployment
        Should -Invoke Invoke-ArcBoxAz -Exactly -Times 16 -ParameterFilter { $Arguments[0] -eq 'provider' -and $Arguments[1] -eq 'register' }
        Should -Invoke Invoke-ArcBoxAz -Exactly -Times 1 -ParameterFilter { $Arguments -contains 'Microsoft.ContainerService' }
    }

    It 'generates a per-environment SSH key pair without invoking Azure for a private key' {
        $env:JS_ARCBOX_FLAVOR = 'DevOps'
        Mock Test-Path { $false }
        Mock New-Item {}
        Mock ssh-keygen { $global:LASTEXITCODE = 0 }
        Mock Get-Content { 'ssh-rsa dGVzdA== arcbox-test' }
        Initialize-ArcBoxDeployment
        Should -Invoke ssh-keygen -Exactly -Times 1 -ParameterFilter {
            $Arguments -contains '-N' -and ($Arguments | Where-Object { $_ -like '*arcbox-test*id_rsa' })
        }
        $env:JS_SSH_PUBLIC_KEY | Should -Be 'ssh-rsa dGVzdA== arcbox-test'
    }

    It 'reuses an existing per-environment public key' {
        $env:JS_ARCBOX_FLAVOR = 'DevOps'
        Mock Test-Path { $true }
        Mock Get-Content { 'ssh-rsa dGVzdA== arcbox-test' }
        Mock ssh-keygen {}
        Initialize-ArcBoxDeployment
        Should -Invoke ssh-keygen -Times 0
        $env:JS_SSH_PUBLIC_KEY | Should -Be 'ssh-rsa dGVzdA== arcbox-test'
    }

    It 'never overwrites a private key whose public key is missing' {
        $env:JS_ARCBOX_FLAVOR = 'DevOps'
        Mock Test-Path { $Path -notlike '*.pub' }
        Mock ssh-keygen {}
        { Initialize-ArcBoxDeployment } | Should -Throw '*private key will not be overwritten*'
        Should -Invoke ssh-keygen -Times 0
    }

    It 'rejects a path instead of RSA public-key contents' {
        $env:JS_ARCBOX_FLAVOR = 'DevOps'
        $env:JS_SSH_PUBLIC_KEY = 'id_rsa.pub'
        { Initialize-ArcBoxDeployment } | Should -Throw '*must contain an OpenSSH RSA public key*'
    }

    It 'looks up the Custom Locations RP only for DataOps' {
        $env:JS_ARCBOX_FLAVOR = 'DataOps'
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        Initialize-ArcBoxDeployment
        $env:JS_CUSTOM_LOCATION_RP_ID | Should -Be '00000000-0000-0000-0000-000000000002'
        Should -Invoke Invoke-ArcBoxAz -Exactly -Times 1 -ParameterFilter { $Arguments[0] -eq 'ad' }
    }

    It 'fails explicitly if the Custom Locations RP lookup is empty' {
        $env:JS_ARCBOX_FLAVOR = 'DataOps'
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        Mock Invoke-ArcBoxAz { '[]' } -ParameterFilter { $Arguments[0] -eq 'ad' }
        { Initialize-ArcBoxDeployment } | Should -Throw "*Expected one 'Custom Locations RP'*"
    }

    It 'rejects an invalid DataOps Custom Locations RP object ID' {
        $env:JS_ARCBOX_FLAVOR = 'DataOps'
        $env:JS_SSH_PUBLIC_KEY = 'ssh-rsa dGVzdA== arcbox-test'
        $env:JS_CUSTOM_LOCATION_RP_ID = 'not-a-guid'
        { Initialize-ArcBoxDeployment } | Should -Throw '*must be the object ID*'
    }
}

Describe 'ArcBox bootstrap argument binding' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $clientTemplate = Get-Content (Join-Path $arcboxRoot 'bicep/clientVm/clientVm.bicep') -Raw
        $commandTemplate = [regex]::Match($clientTemplate, "commandToExecute: '(?<command>[^`r`n]+)'").Groups['command'].Value
        $bootstrapTokens = $null
        $bootstrapErrors = $null
        $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts/Bootstrap.ps1'), [ref]$bootstrapTokens, [ref]$bootstrapErrors)
        if ($bootstrapErrors) {
            throw ($bootstrapErrors | Out-String)
        }
        # Execute only the real parameter block, never the VM provisioning body.
        $probe = $bootstrapAst.ParamBlock.Extent.Text + @'

[pscustomobject]@{
    flavor = $flavor
    customLocationRPOID = $customLocationRPOID
    namingPrefix = $namingPrefix
    nestedSqlMode = $nestedSqlMode
} | ConvertTo-Json -Compress
'@
        Set-Content -Path (Join-Path $TestDrive 'Bootstrap.ps1') -Value $probe
    }

    It 'omits the Custom Locations argument when the optional value is empty' {
        $clientTemplate | Should -Match ([regex]::Escape("var customLocationRPArgument = empty(customLocationRPOID) ? '' : '-customLocationRPOID `${customLocationRPOID}'"))
        $commandTemplate | Should -Match ([regex]::Escape('${customLocationRPArgument}'))
        $commandTemplate | Should -Not -Match ([regex]::Escape('-customLocationRPOID ${customLocationRPOID}'))
    }

    It 'reproduces the original missing-value failure without executing VM setup' -Skip:(-not $IsWindows) {
        $previousLocation = Get-Location
        try {
            Set-Location $TestDrive
            $output = & $env:ComSpec /d /c 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File Bootstrap.ps1 -flavor ITPro -customLocationRPOID -resourceTags {} -namingPrefix ArcBox' 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output | Out-String) | Should -Match "Missing an argument[\s\S]*customLocationRPOID"
        } finally {
            Set-Location $previousLocation
        }
    }

    It 'binds the full bootstrap command for <flavor> with object ID "<objectId>"' -Skip:(-not $IsWindows) -ForEach @(
        @{ flavor = 'ITPro'; objectId = '' },
        @{ flavor = 'DevOps'; objectId = '' },
        @{ flavor = 'DataOps'; objectId = '00000000-0000-0000-0000-000000000002' },
        @{ flavor = 'ITPro'; objectId = '00000000-0000-0000-0000-000000000002' }
    ) {
        $values = @{
            flavor = $flavor
            namingPrefix = 'ArcBox'
            resourceTags = '{}'
            nestedSqlMode = 'Evaluation'
            customLocationRPArgument = if ($objectId) { "-customLocationRPOID $objectId" } else { '' }
        }
        $command = [regex]::Replace($commandTemplate, '\$\{([^}]+)\}', {
            param($match)
            $name = $match.Groups[1].Value
            if ($values.ContainsKey($name)) { $values[$name] } else { 'test' }
        })
        $command = $command.Replace('powershell.exe ', 'powershell.exe -NoProfile ')
        $previousLocation = Get-Location
        try {
            Set-Location $TestDrive
            $output = & $env:ComSpec /d /c $command 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
            $boundParameters = $output | ConvertFrom-Json
            $boundParameters.flavor | Should -Be $flavor
            $boundParameters.customLocationRPOID | Should -Be $objectId
            $boundParameters.namingPrefix | Should -Be ArcBox
            $boundParameters.nestedSqlMode | Should -Be Evaluation
        } finally {
            Set-Location $previousLocation
        }
    }
}

Describe 'ArcBox standalone artifact source' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $main = Get-Content (Join-Path $arcboxRoot 'ARM/azuredeploy.json') -Raw | ConvertFrom-Json
        $parameters = Get-Content (Join-Path $arcboxRoot 'bicep/main.azd.parameters.json') -Raw | ConvertFrom-Json
    }

    It 'defaults to the public standalone repository at its root' {
        $main.parameters.githubAccount.defaultValue | Should -Be 'da5is'
        $main.parameters.githubBranch.defaultValue | Should -Be 'main'
        $main.variables.templateBaseUrl | Should -Be "[format('https://raw.githubusercontent.com/{0}/azd_arcbox/{1}/', parameters('githubAccount'), parameters('githubBranch'))]"
        $parameters.parameters.githubAccount.value | Should -Be '${JS_GITHUB_ACCOUNT=da5is}'
    }

    It 'retrieves integration scripts from the same standalone artifact root' {
        $wait = Get-Content (Join-Path $arcboxRoot 'artifacts/integration_tests/scripts/Wait-ArcBoxDeployment.ps1') -Raw
        $wait | Should -Match ([regex]::Escape('https://raw.githubusercontent.com/$githubAccount/azd_arcbox/$githubBranch/artifacts/'))
        $wait | Should -Not -Match 'azure_arc/'
    }

    It 'does not download or retain the shared-credential telemetry script' {
        Test-Path (Join-Path $arcboxRoot 'artifacts/DeploymentStatus.ps1') | Should -BeFalse
        $bootstrap = Get-Content (Join-Path $arcboxRoot 'artifacts/Bootstrap.ps1') -Raw
        $bootstrap | Should -Not -Match 'artifacts/DeploymentStatus\.ps1'
    }
}

Describe 'ArcBox ITPro nested memory allocation' {
    It 'allocates 4 GB to Ubuntu SQL and 2 GB to the non-SQL guest' {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $configuration = Get-Content (Join-Path $arcboxRoot 'artifacts\dsc\virtual_machines_itpro.dsc.yml') -Raw
        foreach ($guest in @(@{ Image = 'Ubuntu-01'; Memory = 4 }, @{ Image = 'Ubuntu-02'; Memory = 2 })) {
            $configuration | Should -Match "(?s)VhdPath: [^\r\n]*namingPrefixStage-$($guest.Image)\.vhdx\s+ProcessorCount: 2\s+StartupMemory: '$($guest.Memory)GB'"
        }
    }
}

Describe 'ArcBox guest provisioning safeguards' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $source = Get-Content (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    }
    It 'checks every AzCopy and WinGet configuration exit code before proceeding' {
        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('azcopy', 'winget')
        }, $true))
        $commands.Count | Should -Be 3
        foreach ($command in $commands) {
            $following = $source.Substring($command.Extent.EndOffset)
            $following | Should -Match '^\s+if \(\$LASTEXITCODE -ne 0\) \{\s+throw '
        }
    }
    It 'merges the opt-out tag without replacing existing tags' {
        $source | Should -Match 'az tag update [^\r\n]+--operation Merge --tags ArcSQLServerExtensionDeployment=Disabled'
        $source | Should -Not -Match 'az tag create'
    }
    It 'reports Ubuntu onboarding before running its package installer rather than leaving the Windows SQL stage' {
        $progress = $source.IndexOf("DeploymentProgress = 'Onboarding Ubuntu guests to Azure Arc'")
        $progress | Should -BeGreaterThan $source.IndexOf('Installing SQL Server extensions on Arc-enabled Windows VMs')
        $progress | Should -BeLessThan $source.IndexOf('sudo -n sh "/home/$using:nestedLinuxUsername/installArcAgentModifiedUbuntu.sh"')
        $progress | Should -BeGreaterThan -1
        $source.Substring($progress - 180, 180) | Should -Match 'Update-AzTag.*-Operation Merge -Tag'
    }
    It 'names the prebuilt SQL Server guest for its OS and SQL Server versions' {
        $source | Should -Match "\$SQLvmName = 'win22sql22'"
        $configuration = Get-Content (Join-Path $arcboxRoot 'artifacts\dsc\virtual_machines_sql.dsc.yml') -Raw
        $configuration | Should -Match '(?s)id: win22sql22.*?Name: win22sql22'
    }
    It 'submits the policy scan within the resource group and retains setup recovery until validation runs' {
        $source | Should -Match 'Invoke-AzRestMethod -Method POST -Path "/subscriptions/\$subscriptionId/resourceGroups/\$resourceGroup/providers/Microsoft.PolicyInsights/policyStates/latest/triggerEvaluation\?api-version=2019-10-01" -ErrorAction Stop'
        $source | Should -Match '\$policyScan.StatusCode -notin @\(200, 202, 204\)'
        $source | Should -Not -Match 'Start-AzPolicyComplianceScan'
        $source.IndexOf("Unregister-ScheduledTask -TaskName 'ArcServersLogonScript'") |
            Should -BeGreaterThan $source.IndexOf('& "$Env:ArcBoxTestsDir\Invoke-Test.ps1"')
    }
    It 'uses destination directories for Linux Hyper-V file copies' {
        $copies = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Copy-ArcBoxLinuxGuestFile' -and
                $node.Extent.Text -match '/home/'
        }, $true))
        $copies.Count | Should -Be 3
        $copies[0].Extent.Text | Should -Match '-DestinationDirectory "/home/\$nestedLinuxUsername/\.ssh"'
        $copies[1].Extent.Text | Should -Match '-DestinationDirectory "/home/\$nestedLinuxUsername"'
        $copies[2].Extent.Text | Should -Match '-DestinationDirectory "/home/\$nestedLinuxUsername"'
    }
    It 'configures lifecycle policies only for the six named guests' {
        $loop = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.VariablePath.UserPath -eq 'vmName'
        }, $true)
        $loop | Should -Not -BeNullOrEmpty
        $SQLvmName = 'win22sql22'
        $Win19Sql16vmName = 'win19sql16'
        $Win22Sql19vmName = 'win22sql19'
        $Win25Sql25vmName = 'win25sql25'
        $Ubuntu01vmName = 'test-Ubuntu-01'
        $Ubuntu02vmName = 'test-Ubuntu-02'
        $script:configuredGuests = @()
        function Set-ArcBoxGuestLifecycle {
            param($VMName)
            $script:configuredGuests += $VMName
        }
        & ([scriptblock]::Create($loop.Extent.Text))
        $script:configuredGuests.Count | Should -Be 6
        $script:configuredGuests | Should -Contain 'win22sql22'
        $script:configuredGuests | Should -Contain 'win19sql16'
        $script:configuredGuests | Should -Contain 'win22sql19'
        $script:configuredGuests | Should -Contain 'win25sql25'
        $source | Should -Not -Match 'Stop-VM[^\r\n]+-TurnOff'
    }
}

Describe 'ArcBox guest lifecycle retries' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-ArcBoxGuestLifecycle'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        function Get-VM { param($Name) }
        function Set-VM { param($Name, $AutomaticStopAction, $AutomaticStartAction) }
        function Stop-VM { param($Name, [switch]$AsJob) }
        function Start-VM { param($Name) }
        function Wait-Job { param($Job, $Timeout) }
        function Receive-Job { param($Job) }
        function Stop-Job { param($Job) }
        function Remove-Job { param($Job) }
    }
    BeforeEach {
        $script:vm = [pscustomobject]@{ State = 'Running'; AutomaticStopAction = 'Save'; AutomaticStartAction = 'StartIfRunning' }
        Mock Get-VM { $script:vm }
        Mock Set-VM {}
        Mock Stop-VM { $script:vm.State = 'Off'; [pscustomobject]@{ State = 'Completed' } }
        Mock Start-VM { $script:vm.State = 'Running' }
        Mock Wait-Job { $Job }
        Mock Receive-Job {}
        Mock Remove-Job {}
        Mock Stop-Job {}
    }
    It 'leaves already configured running guests untouched' {
        $script:vm.AutomaticStopAction = 'ShutDown'
        $script:vm.AutomaticStartAction = 'Start'
        Set-ArcBoxGuestLifecycle -VMName test-vm
        Should -Invoke Stop-VM -Times 0 -Exactly
        Should -Invoke Set-VM -Times 0 -Exactly
    }
    It 'shuts down before changing the stop policy and restores the running state' {
        Mock Set-VM { $script:vm.State | Should -Be Off }
        Set-ArcBoxGuestLifecycle -VMName test-vm
        Should -Invoke Stop-VM -Times 1 -Exactly -ParameterFilter { $AsJob }
        Should -Invoke Start-VM -Times 1 -Exactly
        $script:vm.State | Should -Be Running
    }
    It 'restores a running guest even when the settings update fails' {
        Mock Set-VM { throw 'settings failure' }
        { Set-ArcBoxGuestLifecycle -VMName test-vm } | Should -Throw '*settings failure*'
        Should -Invoke Start-VM -Times 1 -Exactly
    }
    It 'does not restart a guest when only its start policy needs changing' {
        $script:vm.AutomaticStopAction = 'ShutDown'
        Set-ArcBoxGuestLifecycle -VMName test-vm
        Should -Invoke Stop-VM -Times 0 -Exactly
        Should -Invoke Set-VM -Times 1 -Exactly
    }
    It 'leaves an initially stopped guest stopped' {
        $script:vm.State = 'Off'
        Set-ArcBoxGuestLifecycle -VMName test-vm
        Should -Invoke Stop-VM -Times 0 -Exactly
        Should -Invoke Start-VM -Times 0 -Exactly
        Should -Invoke Set-VM -Times 1 -Exactly
    }
    It 'fails explicitly on shutdown timeout without forcing power off' {
        Mock Stop-VM { [pscustomobject]@{ State = 'Running' } }
        Mock Wait-Job {}
        { Set-ArcBoxGuestLifecycle -VMName test-vm } | Should -Throw '*Timed out*'
        Should -Invoke Set-VM -Times 0 -Exactly
        Should -Invoke Stop-Job -Times 1 -Exactly
    }
}

Describe 'ArcBox retry-safe guest disks' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-ArcBoxGuestDisk'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        function Get-VM {}
        function Get-VMHardDiskDrive {}
        function azcopy { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    }
    BeforeEach {
        $vhdSourceFolder = 'https://example.test/disks/*'
        Mock Get-VM { [pscustomobject]@{ Name = 'test-vm' } }
        Mock Get-VMHardDiskDrive {}
        Mock azcopy {
            $global:LASTEXITCODE = 0
            Set-Content -LiteralPath $Arguments[2] -Value 'disk-data'
        }
    }
    It 'does not touch an existing guest disk' {
        $path = Join-Path $TestDrive 'existing.vhdx'
        Set-Content $path 'existing-data'
        Save-ArcBoxGuestDisk -SourceName 'ArcBox-Win2K19.vhdx' -DestinationPath $path
        Get-Content $path | Should -Be 'existing-data'
        Should -Invoke azcopy -Exactly -Times 0
    }
    It 'downloads only the requested missing disk into a staging file' {
        $path = Join-Path $TestDrive 'missing.vhdx'
        Save-ArcBoxGuestDisk -SourceName 'ArcBox-Win2K19.vhdx' -DestinationPath $path
        Get-Content $path | Should -Be 'disk-data'
        Test-Path "$path.download" | Should -BeFalse
        Should -Invoke azcopy -Exactly -Times 1 -ParameterFilter {
            $Arguments[1] -eq 'https://example.test/disks/ArcBox-Win2K19.vhdx' -and
            $Arguments[2] -eq "$path.download"
        }
    }
    It 'refuses a missing path still attached to a VM' {
        $path = Join-Path $TestDrive 'attached.vhdx'
        $script:attachedPath = $path
        Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = $script:attachedPath } }
        { Save-ArcBoxGuestDisk -SourceName 'ArcBox-Win2K19.vhdx' -DestinationPath $path } | Should -Throw '*attached guest disk*'
        Should -Invoke azcopy -Exactly -Times 0
    }
    It 'cleans failed downloads without publishing a guest disk' {
        Mock azcopy {
            Set-Content -LiteralPath $Arguments[2] -Value 'partial'
            $global:LASTEXITCODE = 8
        }
        $path = Join-Path $TestDrive 'failed.vhdx'
        { Save-ArcBoxGuestDisk -SourceName 'ArcBox-Win2K19.vhdx' -DestinationPath $path } | Should -Throw '*exit code 8*'
        Test-Path $path | Should -BeFalse
        Test-Path "$path.download" | Should -BeFalse
    }
}

Describe 'ArcBox SQL extension installation' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Install-ArcBoxSqlExtension'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    BeforeEach {
        $savedArcBoxDir = $env:ArcBoxDir
        $env:ArcBoxDir = $TestDrive
        $subscriptionId = 'test-subscription'
        $resourceGroup = 'test-rg'
        $resourceTags = 'test=value'
        $azureLocation = 'eastus2'
        Mock Start-Sleep {}
        $script:listCalls = 0
        Mock az {
            $global:LASTEXITCODE = 0
            if ($Arguments -contains 'rest') {
                $script:listCalls++
                if ($script:listCalls -gt 1) { 'Succeeded' }
            }
        }
    }
    AfterEach { $env:ArcBoxDir = $savedArcBoxDir }

    It 'passes valid settings by file rather than inline Windows JSON' {
        Mock az {
            $global:LASTEXITCODE = 0
            $settingsArgument = $Arguments[[array]::IndexOf($Arguments, '--settings') + 1]
            $settingsArgument | Should -BeLike '@*'
            $settings = Get-Content $settingsArgument.Substring(1) -Raw | ConvertFrom-Json
            $settings.LicenseType | Should -Be 'LicenseOnly'
            $settings.SqlManagement.IsEnabled | Should -BeTrue
            $settings.PSObject.Properties.Name | Should -Not -Contain enableExtendedSecurityUpdates
        } -ParameterFilter { $Arguments -contains 'create' }
        Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType LicenseOnly
        Test-Path (Join-Path $TestDrive 'SqlExtension-test-vm.json') | Should -BeFalse
        Should -Invoke az -Times 2 -Exactly -ParameterFilter { $Arguments -contains 'rest' }
        Should -Invoke az -Times 2 -Exactly -ParameterFilter {
            $Arguments -contains 'rest' -and
            $Arguments -contains 'value[?name==''WindowsAgent.SqlServer''].properties.provisioningState | [0]' -and
            ($Arguments -join ' ') -like '*Microsoft.HybridCompute/machines/test-vm/extensions?api-version=2024-07-10*'
        }
    }

    It 'stops immediately when extension creation fails' {
        Mock az { $global:LASTEXITCODE = 9 } -ParameterFilter { $Arguments -contains 'create' }
        { Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid } | Should -Throw '*creation failed*exit code 9*'
        Should -Invoke az -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'rest' }
    }

    It 'surfaces a failed provisioning state' {
        Mock az { $global:LASTEXITCODE = 0; 'Failed' } -ParameterFilter { $Arguments -contains 'rest' }
        { Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid } | Should -Throw "*state 'Failed'*"
    }

    It 'surfaces a status lookup failure' {
        Mock az { $global:LASTEXITCODE = 7 } -ParameterFilter { $Arguments -contains 'rest' }
        { Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid } | Should -Throw '*list SQL extensions*exit code 7*'
    }

    It 'times out instead of reporting success for a pending extension' {
        $script:dateCalls = 0
        Mock Get-Date {
            $script:dateCalls++
            ([datetime]'2026-10-11T00:00:00Z').AddMinutes(16 * ($script:dateCalls - 1))
        }
        Mock az { $global:LASTEXITCODE = 0; 'Creating' } -ParameterFilter { $Arguments -contains 'rest' }
        { Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid } | Should -Throw '*Timed out*'
    }
    It 'tolerates an extension not yet visible after asynchronous creation' {
        Mock az {
            $global:LASTEXITCODE = 0
            $script:listCalls++
            if ($script:listCalls -gt 2) { 'Succeeded' }
        } -ParameterFilter { $Arguments -contains 'rest' }
        Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid
        Should -Invoke Start-Sleep -Exactly -Times 1
    }
    It 'does not recreate an already successful extension' {
        Mock az { $global:LASTEXITCODE = 0; 'Succeeded' } -ParameterFilter { $Arguments -contains 'rest' }
        Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType Paid
        Should -Invoke az -Exactly -Times 0 -ParameterFilter { $Arguments -contains 'create' }
        Should -Invoke az -Exactly -Times 0 -ParameterFilter { $Arguments -contains 'update' }
    }
    It 'preserves manually configured Software Assurance and ESU settings on retries' {
        $script:existingSettings = '{"LicenseType":"Paid","enableExtendedSecurityUpdates":true}'
        Mock az {
            $global:LASTEXITCODE = 0
            'Succeeded'
        } -ParameterFilter { $Arguments -contains 'rest' }
        Mock az {
            $script:existingSettings = 'overwritten'
            throw 'Existing extension settings must not be changed.'
        } -ParameterFilter { $Arguments -contains 'update' -or $Arguments -contains 'create' }
        Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType LicenseOnly
        $script:existingSettings | Should -Be '{"LicenseType":"Paid","enableExtendedSecurityUpdates":true}'
        Should -Invoke az -Exactly -Times 1
        Test-Path (Join-Path $TestDrive 'SqlExtension-test-vm.json') | Should -BeFalse
    }
    It 'waits for an existing pending extension without overwriting its configuration' {
        Mock az {
            $global:LASTEXITCODE = 0
            $script:listCalls++
            if ($script:listCalls -eq 1) { 'Updating' } else { 'Succeeded' }
        } -ParameterFilter { $Arguments -contains 'rest' }
        Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType LicenseOnly
        Should -Invoke az -Exactly -Times 0 -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'update' }
    }
    It 'does not reset licensing to repair a failed existing extension' {
        Mock az { $global:LASTEXITCODE = 0; 'Failed' } -ParameterFilter { $Arguments -contains 'rest' }
        { Install-ArcBoxSqlExtension -MachineName 'test-vm' -LicenseType LicenseOnly } | Should -Throw '*Repair the existing extension*'
        Should -Invoke az -Exactly -Times 0 -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'update' }
    }
}

Describe 'ArcBox SQL installation modes' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $installer = Get-Content (Join-Path $arcboxRoot 'artifacts\InstallNestedSqlServer.ps1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$null, [ref]$null)
        foreach ($functionName in @('Assert-SqlEdition', 'Invoke-SqlServerSetup')) {
            $function = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $assignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$versions'
        }, $true)
        . ([scriptblock]::Create($assignment.Extent.Text))
        function Save-SqlDownload { param($Uri, $Path) }
        function Invoke-SqlSetupProcess { param($FilePath, $Arguments) }
        function Mount-DiskImage { param($ImagePath, [switch]$PassThru) }
        function Dismount-DiskImage { param($ImagePath) }
        function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) }
    }
    BeforeEach {
        $SqlVersion = '2019'
        $InstallationMode = 'Developer'
        $installDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item $installDirectory -ItemType Directory
        Mock Write-Warning {}
        Mock Save-SqlDownload {}
        Mock Mount-DiskImage { [pscustomobject]@{ ImagePath = $ImagePath } }
        Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'TestDrive' } }
        Mock Dismount-DiskImage {}
        Set-Content (Join-Path $TestDrive 'setup.exe') 'mock setup'
        Mock Invoke-SqlSetupProcess {
            if ($FilePath -like '*SSEI-*.exe') {
                $mediaPath = ($Arguments | Where-Object { $_ -like '/MediaPath=*' }) -replace '^/MediaPath="|"$', ''
                Set-Content (Join-Path $mediaPath 'downloaded.iso') 'mock ISO'
            }
        }
    }
    It 'retains Developer as the default and rejects unsupported installation modes' {
        $probe = [scriptblock]::Create($ast.ParamBlock.Extent.Text + '; $InstallationMode')
        & $probe -SqlVersion 2019 | Should -Be Developer
        { & $probe -SqlVersion 2019 -InstallationMode PAYG } | Should -Throw
        { & $probe -SqlVersion 2019 -InstallationMode BYOL } | Should -Throw
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Not -Contain ByolEdition
    }
    It 'accepts <edition> in <mode> mode' -ForEach @(
        @{ mode = 'Developer'; edition = 'Developer Edition (64-bit)' },
        @{ mode = 'Developer'; edition = 'Enterprise Developer Edition (64-bit)' },
        @{ mode = 'Evaluation'; edition = 'Enterprise Evaluation Edition (64-bit)' },
        @{ mode = 'Evaluation'; edition = 'Standard Edition (64-bit)' },
        @{ mode = 'Evaluation'; edition = 'Enterprise Edition (64-bit)' }
    ) {
        $InstallationMode = $mode
        { Assert-SqlEdition -Edition $edition } | Should -Not -Throw
    }
    It 'rejects incompatible existing editions in <mode> mode: <edition>' -ForEach @(
        @{ mode = 'Evaluation'; edition = 'Developer Edition (64-bit)' },
        @{ mode = 'Developer'; edition = 'Enterprise Evaluation Edition (64-bit)' },
        @{ mode = 'Evaluation'; edition = 'Enterprise Developer Edition (64-bit)' },
        @{ mode = 'Evaluation'; edition = 'Express Edition (64-bit)' },
        @{ mode = 'Developer'; edition = 'Enterprise Edition (64-bit)' }
    ) {
        $InstallationMode = $mode
        { Assert-SqlEdition -Edition $edition } | Should -Throw '*does not convert an existing instance*'
    }
    It 'selects separate <mode> media for SQL <versionNumber>' -ForEach @(
        @{ mode = 'Developer'; versionNumber = '2016' },
        @{ mode = 'Developer'; versionNumber = '2019' },
        @{ mode = 'Developer'; versionNumber = '2025' },
        @{ mode = 'Evaluation'; versionNumber = '2016' },
        @{ mode = 'Evaluation'; versionNumber = '2019' },
        @{ mode = 'Evaluation'; versionNumber = '2025' }
    ) {
        $SqlVersion = $versionNumber
        $InstallationMode = $mode
        Invoke-SqlServerSetup -SqlVersionInfo $versions[$SqlVersion]
        $mediaEdition = if ($mode -eq 'Developer') { 'Developer' } else { 'Evaluation' }
        $expectedMediaDirectory = if ($mediaEdition -eq 'Developer') { $installDirectory } else { Join-Path $installDirectory 'Evaluation' }
        $expectedUri = if ($mode -ne 'Developer') {
            $versions[$SqlVersion].EvaluationBootstrapperUrl
        } elseif ($SqlVersion -eq '2016') {
            $versions[$SqlVersion].IsoUrl
        } else { $versions[$SqlVersion].BootstrapperUrl }
        Should -Invoke Save-SqlDownload -Exactly -Times 1 -ParameterFilter { $Uri -eq $expectedUri }
        Should -Invoke Mount-DiskImage -Exactly -Times 1 -ParameterFilter {
            $ImagePath -eq (Join-Path $expectedMediaDirectory "SQLServer$SqlVersion.iso")
        }
        Should -Invoke Invoke-SqlSetupProcess -Exactly -Times 1 -ParameterFilter {
            $FilePath -eq 'TestDrive:\setup.exe' -and $Arguments -contains "/ConfigurationFile=`"$installDirectory\ConfigurationFile.ini`""
        }
        if ($SqlVersion -eq '2016' -and $mode -ne 'Developer') {
            Should -Invoke Save-SqlDownload -Exactly -Times 1 -ParameterFilter { $Uri -eq $versions['2016'].ServicePackUrl }
            Should -Invoke Invoke-SqlSetupProcess -Exactly -Times 1 -ParameterFilter {
                $Arguments -contains '/UpdateEnabled=True' -and $Arguments -contains "/UpdateSource=`"$installDirectory\Evaluation\Updates`""
            }
        }
        Should -Invoke Dismount-DiskImage -Exactly -Times 1
    }
    It 'reuses existing Developer media without downloading it again' {
        $SqlVersion = '2019'
        Set-Content (Join-Path $installDirectory 'SQLServer2019.iso') 'cached Developer ISO'
        Invoke-SqlServerSetup -SqlVersionInfo $versions[$SqlVersion]
        Should -Invoke Save-SqlDownload -Exactly -Times 0
        Should -Invoke Invoke-SqlSetupProcess -Exactly -Times 0 -ParameterFilter { $FilePath -like '*SSEI-*.exe' }
    }
    It 'does not mistake cached Developer media for Evaluation media' {
        $InstallationMode = 'Evaluation'
        Set-Content (Join-Path $installDirectory 'SQLServer2019.iso') 'cached Developer ISO'
        Invoke-SqlServerSetup -SqlVersionInfo $versions[$SqlVersion]
        Should -Invoke Save-SqlDownload -Exactly -Times 1 -ParameterFilter { $Uri -eq $versions['2019'].EvaluationBootstrapperUrl }
        Get-Content (Join-Path $installDirectory 'SQLServer2019.iso') | Should -Be 'cached Developer ISO'
    }
    It 'wires both options through deployment templates and the bootstrap machine environment' {
        $mapping = Get-Content (Join-Path $arcboxRoot 'bicep\main.azd.parameters.json') -Raw | ConvertFrom-Json
        $mapping.parameters.nestedSqlMode.value | Should -Be '${JS_NESTED_SQL_MODE=Developer}'
        $mapping.parameters.PSObject.Properties.Name | Should -Not -Contain nestedSqlByolEdition
        foreach ($path in @('bicep\main.azd.bicep', 'bicep\main.bicep')) {
            $source = Get-Content (Join-Path $arcboxRoot $path) -Raw
            $source | Should -Match 'nestedSqlMode: nestedSqlMode'
            $source | Should -Not -Match 'nestedSqlByolEdition|''BYOL'''
        }
        $bootstrap = Get-Content (Join-Path $arcboxRoot 'artifacts\Bootstrap.ps1') -Raw
        $bootstrap | Should -Match ([regex]::Escape("SetEnvironmentVariable('nestedSqlMode', `$nestedSqlMode, [System.EnvironmentVariableTarget]::Machine)"))
        $bootstrap | Should -Not -Match 'nestedSqlByolEdition|''BYOL'''
        $client = Get-Content (Join-Path $arcboxRoot 'ARM\clientVm\clientVm.json') -Raw | ConvertFrom-Json
        $client.parameters.nestedSqlMode.allowedValues | Should -Be @('Developer', 'Evaluation')
        $client.parameters.PSObject.Properties.Name | Should -Not -Contain nestedSqlByolEdition
        $hostSource = Get-Content (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1') -Raw
        ([regex]::Matches($hostSource, '-InstallationMode \$mode')).Count | Should -Be 2
        $hostSource | Should -Match 'Install-ArcBoxSqlExtension -MachineName \$additionalSqlMachine -LicenseType LicenseOnly'
        $hostSource | Should -Not -Match 'ByolEdition|sqlGuestLicenseTypes|Installation\.json'
        $installer | Should -Not -Match 'LicenseType|''Paid''|Installation\.json'
    }
    It 'passes the selected installation mode into both initial and post-reboot guest setup' {
        $hostAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\ArcServersLogonScript.ps1'), [ref]$null, [ref]$null)
        $commands = $hostAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'
        }, $true)
        $blocks = @($commands.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
            $_.Extent.Text -like '*InstallNestedSqlServer.ps1*'
        })
        $blocks.Count | Should -Be 2
        $nestedVMArcBoxDir = $TestDrive
        Set-Content (Join-Path $TestDrive 'InstallNestedSqlServer.ps1') @'
param($SqlVersion, $InstallationMode)
[pscustomobject]@{ Version = $SqlVersion; Mode = $InstallationMode }
'@
        Mock Remove-Item {}
        foreach ($block in $blocks) {
            $text = $block.Extent.Text
            $guestSetup = [scriptblock]::Create($text.Substring(1, $text.Length - 2).Replace('$Using:nestedVMArcBoxDir', '$nestedVMArcBoxDir'))
            $result = & $guestSetup '2016' 'Evaluation'
            $result.Version | Should -Be '2016'
            $result.Mode | Should -Be 'Evaluation'
        }
    }
}

Describe 'ArcBox SQL sample database batches' {
    It 'creates ArchiveDB in a separate batch before compiling its table' {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\InstallNestedSqlServer.ps1'), [ref]$null, [ref]$null)
        $assignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$archiveDatabaseQuery'
        }, $true)
        $archiveDataPath = 'C:\SQL\ArchiveDB.mdf'
        $archiveLogPath = 'C:\SQL\ArchiveDB_log.ldf'
        $archiveFileStreamPath = 'C:\SQL\ArchiveDB_FileStream'
        . ([scriptblock]::Create($assignment.Extent.Text))
        $batches = @($archiveDatabaseQuery -split '(?m)^GO\r?$')
        $batches.Count | Should -Be 3
        $batches[0] | Should -Match 'CREATE DATABASE \[ArchiveDB\]'
        $batches[0] | Should -Not -Match 'CREATE TABLE|ALTER DATABASE'
        $batches[1] | Should -Match "IF OBJECT_ID\(N'ArchiveDB.dbo.Records', N'U'\) IS NULL"
        $batches[1] | Should -Match 'CREATE TABLE \[ArchiveDB\]\.\[dbo\]\.\[Records\]'
        $batches[2] | Should -Match 'ALTER DATABASE \[ArchiveDB\] SET RECOVERY FULL'
    }
}

Describe 'ArcBox SQL artifact downloads' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\InstallNestedSqlServer.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-SqlDownload'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        $SqlVersion = '2019'
    }
    It 'does not retain an incomplete download as reusable installation media' {
        Mock Invoke-WebRequest {
            Set-Content -LiteralPath $OutFile -Value 'incomplete'
            throw 'Download interrupted'
        }
        $path = Join-Path $TestDrive 'sql.iso'
        { Save-SqlDownload -Uri 'https://example.test/sql.iso' -Path $path } | Should -Throw '*Download interrupted*'
        Test-Path $path | Should -BeFalse
        Test-Path "$path.partial" | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter { $TimeoutSec -eq 3600 }
    }
}

Describe 'ArcBox SQL setup process limits' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $arcboxRoot 'artifacts\InstallNestedSqlServer.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SqlSetupProcess'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        $SqlVersion = '2019'
    }
    BeforeEach {
        $installDirectory = $TestDrive
        $script:process = [pscustomobject]@{ Id = 12345; ExitCode = 0; Completed = $true; WaitMilliseconds = 0 }
        $script:process | Add-Member ScriptMethod WaitForExit {
            param($milliseconds)
            $this.WaitMilliseconds = $milliseconds
            return $this.Completed
        }
        $script:process | Add-Member ScriptMethod Refresh {}
        Mock Start-Process { $script:process }
        function taskkill.exe { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
        Mock taskkill.exe { $global:LASTEXITCODE = 0 }
    }
    It 'waits at most one hour for setup' {
        Invoke-SqlSetupProcess -FilePath 'setup.exe' -Arguments @('/Q')
        $script:process.WaitMilliseconds | Should -Be 3600000
        Should -Invoke taskkill.exe -Exactly -Times 0
    }
    It 'stops the specific installer process and fails on timeout' {
        $script:process.Completed = $false
        { Invoke-SqlSetupProcess -FilePath 'setup.exe' -Arguments @('/Q') } | Should -Throw '*60-minute limit*'
        Should -Invoke taskkill.exe -Exactly -Times 1 -ParameterFilter { $Arguments -contains '12345' -and $Arguments -contains '/T' }
    }
    It 'fails on an unsuccessful setup exit code' {
        $script:process.ExitCode = 5
        { Invoke-SqlSetupProcess -FilePath 'setup.exe' -Arguments @('/Q') } | Should -Throw '*exit code 5*'
    }
    It 'signals a required guest restart rather than proceeding to databases' {
        $script:process.ExitCode = 3010
        Invoke-SqlSetupProcess -FilePath 'setup.exe' -Arguments @('/Q')
        Test-Path (Join-Path $TestDrive 'RestartRequired') | Should -BeTrue
    }
}

Describe 'ArcBox private Key Vault deployment' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        $management = Get-Content (Join-Path $arcboxRoot 'ARM/mgmt/mgmtArtifacts.json') -Raw | ConvertFrom-Json
        $vaultDeployment = $management.resources.keyVault
    }

    It 'keeps public vault access disabled and configures a client-subnet private endpoint' {
        $vaultDeployment.properties.parameters.publicNetworkAccess.value | Should -Be 'Disabled'
        $endpoints = @($vaultDeployment.properties.parameters.privateEndpoints.value)
        $endpoints.Count | Should -Be 1
        $endpoints[0].subnetResourceId | Should -Match "Microsoft.Network/virtualNetworks/subnets.*parameters\('subnetName'\)"
        $endpoints[0].privateDnsZoneResourceIds | Should -Contain "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')]"
    }

    It 'links private vault DNS to the VNet before deploying the vault endpoint' {
        $management.resources.keyVaultPrivateDnsZone.name | Should -Be 'privatelink.vaultcore.azure.net'
        $link = $management.resources.keyVaultPrivateDnsLink
        $link.properties.registrationEnabled | Should -BeFalse
        $link.dependsOn | Should -Contain 'arcVirtualNetwork'
        $link.properties.virtualNetwork.id | Should -Match "Microsoft.Network/virtualNetworks"
        $vaultDeployment.dependsOn | Should -Contain 'keyVaultPrivateDnsLink'
    }

    It 'waits for the required identity role assignments before <extensionName>' -ForEach @(
        @{ templatePath = 'ARM/clientVm/clientVm.json'; extensionName = 'Bootstrap'; roles = @('Administrator', 'Owner', 'Storage Blob Data Contributor') },
        @{ templatePath = 'ARM/mgmt/addsVm.json'; extensionName = 'DeployADDS'; roles = @('reader', 'keyVaultSecretReader') }
    ) {
        $template = Get-Content (Join-Path $arcboxRoot $templatePath) -Raw | ConvertFrom-Json
        $extension = $template.resources | Where-Object {
            $_.type -eq 'Microsoft.Compute/virtualMachines/extensions' -and $_.name -like "*'$extensionName'*"
        }
        $extension | Should -Not -BeNullOrEmpty
        foreach ($role in $roles) {
            ($extension.dependsOn -join "`n") | Should -Match "Microsoft.Authorization/roleAssignments.*'$role'"
        }
    }
}

Describe 'ArcBox VM administrator secret retrieval' {
    BeforeAll {
        $arcboxRoot = Split-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) -Parent
        function Get-Secret {
            [CmdletBinding()]
            param([string]$Name, [string]$Vault, [switch]$AsPlainText)
            throw 'Unmocked secret retrieval.'
        }
        function Get-SecretRetrievalProbe {
            param([string]$ScriptName, [string]$VariableName)

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $arcboxRoot "artifacts/$ScriptName"), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors) {
                throw ($parseErrors | Out-String)
            }
            $statements = $ast.EndBlock.Statements
            $assignment = $statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $_.Left.VariablePath.UserPath -eq $VariableName
            } | Select-Object -First 1
            if (-not $assignment) {
                throw "Missing administrator secret assignment in $ScriptName."
            }
            $guard = $statements[$statements.IndexOf($assignment) + 1]
            if ($guard -isnot [System.Management.Automation.Language.IfStatementAst]) {
                throw "Missing administrator secret guard in $ScriptName."
            }
            # Execute only secret retrieval and its guard, never VM provisioning.
            [scriptblock]::Create($assignment.Extent.Text + "`n" + $guard.Extent.Text + "`n`$$VariableName")
        }
    }

    It 'retrieves the password from the selected vault in <scriptName>' -ForEach @(
        @{ scriptName = 'Bootstrap.ps1'; variableName = 'adminPassword' },
        @{ scriptName = 'SetupADDS.ps1'; variableName = 'windowsAdminPasswordSecret' }
    ) {
        $KeyVault = [pscustomobject]@{ VaultName = 'arcbox-test-vault' }
        $probe = Get-SecretRetrievalProbe -ScriptName $scriptName -VariableName $variableName
        Mock Get-Secret { 'mock-password' }
        & $probe | Should -Be 'mock-password'
        Should -Invoke Get-Secret -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'windowsAdminPassword' -and $Vault -eq 'arcbox-test-vault' -and
            $AsPlainText -and $ErrorAction -eq 'Stop'
        }
    }

    It 'rejects an empty password in <scriptName>' -ForEach @(
        @{ scriptName = 'Bootstrap.ps1'; variableName = 'adminPassword'; password = $null },
        @{ scriptName = 'Bootstrap.ps1'; variableName = 'adminPassword'; password = ' ' },
        @{ scriptName = 'SetupADDS.ps1'; variableName = 'windowsAdminPasswordSecret'; password = $null },
        @{ scriptName = 'SetupADDS.ps1'; variableName = 'windowsAdminPasswordSecret'; password = '' }
    ) {
        $KeyVault = [pscustomobject]@{ VaultName = 'arcbox-test-vault' }
        $probe = Get-SecretRetrievalProbe -ScriptName $scriptName -VariableName $variableName
        $script:mockPassword = $password
        Mock Get-Secret { $script:mockPassword }
        { & $probe } | Should -Throw '*empty windowsAdminPassword*'
    }

    It 'surfaces a vault access failure in <scriptName>' -ForEach @(
        @{ scriptName = 'Bootstrap.ps1'; variableName = 'adminPassword' },
        @{ scriptName = 'SetupADDS.ps1'; variableName = 'windowsAdminPasswordSecret' }
    ) {
        $KeyVault = [pscustomobject]@{ VaultName = 'arcbox-test-vault' }
        $probe = Get-SecretRetrievalProbe -ScriptName $scriptName -VariableName $variableName
        Mock Get-Secret { throw 'Key Vault network access denied.' }
        { & $probe } | Should -Throw '*Key Vault network access denied*'
    }
}

Describe 'ArcBox readiness wait' {
    BeforeEach {
        Initialize-TestEnvironment
        Mock Start-Sleep {}
        Mock Invoke-ArcBoxAz { '{"DeploymentProgress":"Completed","DeploymentStatus":"Tests succeeded: 12 Tests failed: 0"}' }
    }
    AfterEach { Restore-TestEnvironment }

    It 'accepts passing deployment checks' {
        { Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0 } | Should -Not -Throw
        Should -Invoke Invoke-ArcBoxAz -Exactly -Times 1
    }

    It 'waits through setup rather than returning at ARM completion' {
        $script:pollCount = 0
        Mock Invoke-ArcBoxAz {
            $script:pollCount++
            if ($script:pollCount -eq 1) {
                '{"DeploymentProgress":"Installing WinGet packages..."}'
            } else {
                '{"DeploymentProgress":"Completed","DeploymentStatus":"Tests succeeded: 12 Tests failed: 0"}'
            }
        }
        Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0
        Should -Invoke Invoke-ArcBoxAz -Exactly -Times 2
        Should -Invoke Start-Sleep -Exactly -Times 1
    }

    It 'fails when ArcBox checks report failure' {
        Mock Invoke-ArcBoxAz { '{"DeploymentProgress":"Failed","DeploymentStatus":"Tests succeeded: 10 Tests failed: 2"}' }
        { Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0 } | Should -Throw '*checks failed*'
    }

    It 'rejects completion without nonzero passing checks: <status>' -ForEach @(
        @{ status = '' }, @{ status = 'Tests succeeded: 0 Tests failed: 0' }, @{ status = 'Tests succeeded: 10 Tests failed: 1' }
    ) {
        $script:deploymentStatus = $status
        Mock Invoke-ArcBoxAz {
            @{ DeploymentProgress = 'Completed'; DeploymentStatus = $script:deploymentStatus } | ConvertTo-Json
        }
        { Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0 } | Should -Throw '*without passing deployment checks*'
    }

    It 'times out without claiming success or deleting resources' {
        $script:clock = [datetime]'2026-01-01T00:00:00Z'
        Mock Get-Date { $script:clock = $script:clock.AddSeconds(30); $script:clock }
        Mock Invoke-ArcBoxAz { '{"DeploymentProgress":"Installing WinGet packages..."}' }
        { Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0 } | Should -Throw '*Timed out*Resources remain deployed*'
        Should -Invoke Invoke-ArcBoxAz -Times 0 -ParameterFilter { $Arguments -contains 'delete' }
    }

    It 'surfaces an Azure error immediately rather than polling indefinitely' {
        Mock Invoke-ArcBoxAz { throw 'AuthorizationFailed' }
        { Wait-ArcBoxDeployment -TimeoutMinutes 1 -PollIntervalSeconds 0 } | Should -Throw '*AuthorizationFailed*'
    }
}

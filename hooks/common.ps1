#Requires -Version 7.3

function Invoke-ArcBoxAz {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --subscription $env:AZURE_SUBSCRIPTION_ID --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command 'az $($Arguments -join ' ')' failed (exit code $LASTEXITCODE)."
    }
    return $result
}

function Set-ArcBoxEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    & azd env set "$Name=$Value" --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to save $Name to azd environment '$env:AZURE_ENV_NAME'."
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

function ConvertFrom-ArcBoxSecureString {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Assert-ArcBoxPassword {
    param([Parameter(Mandatory)][string]$Password)

    if ($Password.Length -lt 12 -or $Password.Length -gt 123 -or
        $Password -cnotmatch '[a-z]' -or $Password -cnotmatch '[A-Z]' -or
        $Password -cnotmatch '[0-9]' -or $Password -cnotmatch '[^a-zA-Z0-9]' -or
        $Password -match '[\x00-\x1f\x7f"\\]') {
        throw 'The shared ArcBox password must be 12-123 characters and include lowercase, uppercase, numeric, and special characters; control characters, double quotes, and backslashes are not supported.'
    }
}

function Initialize-ArcBoxPassword {
    param([bool]$Interactive = (-not [Console]::IsInputRedirected -and [Environment]::UserInteractive))

    if (-not [string]::IsNullOrWhiteSpace($env:JS_ARCBOX_PASSWORD)) {
        Assert-ArcBoxPassword -Password $env:JS_ARCBOX_PASSWORD
        return
    }
    if (-not $Interactive -or $env:AZD_NO_PROMPT -eq 'true') {
        throw 'No shared ArcBox password is configured. Set JS_ARCBOX_PASSWORD in the azd environment before provisioning, or run interactively to enter it.'
    }

    $securePassword = Read-Host 'Enter the shared ArcBox password' -AsSecureString
    $secureConfirmation = Read-Host 'Confirm the shared ArcBox password' -AsSecureString
    if ($null -eq $securePassword -or $null -eq $secureConfirmation) {
        throw 'The shared ArcBox password was not provided.'
    }

    $password = ConvertFrom-ArcBoxSecureString -SecureString $securePassword
    $confirmation = ConvertFrom-ArcBoxSecureString -SecureString $secureConfirmation
    if ($password -cne $confirmation) {
        throw 'The shared ArcBox password entries did not match.'
    }
    Assert-ArcBoxPassword -Password $password
    Set-ArcBoxEnvironmentValue -Name JS_ARCBOX_PASSWORD -Value $password
}

function Get-ArcBoxTimeoutMinutes {
    $timeout = 360
    if ($env:JS_ARCBOX_TIMEOUT_MINUTES -and
        (-not [int]::TryParse($env:JS_ARCBOX_TIMEOUT_MINUTES, [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 1440)) {
        throw 'JS_ARCBOX_TIMEOUT_MINUTES must be an integer between 1 and 1440.'
    }
    return $timeout
}

function Select-ArcBoxFlavor {
    param([bool]$Interactive = (-not [Console]::IsInputRedirected -and [Environment]::UserInteractive))

    if (-not $Interactive -or $env:AZD_NO_PROMPT -eq 'true') {
        throw "No ArcBox flavor is configured and interactive input is unavailable or disabled. Run 'azd env set JS_ARCBOX_FLAVOR <ITPro|DevOps|DataOps>' before provisioning."
    }

    Write-Host 'Select an ArcBox scenario:'
    Write-Host '  1. ITPro   - Arc-enabled servers and nested Hyper-V lab'
    Write-Host '  2. DevOps  - Arc-enabled Kubernetes and GitOps lab'
    Write-Host '  3. DataOps - Arc-enabled SQL Managed Instance and DR lab'
    while ($true) {
        $selection = Read-Host 'Select 1-3 or enter the flavor name (Enter or Q to cancel)'
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection.Trim() -eq 'Q') {
            throw "ArcBox flavor selection cancelled. Run 'azd env set JS_ARCBOX_FLAVOR <ITPro|DevOps|DataOps>' before provisioning."
        }
        switch ($selection.Trim()) {
            { $_ -in @('1', 'ITPro') } { return 'ITPro' }
            { $_ -in @('2', 'DevOps') } { return 'DevOps' }
            { $_ -in @('3', 'DataOps') } { return 'DataOps' }
            default { Write-Warning 'Choose 1 (ITPro), 2 (DevOps), or 3 (DataOps).' }
        }
    }
}

function Select-ArcBoxSqlMode {
    param([bool]$Interactive = (-not [Console]::IsInputRedirected -and [Environment]::UserInteractive))

    if (-not $Interactive -or $env:AZD_NO_PROMPT -eq 'true') {
        throw "No ITPro SQL installation mode is configured and interactive input is unavailable or disabled. Run 'azd env set JS_NESTED_SQL_MODE <Developer|Evaluation>' before provisioning."
    }

    Write-Host 'Select the ITPro SQL installation mode (SQL 2016/2019/2025):'
    Write-Host '  1. Developer  (dev)  - Development and testing'
    Write-Host '  2. Evaluation (eval) - 180-day Evaluation trial'
    Write-Host 'SQL 2022 uses JS_SQL_SERVER_EDITION separately. This selection does not enroll ESUs.'
    while ($true) {
        $selection = Read-Host 'Select 1-2 or enter dev or eval (Enter or Q to cancel)'
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection.Trim() -eq 'Q') {
            throw "SQL installation mode selection cancelled. Run 'azd env set JS_NESTED_SQL_MODE <Developer|Evaluation>' before provisioning."
        }
        switch ($selection.Trim()) {
            { $_ -in @('1', 'dev', 'Developer') } { return 'Developer' }
            { $_ -in @('2', 'eval', 'Evaluation') } { return 'Evaluation' }
            default { Write-Warning 'Choose 1 (dev) or 2 (eval).' }
        }
    }
}

function Assert-ArcBoxSqlArtifacts {
    $account = if ([string]::IsNullOrWhiteSpace($env:JS_GITHUB_ACCOUNT)) { 'da5is' } else { $env:JS_GITHUB_ACCOUNT }
    $branch = if ([string]::IsNullOrWhiteSpace($env:JS_GITHUB_BRANCH)) { 'main' } else { $env:JS_GITHUB_BRANCH }
    $baseUrl = "https://raw.githubusercontent.com/$account/azd_arcbox/$branch"
    $projectRoot = Split-Path $PSScriptRoot -Parent
    foreach ($artifact in @(
        'artifacts\Bootstrap.ps1',
        'artifacts\WinGet.ps1',
        'artifacts\dsc\common.dsc.yml',
        'artifacts\tests\Invoke-Test.ps1',
        'artifacts\ArcServersLogonScript.ps1',
        'artifacts\InstallNestedSqlServer.ps1',
        'artifacts\ArcBoxWindows2016.ps1',
        'artifacts\InstallNestedSqlServerUbuntu.sh',
        'artifacts\installArcAgentUbuntu.sh',
        'artifacts\ArcBoxServerManagement.ps1',
        'artifacts\dsc\virtual_machines_itpro.dsc.yml',
        'artifacts\tests\itpro.tests.ps1'
    )) {
        $url = "$baseUrl/$($artifact.Replace('\', '/'))"
        try {
            $published = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        } catch {
            throw "Cannot verify Evaluation artifacts at '$url': $($_.Exception.Message). Publish the matching scripts and set JS_GITHUB_ACCOUNT/JS_GITHUB_BRANCH to that published source before provisioning."
        }
        $localSource = [IO.File]::ReadAllText((Join-Path $projectRoot $artifact)).Replace("`r`n", "`n")
        $publishedSource = ([string]$published.Content).Replace("`r`n", "`n")
        if ($localSource -cne $publishedSource) {
            throw "Evaluation artifact '$artifact' at '$baseUrl' does not match this checkout. Local menus and templates do not update downloaded VM scripts. Publish the matching scripts, or set JS_GITHUB_BRANCH to their published branch before provisioning. Existing Developer instances are not converted by changing this setting."
        }
    }
}

function Initialize-ArcBoxDeployment {
    foreach ($command in @('az', 'azd')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Install $command before provisioning ArcBox."
        }
    }
    foreach ($name in @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Set $name with 'azd env set $name <value>' before provisioning ArcBox."
        }
    }
    if ($env:AZURE_ENV_NAME -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$') {
        throw 'Use an azd environment name of 1-64 letters, numbers, or hyphens, starting with a letter or number.'
    }

    $flavor = $env:JS_ARCBOX_FLAVOR
    if ([string]::IsNullOrWhiteSpace($flavor)) {
        $flavor = Select-ArcBoxFlavor
    }
    if ($flavor -cnotin @('ITPro', 'DevOps', 'DataOps')) {
        throw "JS_ARCBOX_FLAVOR must be ITPro, DevOps, or DataOps."
    }

    if ($flavor -eq 'ITPro') {
        $sqlMode = $env:JS_NESTED_SQL_MODE
        if ([string]::IsNullOrWhiteSpace($sqlMode)) {
            $sqlMode = Select-ArcBoxSqlMode
        }
        if ($sqlMode -eq 'BYOL') {
            throw "BYOL is no longer an installation mode. Run 'azd env set JS_NESTED_SQL_MODE Evaluation'; configure Software Assurance licensing separately after manual edition conversion."
        }
        if ($sqlMode -cnotin @('Developer', 'Evaluation')) {
            throw 'JS_NESTED_SQL_MODE must be Developer or Evaluation.'
        }
        if ($sqlMode -eq 'Evaluation') {
            Assert-ArcBoxSqlArtifacts
        }
    }

    Initialize-ArcBoxPassword

    $null = Invoke-ArcBoxAz -Arguments @('account', 'show', '--output', 'json')
    $resourceGroup = "$($env:AZURE_ENV_NAME)-rg"
    $exists = Invoke-ArcBoxAz -Arguments @('group', 'exists', '--name', $resourceGroup, '--output', 'tsv')
    if ($exists -eq 'true') {
        $deployments = Invoke-ArcBoxAz -Arguments @('deployment', 'group', 'list', '--resource-group', $resourceGroup, '--output', 'json') | ConvertFrom-Json
        $deployment = $deployments | Where-Object name -EQ 'arcbox'
        if (-not $deployment -or $deployment.properties.parameters.resourceTags.value.'azd-env-name' -cne $env:AZURE_ENV_NAME) {
            throw "Resource group '$resourceGroup' already exists without an ArcBox azd deployment. Use a new environment name; azd down deletes the entire resource group."
        }
        if ($deployment.properties.parameters.flavor.value -cne $flavor) {
            throw "Environment '$env:AZURE_ENV_NAME' already deploys $($deployment.properties.parameters.flavor.value). Use a separate environment for $flavor, or run azd down first."
        }
    }
    Set-ArcBoxEnvironmentValue -Name JS_ARCBOX_FLAVOR -Value $flavor
    if ($flavor -eq 'ITPro') {
        Set-ArcBoxEnvironmentValue -Name JS_NESTED_SQL_MODE -Value $sqlMode
    }

    $null = Get-ArcBoxTimeoutMinutes

    $providers = @(
        'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault',
        'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights',
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData',
        'Microsoft.HybridConnectivity', 'Microsoft.PolicyInsights'
    )
    if ($flavor -ne 'ITPro') {
        $providers += @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')
    } else {
        $providers += 'Microsoft.Monitor'
    }
    if ($flavor -eq 'DataOps') {
        $providers += 'Microsoft.ContainerService'
    }
    $registeredProviders = Invoke-ArcBoxAz -Arguments @('provider', 'list', '--output', 'json') | ConvertFrom-Json
    foreach ($provider in $providers) {
        $registration = $registeredProviders | Where-Object namespace -EQ $provider
        if ($registration.registrationState -ne 'Registered') {
            Write-Host "Registering $provider..."
            $null = Invoke-ArcBoxAz -Arguments @('provider', 'register', '--namespace', $provider, '--wait')
        }
    }

    if ($flavor -ne 'ITPro' -and [string]::IsNullOrWhiteSpace($env:JS_SSH_PUBLIC_KEY)) {
        if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            throw 'Install OpenSSH (ssh-keygen), or set JS_SSH_PUBLIC_KEY to an existing RSA public key.'
        }
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $keyDirectory = Join-Path (Join-Path (Join-Path $projectRoot '.azure') $env:AZURE_ENV_NAME) 'ssh'
        $keyPath = Join-Path $keyDirectory 'id_rsa'
        if (-not (Test-Path "$keyPath.pub")) {
            if (Test-Path $keyPath) {
                throw "SSH private key '$keyPath' exists without its public key. Restore the .pub file or set JS_SSH_PUBLIC_KEY; the private key will not be overwritten."
            }
            $null = New-Item -ItemType Directory -Path $keyDirectory -Force
            & ssh-keygen -t rsa -b 4096 -N '' -f $keyPath -C "arcbox-$env:AZURE_ENV_NAME" -q
            if ($LASTEXITCODE -ne 0) {
                throw 'SSH key generation failed.'
            }
        }
        $publicKey = (Get-Content "$keyPath.pub" -Raw).Trim()
        Set-ArcBoxEnvironmentValue -Name JS_SSH_PUBLIC_KEY -Value $publicKey
    }
    if ($flavor -ne 'ITPro' -and $env:JS_SSH_PUBLIC_KEY -notmatch '^ssh-rsa [A-Za-z0-9+/]+={0,3}( .*)?$') {
        throw 'JS_SSH_PUBLIC_KEY must contain an OpenSSH RSA public key, not a path or a private key.'
    }

    if ($flavor -eq 'DataOps') {
        if ([string]::IsNullOrWhiteSpace($env:JS_CUSTOM_LOCATION_RP_ID)) {
            $ids = @(Invoke-ArcBoxAz -Arguments @('ad', 'sp', 'list', '--filter', "displayName eq 'Custom Locations RP'", '--query', '[].id', '--output', 'json') | ConvertFrom-Json)
            if ($ids.Count -ne 1) {
                throw "Expected one 'Custom Locations RP' service principal in the deployment tenant. Ask a tenant administrator for its object ID and set JS_CUSTOM_LOCATION_RP_ID."
            }
            Set-ArcBoxEnvironmentValue -Name JS_CUSTOM_LOCATION_RP_ID -Value $ids[0]
        }
        $objectId = [guid]::Empty
        if (-not [guid]::TryParse($env:JS_CUSTOM_LOCATION_RP_ID, [ref]$objectId) -or $objectId -eq [guid]::Empty) {
            throw 'JS_CUSTOM_LOCATION_RP_ID must be the object ID (GUID) of the Custom Locations RP service principal.'
        }
    }
    Write-Host "Provisioning $flavor in '$resourceGroup'. VM-side setup will run with autologon and azd will wait for its deployment checks."
}

function Wait-ArcBoxDeployment {
    param(
        [ValidateRange(1, 1440)][int]$TimeoutMinutes = 360,
        [ValidateRange(0, 300)][int]$PollIntervalSeconds = 30
    )

    foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Missing $name. Run azd provision or refresh this environment before waiting for deployment."
        }
    }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $previousProgress = $null
    Write-Host "Waiting up to $TimeoutMinutes minutes for the complete ArcBox lab..."
    while ((Get-Date) -lt $deadline) {
        $tags = Invoke-ArcBoxAz -Arguments @('group', 'show', '--name', $env:AZURE_RESOURCE_GROUP, '--query', 'tags', '--output', 'json') | ConvertFrom-Json
        $progress = $tags.DeploymentProgress
        $status = $tags.DeploymentStatus
        if ($progress -ne $previousProgress) {
            Write-Host "ArcBox progress: $progress"
            $previousProgress = $progress
        }
        if ($progress -eq 'Failed') {
            throw "ArcBox deployment checks failed: $status. Inspect C:\ArcBox\Logs on the client VM. Resources remain deployed; use azd down to delete the lab."
        }
        if ($progress -eq 'Completed') {
            if ($status -notmatch '^Tests succeeded: [1-9][0-9]* Tests failed: 0$') {
                throw "ArcBox reported completion without passing deployment checks: '$status'. Inspect C:\ArcBox\Logs on the client VM."
            }
            Write-Host "ArcBox lab is ready. $status"
            return
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out waiting for ArcBox. Last progress: '$previousProgress'. Inspect C:\ArcBox\Logs on the client VM. Resources remain deployed; resume with azd hooks run postprovision, or delete the lab with azd down."
}

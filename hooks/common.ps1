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

    & azd env set $Name $Value --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to save $Name to azd environment '$env:AZURE_ENV_NAME'."
    }
    Set-Item -Path "Env:$Name" -Value $Value
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

    $null = Get-ArcBoxTimeoutMinutes

    $providers = @(
        'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault',
        'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.Insights',
        'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData',
        'Microsoft.HybridConnectivity', 'Microsoft.PolicyInsights'
    )
    if ($flavor -ne 'ITPro') {
        $providers += @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')
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

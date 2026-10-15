targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name. Each environment owns a separate resource group.')
param envName string

@description('Azure region for all ArcBox resources. Verify regional service, VM SKU, availability zone, and quota compatibility for the selected flavor.')
param location string

@allowed([
  'ITPro'
  'DevOps'
  'DataOps'
])
param flavor string = 'ITPro'

param windowsAdminUsername string = 'arcdemo'

@secure()
@minLength(12)
@maxLength(123)
param windowsAdminPassword string

@secure()
param registryPassword string

@secure()
param sshRSAPublicKey string = ''
param customLocationRPOID string = ''
param deployBastion bool = false

@allowed([
  'Basic'
  'Standard'
  'Developer'
])
param bastionSku string = 'Basic'

param githubAccount string = 'da5is'
param githubBranch string = 'main'
param githubUser string = 'Azure'

@allowed([
  'Developer'
  'Standard'
  'Enterprise'
])
param sqlServerEdition string = 'Developer'

@description('SQL 2016/2019/2025 installation mode. Software Assurance licensing and edition conversion are separate manual steps.')
@allowed([
  'Developer'
  'Evaluation'
])
param nestedSqlMode string = 'Developer'

param autoShutdownEnabled bool = true
param autoShutdownTime string = '1800'
param autoShutdownTimezone string = 'UTC'
param enableAzureSpotPricing bool = false
param debugEnabled bool = false

@allowed([
  '1'
  '2'
  '3'
])
param zones string = '1'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${envName}-rg'
  location: location
  tags: {
    'azd-env-name': envName
    Solution: 'jumpstart_arcbox_${toLower(flavor)}'
  }
}

module arcbox 'main.bicep' = {
  name: 'arcbox'
  scope: rg
  params: {
    location: location
    flavor: flavor
    windowsAdminUsername: windowsAdminUsername
    windowsAdminPassword: windowsAdminPassword
    registryPassword: registryPassword
    sshRSAPublicKey: sshRSAPublicKey
    customLocationRPOID: customLocationRPOID
    deployBastion: deployBastion
    bastionSku: bastionSku
    githubAccount: githubAccount
    githubBranch: githubBranch
    githubUser: githubUser
    sqlServerEdition: sqlServerEdition
    nestedSqlMode: nestedSqlMode
    vmAutologon: true
    guid: take(uniqueString(subscription().id, envName), 4)
    resourceTags: {
      'azd-env-name': envName
      Solution: 'jumpstart_arcbox_${toLower(flavor)}'
    }
    autoShutdownEnabled: autoShutdownEnabled
    autoShutdownTime: autoShutdownTime
    autoShutdownTimezone: autoShutdownTimezone
    enableAzureSpotPricing: enableAzureSpotPricing
    debugEnabled: debugEnabled
    zones: zones
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_TENANT_ID string = tenant().tenantId
output ARCBOX_CLIENT_VM_NAME string = 'ArcBox-Client'
output ARCBOX_CLIENT_USERNAME string = flavor == 'DataOps' ? arcbox.outputs.clientVmLogonUserName : windowsAdminUsername

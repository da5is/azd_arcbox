param location string
param namingPrefix string
param workspaceId string
param resourceTags object

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(workspaceId, '/'))
}

resource changeTrackingSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'ChangeTracking(${logWorkspace.name})'
  location: location
  properties: {
    workspaceResourceId: workspaceId
  }
  plan: {
    name: 'ChangeTracking(${logWorkspace.name})'
    product: 'OMSGallery/ChangeTracking'
    publisher: 'Microsoft'
    promotionCode: ''
  }
}

resource inventoryTables 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = [for table in ['ConfigurationChange', 'ConfigurationData']: {
  parent: logWorkspace
  name: table
  dependsOn: [
    changeTrackingSolution
  ]
  properties: {
    schema: {
      name: table
    }
  }
}]

resource metricsWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: '${namingPrefix}-monitor'
  location: location
  tags: resourceTags
  properties: {}
}

resource otelRule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${namingPrefix}-OTel'
  location: location
  tags: resourceTags
  properties: {
    dataSources: {
      performanceCountersOTel: [
        {
          name: 'OtelHostMetrics'
          streams: [
            'Microsoft-OtelPerfMetrics'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'system.filesystem.usage'
            'system.disk.io'
            'system.disk.operation_time'
            'system.disk.operations'
            'system.memory.usage'
            'system.network.io'
            'system.cpu.time'
            'system.network.dropped'
            'system.network.errors'
            'system.uptime'
          ]
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'HostMetrics'
          accountResourceId: metricsWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-OtelPerfMetrics'
        ]
        destinations: [
          'HostMetrics'
        ]
      }
    ]
  }
}

var changeStreams = [
  'Microsoft-ConfigurationChange'
  'Microsoft-ConfigurationChangeV2'
  'Microsoft-ConfigurationData'
]

resource inventoryRule 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${namingPrefix}-Inventory'
  location: location
  tags: resourceTags
  dependsOn: [
    inventoryTables
  ]
  properties: {
    dataSources: {
      extensions: [for os in ['Windows', 'Linux']: {
        name: 'Inventory${os}'
        extensionName: 'ChangeTracking-${os}'
        streams: changeStreams
        extensionSettings: {
          enableFiles: false
          enableRegistry: false
          enableInventory: true
          enableServices: true
          enableSoftware: true
          inventorySettings: {
            inventoryCollectionFrequency: 3600
          }
          servicesSettings: {
            serviceCollectionFrequency: 300
          }
          softwareSettings: {
            softwareCollectionFrequency: 300
          }
        }
      }]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'Inventory'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: changeStreams
        destinations: [
          'Inventory'
        ]
      }
    ]
  }
}

resource logRules 'Microsoft.Insights/dataCollectionRules@2024-03-11' = [for os in ['Windows', 'Linux']: {
  name: '${namingPrefix}-Logs-${os}'
  location: location
  kind: os
  tags: resourceTags
  properties: {
    dataSources: os == 'Windows' ? {
      windowsEventLogs: [
        {
          name: 'SystemAndApplicationErrors'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
          ]
        }
      ]
    } : {
      syslog: [
        {
          name: 'SystemWarnings'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'daemon'
            'syslog'
            'user'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'Logs'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: os == 'Windows' ? ['Microsoft-Event'] : ['Microsoft-Syslog']
        destinations: [
          'Logs'
        ]
      }
    ]
  }
}]

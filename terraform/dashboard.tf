resource "azurerm_application_insights_workbook" "acr_monitoring" {
  name                = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "${var.prefix} ACR Monitoring"
  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      # --- Parameters ---
      {
        type = 9
        content = {
          version = "KqlParameterItem/1.0"
          crossComponentResources = ["{Subscription}"]
          parameters = [
            {
              id          = "p-sub"
              version     = "KqlParameterItem/1.0"
              name        = "Subscription"
              label       = "Subscription"
              type        = 6
              isRequired  = true
              multiSelect = false
              query       = ""
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = true
              }
            },
            {
              id          = "p-acr"
              version     = "KqlParameterItem/1.0"
              name        = "ContainerRegistry"
              label       = "Container Registry"
              type        = 5
              isRequired  = true
              multiSelect = false
              query       = "where type == 'microsoft.containerregistry/registries'\n| project id, name"
              crossComponentResources = ["{Subscription}"]
              queryType    = 1
              resourceType = "microsoft.resourcegraph/resources"
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = false
              }
            },
            {
              id         = "p-time"
              version    = "KqlParameterItem/1.0"
              name       = "TimeRange"
              label      = "Time Range"
              type       = 4
              isRequired = true
              typeSettings = {
                selectableValues = [
                  { durationMs = 3600000, displayText = "Last 1 hour" },
                  { durationMs = 14400000, displayText = "Last 4 hours" },
                  { durationMs = 86400000, displayText = "Last 24 hours" },
                  { durationMs = 604800000, displayText = "Last 7 days" },
                  { durationMs = 2592000000, displayText = "Last 30 days" }
                ]
                allowCustom = true
              }
              value = { durationMs = 86400000 }
            }
          ]
          style    = "pills"
          queryType = 0
        }
        name = "parameters"
      },
      # --- Storage section ---
      {
        type = 1
        content = {
          json = "## Storage"
        }
        name = "section-storage"
      },
      {
        type = 10
        content = {
          chartId = "chart-storage-used"
          version = "MetricsItem/2.0"
          size    = 0
          chartType = 2
          resourceType   = "microsoft.containerregistry/registries"
          metricScope    = 0
          resourceParameter = "ContainerRegistry"
          timeContext     = { durationMs = 0, endTime = null, createdTime = null, isInitialTime = false, grain = 1, useDashboardTimeRange = false }
          timeContextFromParameter = "TimeRange"
          metrics = [
            {
              namespace      = "microsoft.containerregistry/registries"
              metric         = "microsoft.containerregistry/registries-Capacity Metrics-StorageUsed"
              aggregation    = 4
              splitBy        = null
              columnName     = "Storage Used"
            }
          ]
          title      = "Storage Used"
          gridSettings = { rowLimit = 10000 }
        }
        customWidth = "50"
        name        = "chart-storage-used"
      },
      # --- Push/Pull activity section ---
      {
        type = 1
        content = {
          json = "## Push & Pull Activity"
        }
        name = "section-activity"
      },
      {
        type = 10
        content = {
          chartId = "chart-pull-count"
          version = "MetricsItem/2.0"
          size    = 0
          chartType = 2
          resourceType   = "microsoft.containerregistry/registries"
          metricScope    = 0
          resourceParameter = "ContainerRegistry"
          timeContextFromParameter = "TimeRange"
          metrics = [
            {
              namespace   = "microsoft.containerregistry/registries"
              metric      = "microsoft.containerregistry/registries-Traffic Metrics-SuccessfulPullCount"
              aggregation = 1
              columnName  = "Successful Pulls"
            },
            {
              namespace   = "microsoft.containerregistry/registries"
              metric      = "microsoft.containerregistry/registries-Traffic Metrics-TotalPullCount"
              aggregation = 1
              columnName  = "Total Pulls"
            }
          ]
          title = "Pull Operations"
        }
        customWidth = "50"
        name        = "chart-pull-count"
      },
      {
        type = 10
        content = {
          chartId = "chart-push-count"
          version = "MetricsItem/2.0"
          size    = 0
          chartType = 2
          resourceType   = "microsoft.containerregistry/registries"
          metricScope    = 0
          resourceParameter = "ContainerRegistry"
          timeContextFromParameter = "TimeRange"
          metrics = [
            {
              namespace   = "microsoft.containerregistry/registries"
              metric      = "microsoft.containerregistry/registries-Traffic Metrics-SuccessfulPushCount"
              aggregation = 1
              columnName  = "Successful Pushes"
            },
            {
              namespace   = "microsoft.containerregistry/registries"
              metric      = "microsoft.containerregistry/registries-Traffic Metrics-TotalPushCount"
              aggregation = 1
              columnName  = "Total Pushes"
            }
          ]
          title = "Push Operations"
        }
        customWidth = "50"
        name        = "chart-push-count"
      },
      # --- Login events section ---
      {
        type = 1
        content = {
          json = "## Login Events"
        }
        name = "section-login"
      },
      {
        type = 3
        content = {
          version   = "KqlItem/1.0"
          query     = "ContainerRegistryLoginEvents\n| where TimeGenerated {TimeRange}\n| summarize Total = count(), Failed = countif(ResultDescription != \"200\") by bin(TimeGenerated, 1h)\n| render timechart"
          size      = 0
          title     = "Login Attempts (Total vs Failed)"
          queryType = 0
          resourceType = "microsoft.containerregistry/registries"
          crossComponentResources = ["{ContainerRegistry}"]
        }
        customWidth = "50"
        name        = "chart-login-events"
      },
      {
        type = 3
        content = {
          version   = "KqlItem/1.0"
          query     = "ContainerRegistryLoginEvents\n| where TimeGenerated {TimeRange}\n| where ResultDescription != \"200\"\n| summarize FailedAttempts = count() by CallerIpAddress, Identity\n| order by FailedAttempts desc\n| take 20"
          size      = 0
          title     = "Top Failed Login Sources"
          queryType = 0
          resourceType = "microsoft.containerregistry/registries"
          crossComponentResources = ["{ContainerRegistry}"]
        }
        customWidth = "50"
        name        = "table-failed-logins"
      }
    ]
    fallbackResourceIds = []
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}

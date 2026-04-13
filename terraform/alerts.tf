resource "azurerm_monitor_action_group" "main" {
  name                = "${var.prefix}-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = substr(var.prefix, 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_emails
    content {
      name          = "alert-email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }
}

# ---------------------------------------------------------------------------
# Metric alerts — Storage
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "storage_warning" {
  name                = "${var.prefix}-acr-storage-warning"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_registry.main.id]
  description         = "ACR storage exceeds ${var.storage_alert_warning_gb} GiB (80% of Premium included storage)"
  severity            = 2
  frequency           = "PT1H"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.ContainerRegistry/registries"
    metric_name      = "StorageUsed"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.storage_alert_warning_gb * 1073741824 # Convert GiB to bytes
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

resource "azurerm_monitor_metric_alert" "storage_critical" {
  name                = "${var.prefix}-acr-storage-critical"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_registry.main.id]
  description         = "ACR storage exceeds ${var.storage_alert_critical_gb} GiB (95% of Premium included storage)"
  severity            = 1
  frequency           = "PT1H"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.ContainerRegistry/registries"
    metric_name      = "StorageUsed"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.storage_alert_critical_gb * 1073741824
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# ---------------------------------------------------------------------------
# Log-based alerts — Pull and Push failures
# Uses scheduled query rules against ContainerRegistryRepositoryEvents because
# metric alerts cannot compute TotalPullCount - SuccessfulPullCount directly.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pull_failures" {
  name                = "${var.prefix}-acr-pull-failures"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "More than 10 failed image pulls in the last 5 minutes"
  severity            = 2
  enabled             = true

  scopes                    = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency      = "PT5M"
  window_duration           = "PT5M"
  skip_query_validation     = false
  auto_mitigation_enabled   = true
  workspace_alerts_storage_enabled = false

  criteria {
    query = <<-KQL
      ContainerRegistryRepositoryEvents
      | where OperationName == "Pull"
      | where ResultDescription != "200"
      | summarize FailedPulls = count()
    KQL

    time_aggregation_method = "Total"
    operator                = "GreaterThan"
    threshold               = 10
    metric_measure_column   = "FailedPulls"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "push_failures" {
  name                = "${var.prefix}-acr-push-failures"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  description         = "More than 5 failed image pushes in the last 5 minutes"
  severity            = 2
  enabled             = true

  scopes                    = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency      = "PT5M"
  window_duration           = "PT5M"
  skip_query_validation     = false
  auto_mitigation_enabled   = true
  workspace_alerts_storage_enabled = false

  criteria {
    query = <<-KQL
      ContainerRegistryRepositoryEvents
      | where OperationName == "Push"
      | where ResultDescription != "200"
      | summarize FailedPushes = count()
    KQL

    time_aggregation_method = "Total"
    operator                = "GreaterThan"
    threshold               = 5
    metric_measure_column   = "FailedPushes"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }
}

# ---------------------------------------------------------------------------
# Activity log alerts
# ---------------------------------------------------------------------------

# Alert on registry deletion — critical, immediate response needed
resource "azurerm_monitor_activity_log_alert" "acr_deleted" {
  name                = "${var.prefix}-acr-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Azure Container Registry was deleted"

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.ContainerRegistry/registries/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

# Alert on ACR service health events
resource "azurerm_monitor_activity_log_alert" "acr_service_health" {
  name                = "${var.prefix}-acr-service-health"
  resource_group_name = azurerm_resource_group.main.name
  location            = "global"
  scopes              = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}"]
  description         = "Azure Container Registry service health event (incident or maintenance)"

  criteria {
    category = "ServiceHealth"

    service_health {
      services = ["Container Registry"]
      events   = ["Incident", "Maintenance"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

data "azurerm_subscription" "current" {}

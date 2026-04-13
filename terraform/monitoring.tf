resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
}

# Diagnostic setting: route ACR logs and metrics to Log Analytics.
# Log categories: ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents
# Metric category: AllMetrics
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "${var.prefix}-acr-diag"
  target_resource_id         = azurerm_container_registry.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

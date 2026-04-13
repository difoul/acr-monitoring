output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "acr_name" {
  description = "Name of the Azure Container Registry"
  value       = azurerm_container_registry.main.name
}

output "acr_login_server" {
  description = "Login server URL for the ACR (use with docker login)"
  value       = azurerm_container_registry.main.login_server
}

output "acr_id" {
  description = "Resource ID of the ACR"
  value       = azurerm_container_registry.main.id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.main.name
}

output "workbook_id" {
  description = "Resource ID of the monitoring workbook. View in Azure portal: Monitor > Workbooks"
  value       = azurerm_application_insights_workbook.acr_monitoring.id
}

locals {
  # ACR names must be alphanumeric only — strip any dashes from the prefix
  acr_name = "${replace(var.prefix, "-", "")}${random_string.acr_suffix.result}"
}

resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Premium"
  admin_enabled       = false # Use managed identity or service principals, not admin credentials

  zone_redundancy_enabled = true

  georeplications {
    location                = var.secondary_location
    zone_redundancy_enabled = true
  }

  lifecycle {
    #prevent_destroy = true
    ignore_changes  = [tags]
  }
}

# Webhook for push and delete events — useful for CI/CD notifications
resource "azurerm_container_registry_webhook" "push_events" {
  name                = "${replace(var.prefix, "-", "")}pushwebhook"
  resource_group_name = azurerm_resource_group.main.name
  registry_name       = azurerm_container_registry.main.name
  location            = azurerm_resource_group.main.location
  actions             = ["push", "delete"]
  service_uri         = "https://example.com/webhook" # Replace with your actual webhook endpoint
  status              = "disabled"                     # Enable after configuring the endpoint

  lifecycle {
    ignore_changes = [tags]
  }
}

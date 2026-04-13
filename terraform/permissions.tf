# ---------------------------------------------------------------------------
# RBAC Role Assignments
# ---------------------------------------------------------------------------
#
# Minimum roles for a human operator:
#   - Container Registry Contributor and Data Access Configuration Administrator (registry)
#   - Container Registry Repository Writer (registry) — for pushing images
#   - Monitoring Contributor (resource group) — for alert management
#
# Minimum roles for the Terraform service principal:
#   - Contributor (resource group) — creates all resources
#   - Role Based Access Control Administrator (registry) — if assigning data plane roles
#
# To grant image pull access to a compute service (AKS, Container Apps, etc.),
# create a user-assigned managed identity and assign it AcrPull:
#
#   resource "azurerm_user_assigned_identity" "app" {
#     name                = "${var.prefix}-app-identity"
#     location            = azurerm_resource_group.main.location
#     resource_group_name = azurerm_resource_group.main.name
#   }
#
#   resource "azurerm_role_assignment" "acr_pull" {
#     scope                = azurerm_container_registry.main.id
#     role_definition_name = "AcrPull"
#     principal_id         = azurerm_user_assigned_identity.app.principal_id
#   }
#
# ACR prerequisite for managed identity image pulls:
#   az acr config authentication-as-arm update --registry <acr_name> --status enabled
# ---------------------------------------------------------------------------

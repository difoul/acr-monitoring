# Azure Container Registry — Operations Stack

Production-grade monitoring, alerting, geo-replication, and operations documentation for an Azure Container Registry (Premium SKU) deployed to Sweden Central with a geo-replica in West Europe.

## Commands

```bash
# Local development
pip install azure-containerregistry azure-identity
export ACR_LOGIN_SERVER="$(cd terraform && terraform output -raw acr_login_server)"
python scripts/connection_test.py

# Docker build and push
az acr login --name $(cd terraform && terraform output -raw acr_name)
docker build --platform linux/amd64 -t $(cd terraform && terraform output -raw acr_login_server)/myimage:v1 .
docker push $(cd terraform && terraform output -raw acr_login_server)/myimage:v1

# Terraform
cd terraform
terraform init
terraform plan
terraform apply
terraform output
```

## Architecture

| Resource | Terraform name | Notes |
|---|---|---|
| Resource Group | `azurerm_resource_group.main` | Primary RG in Sweden Central |
| Container Registry | `azurerm_container_registry.main` | Premium SKU, zone-redundant (automatic for all tiers in supported regions) |
| Geo-Replication | inline `georeplications` block on ACR | West Europe replica — active-active via Traffic Manager |
| Webhook | `azurerm_container_registry_webhook.push_events` | Push/delete notifications (disabled by default) |
| Log Analytics Workspace | `azurerm_log_analytics_workspace.main` | 30-day retention |
| Diagnostic Setting | `azurerm_monitor_diagnostic_setting.acr` | Routes login + repo events + metrics to LAW |
| Action Group | `azurerm_monitor_action_group.main` | Email notifications |
| Storage Warning Alert | `azurerm_monitor_metric_alert.storage_warning` | > 400 GiB (80% included) |
| Storage Critical Alert | `azurerm_monitor_metric_alert.storage_critical` | > 475 GiB (95% included) |
| Pull Failure Alert | `azurerm_monitor_scheduled_query_rules_alert_v2.pull_failures` | > 10 failed pulls / 5 min |
| Push Failure Alert | `azurerm_monitor_scheduled_query_rules_alert_v2.push_failures` | > 5 failed pushes / 5 min |
| Registry Deleted Alert | `azurerm_monitor_activity_log_alert.acr_deleted` | Sev 0 — critical |
| Service Health Alert | `azurerm_monitor_activity_log_alert.acr_service_health` | Incident + Maintenance |
| Monitoring Workbook | `azurerm_application_insights_workbook.acr_monitoring` | Storage, push/pull, login charts |

## Alerts

| Alert | Metric / Signal | Threshold |
|---|---|---|
| Storage Warning | StorageUsed (Average) | > 400 GiB |
| Storage Critical | StorageUsed (Average) | > 475 GiB |
| Pull Failures | ContainerRegistryRepositoryEvents (Pull, non-200) | > 10 / 5 min |
| Push Failures | ContainerRegistryRepositoryEvents (Push, non-200) | > 5 / 5 min |
| Registry Deleted | Activity Log | Any delete operation — Sev 0 |
| Service Health | Activity Log | Incident or Maintenance — Sev 1 |

## Deployment Flow

1. Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` — fill in `alert_emails`
2. `cd terraform && terraform init`
3. `terraform plan` — review 15 resources
4. `terraform apply`
5. Verify: `terraform output acr_login_server`
6. Test connectivity: `export ACR_LOGIN_SERVER=... && python scripts/connection_test.py`
7. Push a test image: `az acr login --name <name> && docker push ...`
8. Check Azure Monitor > Alerts — all 6 alerts should be active
9. Check Azure Monitor > Workbooks > "acrops ACR Monitoring"
10. Review `docs/operations.md` and share with your team

## Key Quirks

- **Zone redundancy is automatic for all tiers (2025):** The `zoneRedundancy` ARM property may show `Disabled` — this is a legacy artifact. Zone redundancy is active in all supported regions. The `zone_redundancy_enabled = true` Terraform setting is harmless but redundant.
- **`prevent_destroy` is commented out** — intentional for this demo repo. Enable it for production.
- **Soft delete is incompatible with geo-replication** — cannot enable both simultaneously.
- **Pull/push failure alerts use Log Analytics** (KQL-based), not metric alerts — Azure Monitor cannot compute `Total - Successful` in a single metric expression.
- **Activity log alerts require `location = "global"`** on the Terraform resource.
- **Service Health alert must be scoped to the subscription ID** — not the resource group or registry.

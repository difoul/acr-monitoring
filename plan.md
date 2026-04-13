# Operations Plan — Azure Container Registry

## Service Overview
Azure Container Registry (ACR) is a managed, private Docker registry service for storing and managing container images and OCI artifacts. It supports automated image builds via ACR Tasks, geo-replication for multi-region availability, and integrates natively with Azure Kubernetes Service, Container Apps, App Service, and other Azure compute services. ACR is available in three tiers — Basic, Standard, and Premium — each with increasing storage, throughput, and feature sets.

## Demo Application

No demo app needed. ACR is an infrastructure-only service — there is no application hosting layer.

**Connection test script:** `scripts/connection_test.py`
- Language: Python
- SDK: `azure-containerregistry` + `azure-identity`
- Authentication: `DefaultAzureCredential` (supports local Azure CLI auth + managed identity in CI/CD)
- Operations: authenticate to the registry, list repositories, list tags for a repository, verify image manifest exists
- Reads the registry login server from `ACR_LOGIN_SERVER` environment variable or Terraform output

## Hosting Strategy

N/A — This is an infrastructure-only service. No separate compute hosting layer is needed.

**Service access:**
- Endpoint: `<registry_name>.azurecr.io` (available as `azurerm_container_registry.main.login_server`)
- Authentication method: Managed identity (preferred) | Service principal | Azure CLI | Repository-scoped tokens
- Data plane RBAC roles:
  - `Container Registry Repository Reader` (pull) — ABAC-enabled registries
  - `Container Registry Repository Writer` (push/pull) — ABAC-enabled registries
  - `AcrPull` / `AcrPush` — legacy RBAC-only registries

## Scaling

N/A — No replicas or pods to scale.

**Service-level throughput configuration:**

| Setting | Value | Notes |
|---|---|---|
| SKU | Premium | Required for geo-replication, private endpoints, and highest throughput |
| Included storage | 500 GiB | Additional storage billed per-GB |
| Max storage | 100 TiB | Premium limit |
| Max image layer size | 200 GiB | All tiers |
| Webhooks | 500 | Premium limit |
| Private endpoints | 200 | Premium limit |

Note: Throughput (concurrent push/pull operations) scales with SKU tier. Premium provides the highest concurrency. There are no user-configurable throughput knobs — scaling is automatic within tier limits.

## Health Probe Strategy

N/A — No container or pod health probes apply.

**Service health monitoring:**
- Azure Service Health alerts — configure `azurerm_monitor_activity_log_alert` for `ServiceHealth` events affecting `Microsoft.ContainerRegistry` in the target region.
- StorageUsed metric — alert when approaching the tier's included storage or max storage limit.
- Failed pull/push detection — alert when `TotalPullCount - SuccessfulPullCount > 0` or `TotalPushCount - SuccessfulPushCount > 0` to detect authentication failures or throttling.
- Connection test — the `scripts/connection_test.py` script can be run on a schedule from a CI/CD pipeline or Azure Automation to verify end-to-end connectivity.

## Image Registry

N/A — ACR **is** the image registry. No external registry dependency.

**Connection test script:** `scripts/connection_test.py`
- Language: Python
- Authentication: `DefaultAzureCredential` (supports local Azure CLI auth + managed identity in production)
- Reads connection details from environment variables or Terraform output

## Terraform Stack

Complete list of every resource to create, in dependency order:

| Resource | Terraform type | Purpose |
|---|---|---|
| Resource Group | `azurerm_resource_group` | Primary resource group |
| Log Analytics Workspace | `azurerm_log_analytics_workspace` | Central log store |
| Container Registry | `azurerm_container_registry` | The ACR instance (Premium SKU) |
| Diagnostic Setting | `azurerm_monitor_diagnostic_setting` | Route ACR logs and metrics to LAW |
| Geo-Replication | `azurerm_container_registry_replication` | Secondary region replica (Premium) |
| Webhook | `azurerm_container_registry_webhook` | Notify on push/delete events |
| Private DNS Zone | `azurerm_private_dns_zone` | `privatelink.azurecr.io` |
| Private DNS Zone VNet Link | `azurerm_private_dns_zone_virtual_network_link` | Link DNS zone to VNet |
| Private Endpoint | `azurerm_private_endpoint` | Private network access (Premium) |
| Alert — Storage Used | `azurerm_monitor_metric_alert` | Alert when storage exceeds threshold |
| Alert — Failed Pulls | `azurerm_monitor_metric_alert` | Alert on pull failures |
| Alert — Failed Pushes | `azurerm_monitor_metric_alert` | Alert on push failures |
| Alert — Activity Log (Delete) | `azurerm_monitor_activity_log_alert` | Alert on registry deletion |
| Alert — Service Health | `azurerm_monitor_activity_log_alert` | ACR service health events |
| Action Group | `azurerm_monitor_action_group` | Email/webhook notification target |

Total: **15 resources**

## Monitoring

**Visualization strategy:** Azure Monitor Workbooks (default, no extra cost)

> ACR's metric surface is small (7 metrics). A single Workbook with storage trend, push/pull counts over time, and failed operation ratio is sufficient.

**Prometheus / Azure Monitor Workspace:** Not needed — Log Analytics + metric alerts are sufficient for ACR monitoring.

**Log Analytics cost optimization:** All tables at Analytics tier (default). ACR log volume is typically low (login events + repository events). No need for Basic/Auxiliary tier unless the registry has extremely high push/pull throughput.

**Metrics (namespace: `Microsoft.ContainerRegistry/registries`):**

| Metric | Name in REST API | Aggregation | What it measures | Notes |
|---|---|---|---|---|
| Storage Used | `StorageUsed` | Average | Total storage consumed by all repositories | Dimension: `Geolocation`; sampled hourly (PT1H) |
| Successful Pull Count | `SuccessfulPullCount` | Total | Number of successful image pulls | Sampled per minute |
| Successful Push Count | `SuccessfulPushCount` | Total | Number of successful image pushes | Sampled per minute |
| Total Pull Count | `TotalPullCount` | Total | All image pull attempts (success + failure) | Compare with SuccessfulPullCount for failure rate |
| Total Push Count | `TotalPushCount` | Total | All image push attempts (success + failure) | Compare with SuccessfulPushCount for failure rate |
| Agent Pool CPU Time | `AgentPoolCPUTime` | Total | CPU seconds consumed by ACR Tasks agent pools | Only relevant if using ACR Tasks |
| Run Duration | `RunDuration` | Total | Duration of ACR Task runs in milliseconds | Only relevant if using ACR Tasks |

**Log tables (via Diagnostic Settings):**

| Table | What it captures |
|---|---|
| `ContainerRegistryLoginEvents` | Authentication events — identity, IP address, success/failure |
| `ContainerRegistryRepositoryEvents` | Push, pull, untag, delete, purge operations per repository |
| `AzureActivity` | Control plane operations (create, update, delete registry) |

**Useful KQL queries:**

```kql
// Failed login attempts in last 24h
ContainerRegistryLoginEvents
| where TimeGenerated > ago(24h)
| where ResultType != "200"
| summarize FailedAttempts = count() by CallerIpAddress, Identity
| order by FailedAttempts desc

// Image pull/push activity by repository in last 7d
ContainerRegistryRepositoryEvents
| where TimeGenerated > ago(7d)
| summarize Pulls = countif(OperationName == "Pull"), Pushes = countif(OperationName == "Push") by Repository
| order by Pulls desc

// Storage trend over last 30d (from routed metrics)
AzureMetrics
| where ResourceProvider == "MICROSOFT.CONTAINERREGISTRY"
| where MetricName == "StorageUsed"
| summarize AvgStorageGB = avg(Average) / (1024*1024*1024) by bin(TimeGenerated, 1d)
| render timechart
```

## Alerting

| Alert name | Metric / Signal | Aggregation | Condition | Severity | Rationale |
|---|---|---|---|---|---|
| ACR Storage High | `StorageUsed` | Average | > 400 GiB (80% of Premium included) | Sev 2 (Warning) | Approaching included storage limit — overage charges begin |
| ACR Storage Critical | `StorageUsed` | Average | > 475 GiB (95% of Premium included) | Sev 1 (Error) | Near limit — action required to purge or increase budget |
| ACR Pull Failures | `TotalPullCount - SuccessfulPullCount` | Total over 5 min | > 10 | Sev 2 (Warning) | Indicates auth failures, throttling, or network issues |
| ACR Push Failures | `TotalPushCount - SuccessfulPushCount` | Total over 5 min | > 5 | Sev 2 (Warning) | CI/CD pipeline push failures |
| ACR Deleted | Activity Log | N/A | Operation: `Delete ContainerRegistry` | Sev 0 (Critical) | Registry deletion — immediate response needed |
| ACR Service Health | Activity Log (Service Health) | N/A | Service: `Container Registry`, event types: Incident, Maintenance | Sev 1 (Error) | Azure platform issue affecting ACR |

Note: The pull/push failure alerts use a computed metric (`Total - Successful`). In Terraform, this requires `azurerm_monitor_metric_alert` with a `dynamic_criteria` block or a Log Analytics-based alert using `ContainerRegistryRepositoryEvents` where `ResultType != "200"`. The Log Analytics approach is more flexible and recommended.

## High Availability

| Setting | Recommended value | Rationale |
|---|---|---|
| SKU | Premium | Required for geo-replication, private endpoints, highest throughput |
| Zone redundancy | Automatic (all tiers in supported regions) | Enabled by default — no configuration needed. Cannot be disabled. |
| Geo-replication | Enabled (at least one secondary region) | Protects against regional outages; reduces pull latency for distributed deployments |
| Soft delete policy | Enabled, 7-day retention | Recovers accidentally deleted images. Currently in preview. |
| `prevent_destroy` | `true` on `azurerm_container_registry` | Prevents accidental Terraform-driven deletion |

Notes:
- Zone redundancy is now **automatic for all tiers** in supported regions. The `zoneRedundancy` ARM property may still show `Disabled` — this is a legacy artifact and does not reflect actual behavior.
- Zone redundancy applies to the data plane (push/pull). ACR Tasks do **not** support availability zones.
- Soft delete policy **cannot** be enabled simultaneously with the retention policy, and is **not supported** with geo-replication.

## Backup & Recovery

**Strategy:** ACR has no native backup service. Resilience comes from geo-replication (Premium tier) and soft delete (preview). For critical images, use `az acr import` to copy images to a secondary registry or export to external storage.

**Detection:**
- Activity Log alert on `Delete ContainerRegistry` operation
- Activity Log alert on `Delete ContainerRegistryRepository` operation
- Soft delete policy catches accidental image deletions within the retention window

**Recovery runbook:**
- Scenario A: Image accidentally deleted, registry intact — if soft delete is enabled, restore via `az acr manifest restore` within the retention window (1–90 days, default 7). If soft delete is not enabled, re-push from CI/CD pipeline or import from a backup registry.
- Scenario B: Registry deleted — **all images are permanently lost**. ACR has no service-level soft delete or recovery window for the registry resource itself (soft delete only protects images *within* an existing registry). If Terraform state is intact, `terraform apply` recreates an empty registry; all images must be re-pushed from CI/CD or imported from a backup registry. Estimated time: 10–30 min for infrastructure, hours for large image catalogs.
- Scenario C: Registry deleted, Terraform state also lost — same outcome as Scenario B (images are gone), but you must also recreate the Terraform configuration from scratch or from version control. `terraform import` can adopt an existing Azure resource into state, but since the registry was deleted there is nothing to import. Full redeploy required. Estimated time: 30+ min.
- Scenario D: Bad configuration (e.g., network rules blocking access) — revert Terraform to last known good state, `terraform apply`. Estimated time: < 5 min.

**Key takeaway:** The only protection against registry deletion is preventive — use `lifecycle { prevent_destroy = true }` in Terraform and/or an Azure resource lock (`CanNotDelete`). For image-level protection, enable the soft delete policy (preview) or maintain a secondary registry via `az acr import`.

## Disaster Recovery

**Architecture model:** Active-active (via geo-replication)

> ACR geo-replication is natively active-active — all replicas can serve push and pull operations independently. Azure Traffic Manager routes requests to the nearest healthy replica automatically.

**Global routing service:** Azure Traffic Manager (built-in to ACR geo-replication)
**Rationale:** ACR uses Traffic Manager internally for all geo-replicated registries. No external routing configuration is needed — it's managed by the platform.

**Regions:**
- Primary (home region): East US
- Secondary (geo-replica): West US 2

**RTO / RPO targets:**

| Scenario | RTO | RPO | Notes |
|---|---|---|---|
| Region failure (automatic failover) | ~0 min (seamless) | ~0–15 min | Traffic Manager reroutes; recent writes in failed zone may be lost (async replication) |
| Home region failure | ~0 min (data plane) | ~0–15 min | Push/pull continues via replicas. Control plane unavailable — can't modify registry config. |
| Manual failover | N/A | N/A | Not needed — failover is automatic |
| Failback after recovery | Automatic | ~0 | Traffic Manager rebalances; data re-syncs with eventual consistency |

**Cost estimate (additional monthly):**

| Component | Estimated cost |
|---|---|
| Premium SKU (primary) | ~$50/month |
| Geo-replica (secondary, Premium pricing) | ~$50/month |
| Egress charges (cross-region replication) | ~$5–20/month (depends on image volume) |
| Log Analytics Workspace | ~$5/month (low volume) |
| **Total** | **~$110–125/month** |

**DR simulation:**
ACR geo-replication failover cannot be directly simulated (no `/dr/degrade` equivalent). However, you can test by temporarily disabling a geo-replica via the portal or CLI, verifying that operations continue from the remaining replica, then re-enabling it:
```bash
# Temporarily remove secondary replica (simulates region outage)
az acr replication delete --registry <registry> --name <secondary-region>
# Verify pulls still work
docker pull <registry>.azurecr.io/<image>:<tag>
# Re-add the replica
az acr replication create --registry <registry> --location <secondary-region>
```

**Recovery runbook:**
- Scenario D: Region failure — Traffic Manager automatically routes to healthy replica. Verify: `az acr replication list --registry <name>` shows healthy replicas.
- Scenario E: DR test — remove a replica, verify operations continue, re-add the replica.
- Scenario F: Home region failure — data plane continues. Control plane operations (config changes, tasks) are unavailable until home region recovers. No manual action needed for data plane.

## Permissions

### Azure RBAC — roles required to deploy

| Role | Scope | Why needed |
|---|---|---|
| `Container Registry Contributor and Data Access Configuration Administrator` | Registry | Create, configure, manage registry settings (SKU, network rules, geo-replication, diagnostics) |
| `Container Registry Repository Writer` | Registry | Push images during CI/CD (ABAC-enabled registries) |
| `Container Registry Repository Reader` | Registry | Pull images from compute services (ABAC-enabled registries) |
| `AcrPush` | Registry | Push images (legacy RBAC-only registries) |
| `AcrPull` | Registry | Pull images (legacy RBAC-only registries) |
| `Container Registry Tasks Contributor` | Registry | Manage ACR Tasks (if using automated builds) |
| `Monitoring Contributor` | Resource Group | Create and manage metric alerts and diagnostic settings |

### Terraform service principal — minimum permissions
- `Contributor` on the resource group (creates registry, diagnostic settings, alerts, private endpoints)
- `Private DNS Zone Contributor` on the private DNS zone resource group (if DNS zone is in a separate RG)
- `Network Contributor` on the VNet/subnet (for private endpoint creation)
- If using ABAC repository permissions, the SP also needs `Role Based Access Control Administrator` on the registry to assign data plane roles.

## Known Quirks
- **Registry name constraints:** Must be alphanumeric (no dashes or underscores), 5–50 characters, globally unique across all of Azure. Terraform: use `${replace(var.prefix, "-", "")}acr` to strip dashes.
- **`zoneRedundancy` property is misleading:** The ARM property may show `Disabled` even though zone redundancy is active. This is a legacy artifact — zone redundancy is automatic in supported regions for all tiers.
- **`admin_enabled` should be `false`:** Use managed identity or service principals for authentication. Admin credentials are a shared secret and not recommended for production.
- **`ignore_changes` on tags:** Azure may modify tags after creation. Add `lifecycle { ignore_changes = [tags] }` to prevent drift.
- **`ignore_changes` on `georeplications` nested block does not work:** Known Terraform provider issue (#22530). If geo-replication changes cause unwanted diffs, manage replications via separate `azurerm_container_registry_replication` resources instead of the inline `georeplications` block.
- **`prevent_destroy` candidate:** `azurerm_container_registry` should use `lifecycle { prevent_destroy = true }` — registry deletion destroys all images irreversibly.
- **Private endpoint deletion order:** Cannot delete a registry that has private endpoints attached. Must delete all private endpoints first, then delete the registry.
- **Soft delete vs retention policy:** Cannot enable both simultaneously. Choose one. Soft delete is the more flexible option (allows restore within retention window).
- **Soft delete + geo-replication incompatibility:** Soft delete policy is not supported on geo-replicated registries (as of preview). This is a significant limitation for production registries.
- **Shared layers and storage accounting:** Deleting an image does not free storage proportional to the image size — shared layers referenced by other images are retained. Storage reduction after purge may be less than expected.
- **Private endpoint DNS requires two records:** Both the registry endpoint (`<name>.azurecr.io`) and the data endpoint (`<name>.<region>.data.azurecr.io`) must have A records in the private DNS zone. Missing the data endpoint record causes push/pull failures even though login succeeds.
- **Activity log alerts need `location = "Global"`:** Activity log alerts (registry deletion, service health) must have their `scopes` set to the subscription and `location` explicitly set or defaulted correctly.
- **ACR Tasks bound to home region:** Tasks always execute in the home region and don't support availability zones or geo-replicas. If the home region is down, tasks don't run.

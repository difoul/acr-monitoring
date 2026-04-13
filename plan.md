# Operations Plan — Azure Container Registry

## Service Overview
Azure Container Registry (ACR) is a managed, private Docker registry service for storing and managing container images and OCI artifacts. It supports automated image builds via ACR Tasks, geo-replication for multi-region availability, and integrates natively with Azure Kubernetes Service, Container Apps, App Service, and other Azure compute services. ACR is available in three tiers — Basic, Standard, and Premium — each with increasing storage, throughput, and feature sets. The Premium tier is required for geo-replication, private endpoints, and highest throughput.

**Architecture components:**
- **Control plane** — centralized management in the home region (registry config, auth, replication policies)
- **Data plane** — distributed, handles push/pull across regions and availability zones
- **Storage layer** — content-addressable Azure Storage with deduplication, encryption-at-rest, and built-in replication

## Demo Application

No demo app needed. ACR is an infrastructure-only service — there is no application hosting layer.

**Connection test script:** `scripts/connection_test.py`
- Language: Python
- SDK: `azure-containerregistry` + `azure-identity`
- Authentication: `DefaultAzureCredential` (supports local Azure CLI auth + managed identity in CI/CD)
- Operations: authenticate to the registry, list repositories, list tags for a repository, verify image manifest exists
- Reads the registry login server from `ACR_LOGIN_SERVER` environment variable

## Workload Profile Strategy

N/A — ACR is infrastructure-only. No Container Apps environment needed.

## Image Registry Authentication

N/A — ACR **is** the image registry. No external registry dependency.

**For compute services pulling from this ACR (AKS, Container Apps, etc.):**

**Approach:** Managed identity (recommended) — avoids storing admin credentials as secrets.

**Resources required (per consuming service):**
- `azurerm_user_assigned_identity` — one per consuming service/region
- `azurerm_role_assignment` — `AcrPull` or `Container Registry Repository Reader` (ABAC-enabled registries) scoped to the ACR
- ACR ARM token auth must be enabled: `az acr config authentication-as-arm update --registry <name> --status enabled`

**Role assignment mode:** ACR supports two modes:
- **RBAC Registry + ABAC Repository Permissions** — fine-grained per-repository access via Entra ABAC conditions. Recommended for new registries. Use `Container Registry Repository Reader` / `Container Registry Repository Writer` roles.
- **RBAC Registry Permissions** — standard RBAC without per-repository scoping. Use `AcrPull` / `AcrPush` roles (legacy).

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
- Azure Service Health alerts — configure `azurerm_monitor_activity_log_alert` for `ServiceHealth` events affecting `Microsoft.ContainerRegistry` in the target region
- `StorageUsed` metric — alert when approaching the tier's included storage or max storage limit
- Failed pull/push detection — alert when `TotalPullCount - SuccessfulPullCount > 0` or `TotalPushCount - SuccessfulPushCount > 0` to detect authentication failures or throttling
- Connection test — `scripts/connection_test.py` can be run on a schedule from a CI/CD pipeline to verify end-to-end connectivity

## Terraform Stack

Complete list of every resource to create, in dependency order:

| Resource | Terraform type | Purpose |
|---|---|---|
| Resource Group | `azurerm_resource_group` | Primary resource group in Sweden Central |
| Random suffix | `random_string` | Globally unique ACR name suffix |
| Log Analytics Workspace | `azurerm_log_analytics_workspace` | Central log store for all ACR telemetry |
| Container Registry | `azurerm_container_registry` | Premium SKU, zone-redundant by default, admin disabled |
| Geo-Replication | inline `georeplications` block on ACR | West Europe replica (Premium tier) |
| Webhook | `azurerm_container_registry_webhook` | Push/delete event notifications (disabled by default) |
| Diagnostic Setting | `azurerm_monitor_diagnostic_setting` | Routes login events, repo events, and metrics to LAW |
| Action Group | `azurerm_monitor_action_group` | Email notification target |
| Storage Warning Alert | `azurerm_monitor_metric_alert` | StorageUsed > 400 GiB (80% of 500 GiB included) |
| Storage Critical Alert | `azurerm_monitor_metric_alert` | StorageUsed > 475 GiB (95% of 500 GiB included) |
| Pull Failures Alert | `azurerm_monitor_scheduled_query_rules_alert_v2` | > 10 non-200 pulls / 5 min via KQL on LAW |
| Push Failures Alert | `azurerm_monitor_scheduled_query_rules_alert_v2` | > 5 non-200 pushes / 5 min via KQL on LAW |
| Registry Deleted Alert | `azurerm_monitor_activity_log_alert` | Sev 0 — any registry delete operation |
| Service Health Alert | `azurerm_monitor_activity_log_alert` | ACR Incident or Maintenance events |
| Monitoring Workbook | `azurerm_application_insights_workbook` | Storage, push/pull, login charts |

Total: **15 resources** (plus 1 `data` source for subscription ID)

## Monitoring

**Visualization strategy:** Azure Monitor Workbooks (default, no extra cost)

> ACR's metric surface is small (7 metrics). A single Workbook with storage trend, push/pull counts over time, and failed operation ratio is sufficient.

**Prometheus / Azure Monitor Workspace:** Not needed — Log Analytics + metric alerts are sufficient for ACR monitoring.

**Log Analytics cost optimization:** All tables at Analytics tier (default). ACR log volume is typically low (login events + repository events). No need for Basic/Auxiliary tier unless the registry has extremely high push/pull throughput.

**Metrics (namespace: `Microsoft.ContainerRegistry/registries`):**

| Metric | Name in REST API | Unit | Aggregation | Dimensions | Time Grain | What it measures | Notes |
|---|---|---|---|---|---|---|---|
| Storage used | `StorageUsed` | Bytes | Average | `Geolocation` | PT1H | Total storage consumed by all repositories | Shared layers counted once; sampled hourly |
| Successful Pull Count | `SuccessfulPullCount` | Count | Total | none | PT1M | Number of successful image pulls | Compare with TotalPullCount for failure rate |
| Successful Push Count | `SuccessfulPushCount` | Count | Total | none | PT1M | Number of successful image pushes | Compare with TotalPushCount for failure rate |
| Total Pull Count | `TotalPullCount` | Count | Total | none | PT1M | All image pull attempts (success + failure) | Gap vs SuccessfulPullCount = failures |
| Total Push Count | `TotalPushCount` | Count | Total | none | PT1M | All image push attempts (success + failure) | Gap vs SuccessfulPushCount = failures |
| AgentPool CPU Time | `AgentPoolCPUTime` | Seconds | Total | none | PT1M | CPU seconds consumed by ACR Tasks | Only relevant if using ACR Tasks |
| Run Duration | `RunDuration` | MilliSeconds | Total | none | PT1M | Duration of ACR Task runs | Only relevant if using ACR Tasks |

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
| where ResultDescription != "200"
| summarize FailedAttempts = count() by CallerIpAddress, Identity
| order by FailedAttempts desc

// Image pull/push activity by repository in last 7d
ContainerRegistryRepositoryEvents
| where TimeGenerated > ago(7d)
| summarize Pulls = countif(OperationName == "Pull"), Pushes = countif(OperationName == "Push") by Repository
| order by Pulls desc

// Repository event errors (4xx/5xx)
ContainerRegistryRepositoryEvents
| where ResultDescription contains "40" or ResultDescription contains "50"
| project TimeGenerated, OperationName, Repository, Tag, ResultDescription

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
| ACR Storage Warning | `StorageUsed` metric | Average | > 400 GiB (80% of Premium included) | Sev 2 (Warning) | Approaching included storage limit — overage charges begin |
| ACR Storage Critical | `StorageUsed` metric | Average | > 475 GiB (95% of Premium included) | Sev 1 (Error) | Near limit — action required to purge or increase budget |
| ACR Pull Failures | KQL on `ContainerRegistryRepositoryEvents` | Total over 5 min | > 10 non-200 pulls | Sev 2 (Warning) | Auth failures, throttling, or network issues |
| ACR Push Failures | KQL on `ContainerRegistryRepositoryEvents` | Total over 5 min | > 5 non-200 pushes | Sev 2 (Warning) | CI/CD pipeline push failures |
| ACR Deleted | Activity Log | N/A | Operation: `Microsoft.ContainerRegistry/registries/delete` | Sev 0 (Critical) | Registry deletion — immediate response; all images lost |
| ACR Service Health | Activity Log (ServiceHealth) | N/A | Service: `Container Registry`, events: Incident, Maintenance | Sev 1 (Error) | Azure platform issue affecting ACR |

**Alert scoping notes:**
- Storage and pull/push metric alerts: scoped to `azurerm_container_registry.main.id`
- Pull/push failure alerts use Log Analytics-based query rules (scoped to LAW) — metric alerts cannot compute `Total - Successful` directly
- Registry Deleted alert: scoped to resource group ID (catches the registry resource)
- Service Health alert: scoped to subscription ID; `location = "global"` required on the resource

## High Availability

| Setting | Recommended value | Rationale |
|---|---|---|
| SKU | Premium | Required for geo-replication, private endpoints, highest throughput |
| Zone redundancy | Automatic (all tiers in supported regions) | **Now enabled by default for ALL tiers at no extra cost** (updated 2025). Cannot be disabled. The `zoneRedundancy` ARM property may show `Disabled` — legacy artifact, does not reflect actual behavior. |
| Geo-replication | Enabled (West Europe secondary) | Protects against regional outages; reduces pull latency for distributed deployments; active-active via Traffic Manager |
| `prevent_destroy` | `true` on `azurerm_container_registry` | **Currently commented out in acr.tf — must be enabled for production.** Registry deletion is permanent and irreversible. |
| Soft delete policy | Enabled only if NOT geo-replicated | **Incompatible with geo-replication** (preview limitation). Cannot enable both simultaneously. |
| `admin_enabled` | `false` | Use managed identity or service principals instead of shared admin credentials |

**Zone redundancy update (2025):** Zone redundancy is now the default for all ACR tiers in regions that support availability zones. Setting `zone_redundancy_enabled = true` in Terraform is harmless but redundant — safe to leave in place. Existing registries were retroactively upgraded.

**Geo-replication behavior:**
- Active-active — all replicas serve push and pull independently
- Traffic Manager routes to nearest healthy replica automatically
- Replication is asynchronous with eventual consistency (typically completes within minutes)
- Control plane operations (config changes, ACR Tasks) require the home region — unavailable during home region outage

## Backup & Recovery

**Strategy:** ACR has no native backup service. Resilience comes from geo-replication (Premium tier) and soft delete (preview, not compatible with geo-replication). For critical images, use `az acr import` to copy images to a secondary registry.

**Detection:**
- Activity Log alert on `Microsoft.ContainerRegistry/registries/delete` (Sev 0)
- Soft delete policy catches accidental image deletions within the retention window (1–90 days, default 7 days) — **only viable when geo-replication is disabled**

**Recovery runbook:**
- Scenario A: Image accidentally deleted, registry intact — if soft delete enabled (non-geo-replicated): `az acr manifest restore -r <registry> -n <repo>:<tag>`. If not: re-push from CI/CD or `az acr import`.
- Scenario B: Registry deleted, Terraform state intact — **all images permanently lost**. Run `terraform apply` to recreate empty registry (10–30 min). Re-push all images from CI/CD or backup registries (hours for large catalogs).
- Scenario C: Registry deleted, Terraform state also lost — same image loss as B. Recreate Terraform config from version control, run `terraform apply`. Full redeploy required (30+ min).
- Scenario D: Bad configuration (network rules blocking access) — revert Terraform to last known good state, `terraform apply` (< 5 min).

**Prevention:**
- Enable `lifecycle { prevent_destroy = true }` on `azurerm_container_registry` (currently commented out in `acr.tf`)
- Apply Azure resource lock: `az lock create --name no-delete --resource-group <rg> --resource-name <acr> --resource-type Microsoft.ContainerRegistry/registries --lock-type CanNotDelete`

## Disaster Recovery

**Architecture model:** Active-active (via geo-replication)

> ACR geo-replication is natively active-active — all replicas serve push and pull operations independently. Azure Traffic Manager routes requests to the nearest healthy replica automatically.

**Global routing service:** Azure Traffic Manager (built-in to ACR geo-replication)
**Rationale:** ACR uses Traffic Manager internally for all geo-replicated registries. No external routing configuration is needed — it is managed by the platform.

**Regions:**
- Primary (home region): Sweden Central
- Secondary (geo-replica): West Europe

**RTO / RPO targets:**

| Scenario | RTO | RPO | Notes |
|---|---|---|---|
| Zone failure (automatic) | ~seconds | < 15 min | Platform auto-reroutes to healthy zones; recent writes may be lost |
| Region failure (automatic failover) | ~1–2 min | < 15 min | Traffic Manager reroutes; async replication means recent writes may be lost |
| Home region failure | ~1–2 min (data plane) | < 15 min | Push/pull continues via replicas; control plane unavailable |
| Failback after recovery | Automatic | ~0 | Traffic Manager rebalances; data re-syncs with eventual consistency |

**DR simulation:**
ACR geo-replication failover cannot be directly simulated. Simulate by temporarily disabling a geo-replica:
```bash
# 1. Temporarily disable routing to secondary replica
az acr replication update --registry <registry> --name westeurope --region-endpoint-enabled false

# 2. Verify pulls still work (Traffic Manager routes to primary)
docker pull <registry>.azurecr.io/<image>:<tag>

# 3. Re-enable the replica
az acr replication update --registry <registry> --name westeurope --region-endpoint-enabled true

# 4. Verify replication status
az acr replication list --registry <registry> --output table
```

**Cost estimate (additional monthly):**

| Component | Estimated cost |
|---|---|
| Premium SKU (primary, Sweden Central) | ~$50/month |
| Geo-replica (West Europe, Premium pricing) | ~$50/month |
| Egress charges (cross-region replication) | ~$5–20/month (depends on image volume) |
| Log Analytics Workspace (30-day retention, low volume) | ~$5/month |
| **Total** | **~$110–125/month** |

**Recovery runbook:**
- Scenario D: Region failure — Traffic Manager automatically routes to healthy replica. Verify: `az acr replication list --registry <name> --output table` — confirm remaining replica shows `Succeeded` provisioning state.
- Scenario E: DR test — disable replica routing via `az acr replication update --region-endpoint-enabled false`, verify operations continue from remaining replica, re-enable.
- Scenario F: Home region failure — data plane continues. Control plane operations (config changes, tasks) unavailable until home region recovers. No manual action needed for data plane.
- Scenario G: ACR outage (all regions) — existing containers using cached images unaffected; new pulls blocked. Switch image references to a backup registry if one exists.

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

| Role | Scope | Purpose |
|---|---|---|
| `Contributor` | Resource Group | Create all resources in the stack |
| `Role Based Access Control Administrator` | Registry | Assign data plane roles if using ABAC repository permissions |

### Soft delete permissions (if enabled)

| Permission | Purpose |
|---|---|
| `Microsoft.ContainerRegistry/registries/deleted/read` | List soft-deleted artifacts |
| `Microsoft.ContainerRegistry/registries/deleted/restore/action` | Restore soft-deleted artifacts |

## Known Quirks

- **Zone redundancy is now automatic for ALL tiers** (updated 2025): The `zoneRedundancy` ARM property may show `Disabled` — this is a legacy artifact. Zone redundancy is active in all supported regions regardless. Setting `zone_redundancy_enabled = true` in Terraform is harmless but no longer necessary.
- **`prevent_destroy` is commented out** in `acr.tf` — this is a production gap. Registry deletion is permanent and irreversible. Enable `lifecycle { prevent_destroy = true }` before deploying to production.
- **Registry name constraints:** Must be alphanumeric (no dashes or underscores), 5–50 characters, globally unique across all of Azure. Terraform: use `${replace(var.prefix, "-", "")}${random_string.acr_suffix.result}` to strip dashes.
- **`admin_enabled` should be `false`:** Use managed identity or service principals. Admin credentials are a shared secret and not recommended for production.
- **`ignore_changes` on tags:** Azure may modify tags after creation. Add `lifecycle { ignore_changes = [tags] }` to prevent drift.
- **`ignore_changes` on `georeplications` nested block does not work** (known Terraform provider issue). If geo-replication changes cause unwanted diffs, manage replications via separate `azurerm_container_registry_replication` resources instead of the inline `georeplications` block.
- **Soft delete + geo-replication incompatibility:** Soft delete policy is **not supported** on geo-replicated registries (as of preview). Cannot enable both.
- **Soft delete vs retention policy:** Cannot enable both simultaneously. Choose one.
- **Activity log alerts need `location = "global"`** for the resource. Already correctly set in this repo.
- **Service Health alert scope:** Must be the subscription ID (not resource group or resource ID). Already correctly set in this repo.
- **Private endpoint DNS requires two A records:** Both `<name>.azurecr.io` and `<name>.<region>.data.azurecr.io` must have A records in the private DNS zone. Missing the data endpoint causes push/pull failures even though login succeeds.
- **ACR Tasks bound to home region:** Tasks always execute in the home region and don't support AZs or geo-replicas. If home region is down, tasks don't run.
- **Shared layers and storage accounting:** Deleting an image does not free storage proportional to the image size — shared layers referenced by other images are retained. Storage reduction after purge may be less than expected.
- **`StorageUsed` metric is sampled hourly (PT1H)** — not suitable for sub-hour alerting. Keep storage alert frequency at PT1H.
- **Workbook uses hardcoded GUID** for the `azurerm_application_insights_workbook` `name` attribute — replace with a `random_uuid` resource in production to avoid conflicts on redeploy.
- **Pull/push failure alerts use Log Analytics** (not metric alerts) because Azure Monitor cannot directly compute `Total - Successful` in a metric alert expression. KQL-based scheduled query rules on the LAW are the correct approach.

# Azure Container Registry — Operations Guide

## Before You Start

### Required resources

This stack deploys the following core resources via Terraform:

- **Azure Container Registry** (Premium SKU) — the image registry
- **Log Analytics Workspace** — central log and metric store
- **Diagnostic Setting** — routes ACR login events, repository events, and metrics to LAW

Ensure the diagnostic setting is active before relying on log-based alerts. Without it, `ContainerRegistryLoginEvents` and `ContainerRegistryRepositoryEvents` tables in LAW will be empty and alerts will never fire.

### Authentication setup

ACR supports multiple authentication methods. For production:

1. **Managed identity (recommended):** Create a user-assigned managed identity, assign `AcrPull` role scoped to the registry. Enable ARM token auth on the ACR:
   ```bash
   az acr config authentication-as-arm update --registry <acr_name> --status enabled
   ```
2. **Service principal:** Create an App Registration, assign `AcrPull` or `AcrPush` role.
3. **Azure CLI (development):** `az acr login --name <acr_name>` — uses your Azure AD identity.

Admin credentials (`admin_enabled = true`) are **not recommended** for production. They are a shared secret with no audit trail.

### RBAC model

ACR supports two role assignment modes:
- **RBAC Registry + ABAC Repository Permissions** — fine-grained, per-repository access control via Microsoft Entra ABAC conditions. Recommended for new registries.
- **RBAC Registry Permissions** — standard RBAC assignments without per-repository scoping.

Check your registry's mode: Azure portal > Registry > Settings > Properties > "Role assignment permissions mode".

---

## Stack Overview

| Component | Purpose |
|---|---|
| Azure Container Registry (Premium) | Store and manage container images and OCI artifacts |
| Geo-replication (secondary region) | Multi-region availability, reduced pull latency |
| Log Analytics Workspace | Central log store for login events, repository events, metrics |
| Diagnostic Setting | Routes ACR telemetry to LAW |
| Metric Alerts (2) | Storage warning (80%) and critical (95%) thresholds |
| Log-Based Alerts (2) | Pull and push failure detection |
| Activity Log Alerts (2) | Registry deletion and service health events |
| Monitoring Workbook | Visual dashboard for storage, push/pull activity, login events |

---

## How to Monitor

### Key metrics

| Metric | Namespace | Aggregation | What to watch for |
|---|---|---|---|
| `StorageUsed` | `Microsoft.ContainerRegistry/registries` | Average | Approaching 500 GiB (Premium included) — overage charges begin |
| `SuccessfulPullCount` | `Microsoft.ContainerRegistry/registries` | Total | Baseline activity; sudden drops may indicate network issues |
| `TotalPullCount` | `Microsoft.ContainerRegistry/registries` | Total | Compare with SuccessfulPullCount — gap indicates failures |
| `SuccessfulPushCount` | `Microsoft.ContainerRegistry/registries` | Total | CI/CD pipeline health indicator |
| `TotalPushCount` | `Microsoft.ContainerRegistry/registries` | Total | Compare with SuccessfulPushCount for push failure rate |

### Portal navigation

1. **Metrics explorer:** Azure portal > Container Registry > Monitoring > Metrics
2. **Logs (KQL):** Azure portal > Log Analytics Workspace > Logs
3. **Workbook:** Azure portal > Monitor > Workbooks > select "<prefix> ACR Monitoring"

### Useful KQL queries

**Failed login attempts in last 24h:**
```kql
ContainerRegistryLoginEvents
| where TimeGenerated > ago(24h)
| where ResultType != "200"
| summarize FailedAttempts = count() by CallerIpAddress, Identity
| order by FailedAttempts desc
```

**Image pull/push activity by repository in last 7d:**
```kql
ContainerRegistryRepositoryEvents
| where TimeGenerated > ago(7d)
| summarize Pulls = countif(OperationName == "Pull"), Pushes = countif(OperationName == "Push") by Repository
| order by Pulls desc
```

**Storage trend over last 30d:**
```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.CONTAINERREGISTRY"
| where MetricName == "StorageUsed"
| summarize AvgStorageGB = avg(Average) / (1024*1024*1024) by bin(TimeGenerated, 1d)
| render timechart
```

---

## How to Set Up Alerting

### Alert inventory

| Alert | Signal | Condition | Severity | Response |
|---|---|---|---|---|
| ACR Storage Warning | `StorageUsed` metric | > 400 GiB | Sev 2 | Review image retention; purge unused images |
| ACR Storage Critical | `StorageUsed` metric | > 475 GiB | Sev 1 | Immediate purge or budget increase |
| ACR Pull Failures | Log query (non-200 pulls) | > 10 in 5 min | Sev 2 | Check auth config, network rules, throttling |
| ACR Push Failures | Log query (non-200 pushes) | > 5 in 5 min | Sev 2 | Check CI/CD pipeline credentials and network |
| ACR Deleted | Activity Log | Registry delete operation | Sev 0 | Immediate investigation — all images are lost |
| ACR Service Health | Activity Log | Incident or Maintenance | Sev 1 | Monitor Azure Service Health for updates |

### Response playbook

**Storage alerts:**
1. Check current usage: `az acr show-usage --name <acr_name> --output table`
2. Identify large repositories: `az acr repository list --name <acr_name> --output table`
3. Purge untagged manifests: `az acr run --cmd "acr purge --filter '<repo>:.*' --untagged --ago 30d" --registry <acr_name> /dev/null`
4. Review retention policy or soft delete settings.

**Pull/push failure alerts:**
1. Check recent login events in LAW for authentication failures.
2. Verify network rules haven't blocked the source IP: `az acr network-rule list --name <acr_name>`
3. Check if the registry is being throttled (high concurrent operations).
4. Verify managed identity or service principal credentials are valid.

**Registry deleted alert:**
1. This is a **Sev 0 critical** event. All images are permanently lost.
2. If Terraform state is intact: `terraform apply` recreates an empty registry.
3. Re-push all images from CI/CD pipelines or backup registries.
4. Investigate who and why via Activity Log.

---

## High Availability

| Setting | Value | Notes |
|---|---|---|
| SKU | Premium | Required for geo-replication and highest throughput |
| Zone redundancy | Automatic | Enabled by default for all tiers in supported regions; cannot be disabled |
| Geo-replication | Secondary region configured | Active-active — all replicas serve push and pull |

### Zone redundancy details

- Zone redundancy is **automatic** in supported regions — no configuration needed.
- The `zoneRedundancy` property in portal/API may show `Disabled` — this is a legacy artifact and does not reflect actual behavior.
- Zone redundancy applies to the **data plane** (push/pull). ACR Tasks do **not** support availability zones.

### Geo-replication details

- ACR geo-replication is natively **active-active** — all replicas can serve push and pull independently.
- Azure Traffic Manager routes requests to the nearest healthy replica automatically.
- Data replication is **asynchronous with eventual consistency** — typically completes within minutes.
- **Control plane** operations (registry config changes, tasks) run in the **home region** only. If the home region is down, config changes are unavailable but data plane operations continue.

---

## Backup & Recovery

### Strategy

ACR has **no native backup service**. Resilience comes from:
- **Geo-replication** (Premium tier) — survives regional outages
- **Soft delete policy** (preview) — recovers accidentally deleted images within a retention window
- **`az acr import`** — copies images to a backup registry

### Detection

- Activity Log alert on registry deletion (Sev 0)
- Soft delete policy catches image deletions within the retention window (default 7 days)

### Recovery runbook

**Scenario A — Image accidentally deleted, registry intact:**
1. If soft delete is enabled: `az acr manifest restore -r <registry> -n <repo>:<tag>`
2. If not: re-push from CI/CD pipeline or `az acr import --name <registry> --source <backup_registry>.azurecr.io/<repo>:<tag>`

**Scenario B — Registry deleted, Terraform state intact:**
1. All images are **permanently lost** — ACR has no recovery window for the registry resource itself.
2. Run `terraform apply` to recreate an empty registry (10-30 min).
3. Re-push all images from CI/CD or backup registries (hours for large catalogs).

**Scenario C — Registry deleted, Terraform state lost:**
1. Same image loss as Scenario B.
2. Recreate Terraform config from version control and run `terraform apply`.
3. Re-push all images.

**Scenario D — Bad configuration (network rules blocking access):**
1. Revert Terraform to last known good state.
2. Run `terraform apply` (< 5 min).

**Prevention:**
- Use `lifecycle { prevent_destroy = true }` in Terraform.
- Apply an Azure resource lock: `az lock create --name no-delete --resource-group <rg> --resource-name <acr> --resource-type Microsoft.ContainerRegistry/registries --lock-type CanNotDelete`

For region-level failure, see the **Disaster Recovery** section.

---

## Disaster Recovery

### Architecture

ACR geo-replication provides built-in multi-region resilience:

```
                    +-----------------------+
                    |   Azure Traffic Mgr   |
                    |  (built-in to ACR)    |
                    +----------+------------+
                               |
                    Routes to nearest healthy replica
                               |
              +----------------+----------------+
              |                                 |
   +----------v----------+          +-----------v---------+
   |   Sweden Central    |          |    West Europe      |
   |   (home region)     |          |   (geo-replica)     |
   |                     |   async  |                     |
   |  ACR Primary        +--------->  ACR Replica         |
   |  Control plane      |  replic. |  Data plane only    |
   |  + Data plane       |          |                     |
   +---------------------+          +---------------------+
```

### Model

**Active-active** — all replicas can serve push and pull operations independently. No manual failover needed.

### RTO / RPO

| Scenario | RTO | RPO | Notes |
|---|---|---|---|
| Region failure | ~0 min | ~0-15 min | Traffic Manager reroutes; recent writes may be lost (async replication) |
| Home region failure | ~0 min (data plane) | ~0-15 min | Push/pull continues; control plane unavailable |
| Failback | Automatic | ~0 | Traffic Manager rebalances after recovery |

### DR simulation

You can test failover by temporarily removing a geo-replica:

```bash
# 1. Remove secondary replica (simulates region outage)
az acr replication delete --registry <registry> --name westeurope

# 2. Verify pulls still work from the remaining region
docker pull <registry>.azurecr.io/<image>:<tag>

# 3. Re-add the replica
az acr replication create --registry <registry> --location westeurope

# 4. Verify replication status
az acr replication list --registry <registry> --output table
```

### Recovery runbook

**Scenario D — Region failure (automatic failover):**
1. Check Azure Service Health for the affected region.
2. Verify that pulls/pushes are succeeding (Traffic Manager routes to healthy replica).
3. Run `az acr replication list --registry <name>` to confirm which replicas are healthy.
4. No manual action needed for data plane operations.

**Scenario E — Home region failure:**
1. Data plane (push/pull) continues via geo-replicas — no action needed.
2. Control plane operations (config changes, tasks) are **unavailable** until the home region recovers.
3. Do not attempt to reconfigure the registry during the outage.

**Scenario F — ACR outage (all regions):**
1. Detect via Azure Service Health.
2. Existing containers using cached images are unaffected.
3. New deployments requiring image pulls will fail.
4. If you maintain a backup registry: switch image references to the backup.

---

## Permissions

### Human operator roles

| Role | Scope | Purpose |
|---|---|---|
| `Container Registry Contributor and Data Access Configuration Administrator` | Registry | Manage registry settings, SKU, networking, geo-replication |
| `Container Registry Repository Writer` | Registry | Push images (ABAC-enabled registries) |
| `Container Registry Repository Reader` | Registry | Pull images (ABAC-enabled registries) |
| `AcrPush` | Registry | Push images (legacy RBAC-only registries) |
| `AcrPull` | Registry | Pull images (legacy RBAC-only registries) |
| `Monitoring Contributor` | Resource Group | Manage alerts and diagnostic settings |

### Terraform service principal

| Role | Scope | Purpose |
|---|---|---|
| `Contributor` | Resource Group | Create all resources in the stack |
| `Role Based Access Control Administrator` | Registry | Assign data plane roles (if using ABAC) |

### Managed identity for image pull (compute services)

To grant a compute service (AKS, Container Apps, etc.) access to pull images:

1. Create a user-assigned managed identity.
2. Assign `AcrPull` role scoped to the registry.
3. Enable ARM token auth: `az acr config authentication-as-arm update --registry <acr_name> --status enabled`
4. Reference the identity in the compute service's configuration.

---

## Quick Reference Commands

```bash
# Login to ACR
az acr login --name <acr_name>

# List repositories
az acr repository list --name <acr_name> --output table

# Show storage usage
az acr show-usage --name <acr_name> --output table

# List geo-replicas
az acr replication list --registry <acr_name> --output table

# Purge untagged images older than 30 days
az acr run --cmd "acr purge --filter '<repo>:.*' --untagged --ago 30d" \
  --registry <acr_name> /dev/null

# Delete a specific image tag
az acr repository delete --name <acr_name> --image <repo>:<tag> --yes

# Check registry health
az acr check-health --name <acr_name>

# View recent login events (via Azure CLI + LAW)
az monitor log-analytics query --workspace <law_id> \
  --analytics-query "ContainerRegistryLoginEvents | where TimeGenerated > ago(1h) | take 20"

# Apply a resource lock to prevent deletion
az lock create --name no-delete \
  --resource-group <rg> \
  --resource-name <acr_name> \
  --resource-type Microsoft.ContainerRegistry/registries \
  --lock-type CanNotDelete

# Run the connection test
export ACR_LOGIN_SERVER="<acr_name>.azurecr.io"
python scripts/connection_test.py
```

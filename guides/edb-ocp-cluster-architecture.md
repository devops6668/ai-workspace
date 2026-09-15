# EDB On-Premises Cluster Architecture
## Active/Passive Deployment on OCP with Portworx

---

## Table of Contents

- [1. Overview](#1-overview)
- [2. Physical Topology](#2-physical-topology)
- [3. Storage Architecture](#3-storage-architecture)
- [4. EDB Deployment Model](#4-edb-deployment-model)
- [5. Data Replication Strategy](#5-data-replication-strategy)
- [6. Failover Architecture](#6-failover-architecture)
- [7. Recovery Procedures](#7-recovery-procedures)
- [8. Cross-Cluster Connectivity (Submariner)](#8-cross-cluster-connectivity-submariner)
- [9. Storage-Level Failover (Portworx Metro)](#9-storage-level-failover-portworx-metro)
- [10. Backup Restore (PureStorage Object Store)](#10-backup-restore-purestorage-object-store)
- [11. Multiple EDB Instances](#11-multiple-edb-instances)
- [12. Monitoring](#12-monitoring)
- [13. Summary](#13-summary)

---

## 1. Overview

### Requirements

| # | Requirement | Detail |
|---|-------------|--------|
| 1 | 2 OCP Clusters | Each cluster has 3 nodes |
| 2 | NVMe Storage | Each node has NVMe disk attached |
| 3 | Portworx | Install on both clusters, providing persistent volume |
| 4 | 6-Node Storage Pool | All 6 nodes form single Portworx storage pool |
| 5 | Volume Replication | Replicas from Cluster A to Cluster B |
| 6 | EDB | EnterpriseDB using Portworx persistent volume |
| 7 | Active/Passive | EDB deployment model is Active/Passive |
| 8 | Multiple Clusters | Multiple EDB clusters deployed on OCP |

### Version Requirements

| Component | Minimum Version |
|-----------|----------------|
| OCP | 4.14+ |
| CloudNativePG | 1.24+ |
| Portworx Enterprise | 3.0+ |
| Stork | 24.2.0+ |
| Submariner | 0.17+ |
| PostgreSQL | 16+ |

### Design Principles

```
1. PVs must live on the same cluster as the EDB instances
2. 2 Replicas per volume: 1 Local + 1 Remote
3. EDB streaming replication for DB consistency
4. Portworx for storage HA and cross-site DR
5. Failover PVs are already local (no migration needed)
```

---

## 2. Physical Topology

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                        │
│   SITE A (OCP Cluster A)                    SITE B (OCP Cluster B)                     │
│   ═══════════════════════                     ══════════════════════                   │
│                                                                                        │
│   ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐  │ 
│   │  Node A-1 │ │  Node A-2 │ │  Node A-3 │ │  Node B-1 │ │  Node B-2 │ │  Node B-3 │  │ 
│   │  NVMe     │ │  NVMe     │ │  NVMe     │ │  NVMe     │ │  NVMe     │ │  NVMe     │  │
│   │  PX Daemon│ │  PX Daemon│ │  PX Daemon│ │  PX Daemon│ │  PX Daemon│ │  PX Daemon│  │
│   └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘  │
│         │             │             │             │             │             │        │
│         └─────────────┴─────────────┘             └─────────────┴─────────────┘        │
│                       │                                         │                      │
│                       └──────────────────┬──────────────────────┘                      │
│                                          │                                             │
│                         ┌────────────────┴────────────────┐                            │
│                         │     PORTWORX CLUSTER (6)        │                            │
│                         │    Single Unified Storage Pool  │                            │
│                         └─────────────────────────────────┘                            │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘

Key Points:
• 1 Portworx cluster spanning all 6 nodes across both OCP clusters
• All NVMe disks in single unified storage pool
• PX daemons run on all 6 nodes
• PVs accessible from any node (both OCP clusters)
• OCP nodes at same level (horizontal layout)
```

---

## 3. Storage Architecture

### 3.1 Portworx Storage Pool

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                         │
│                    PORTWORX STORAGE POOL                                                │
│                    (6 Nodes, Unified Cluster)                                           │
│                                                                                         │
│   SITE A                                      SITE B                                    │
│   ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐   │
│   │  Node A-1 │ │  Node A-2 │ │  Node A-3 │ │  Node B-1 │ │  Node B-2 │ │  Node B-3 │   │ 
│   │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │   │
│   └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘   │
│         │             │             │             │             │             │         │
│         └─────────────┴─────────────┘             └─────────────┴─────────────┘         │
│                       │                                         │                       │
│                       ▼                                         ▼                       │ 
│              ┌─────────────────┐                    ┌─────────────────┐                 │   
│              │  Active EDB PV  │                    │ Standby EDB PV  │                 │    
│              │                 │                    │                 │                 │
│              │  Replica 1: A-1 │◄──── Sync ───────► │  Replica 1: B-1 │                 │
│              │  (Local NVMe)   │                    │  (Local NVMe)   │                 │
│              │                 │                    │                 │                 │
│              │  Replica 2: B-2 │◄──── Sync ───────► │  Replica 2: A-2 │                 │
│              │  (Remote NVMe)  │                    │  (Remote NVMe)  │                 │
│              └─────────────────┘                    └─────────────────┘                 │    
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Volume Replication Rules

| Active Site | Replica 1 (Local) | Replica 2 (Remote) | Purpose |
|-------------|-------------------|-------------------|---------|
| Site A | Node A-1, A-2, A-3 | Node B-1, B-2, B-3 | Active PVs |
| Site B | Node B-1, B-2, B-3 | Node A-1, A-2, A-3 | Standby PVs |

**Key Design Point:**
- Active PVs: Primary chunk on Site A, secondary on Site B
- Standby PVs: Primary chunk on Site B, secondary on Site A
- Both sites always have a local copy for fast access
- Remote copy provides DR if site goes down

---

## 4. EDB Deployment Model

### 4.1 Active/Passive Architecture

> **⚠️ EDB Official Recommendation:**
> This architecture follows the EDB Postgres AI for CloudNativePG "Single Availability Zone Kubernetes Clusters" pattern.
> - 2 data centers = only viable option for Active/Passive
> - Each operator manages only its local cluster
> - Cross-cluster failover must be manual or via GitOps (CNPG cannot auto-failover across clusters)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SITE A (ACTIVE)                          SITE B (PASSIVE/DR)              │
│   ═══════════════                          ═══════════════════              │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐     │
│   │                     OCP Cluster A (Primary Cluster)              │     │
│   │                                                                   │     │
│   │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐           │     │
│   │   │   Primary   │    │  Replica-1  │    │  Replica-2  │           │     │
│   │   │    (RW)     │    │    (RO)     │    │    (RO)     │           │     │
│   │   └─────────────┘    └─────────────┘    └─────────────┘           │     │
│   │                                                                   │     │
│   └───────────────────────────────────────────────────────────────────┘     │
│          │                              │                                   │
│          │                     EDB Streaming Replication                    │
│          │                     (Async WAL Shipping)                         │
│          │                              │                                   │
│          ▼                              ▼                                   │
│   ┌───────────────────────────────────────────────────────────────────┐     │
│   │                  OCP Cluster B (Replica Cluster)                 │     │
│   │                                                                   │     │
│   │   ┌─────────────────┐    ┌─────────────┐    ┌─────────────┐       │     │
│   │   │    Designated   │    │  Replica-1  │    │  Replica-2  │       │     │
│   │   │    Primary      │    │    (RO)     │    │    (RO)     │       │     │
│   │   │    (RO)         │    └─────────────┘    └─────────────┘       │     │
│   │   │    (Standby)    │                                             │     │
│   │   └─────────────────┘                                             │     │
│   │                                                                   │     │
│   │   ⚠️  Designated Primary can be promoted to Primary anytime       │     │
│   │                                                                   │     │
│   └───────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│   Key Points:                                                               │
│   • Site B is a "Replica Cluster" (not just a single standby)              │
│   • Designated Primary = standby server with promotion capability          │
│   • Can have multiple replicas for read scaling                            │
│   • Promotion transforms Replica Cluster → Primary Cluster                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Instance Allocation

| Site | Role | Instances | PV Location | StorageClass |
|------|------|-----------|-------------|--------------|
| Site A | Active (Primary Cluster) | 3 (Primary + 2 Replicas) | Site A NVMe | portworx-edb-site-a |
| Site B | Passive (Replica Cluster) | 3 (Designated Primary + 2 Replicas) | Site B NVMe | portworx-edb-site-b |

> **Why 3 instances on Site B?**
> - EDB recommends Replica Cluster should have same architecture as Primary
> - After promotion, Site B can immediately handle read traffic with 2 replicas
> - Can scale up replicas after promotion if needed

### 4.3 Distributed Topology (EDB Recommended)

> **⚠️ EDB Official Pattern:**
> For DR/HA across Kubernetes clusters, use "Distributed Topology"
> - Both clusters define `externalClusters` pointing to each other
> - Both clusters define `.spec.replica` stanza with `primary`, `source`
> - Controlled switchover via demotionToken → promotionToken

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   DISTRIBUTED TOPOLOGY (EDB Recommended)                                   │
│   ══════════════════════════════════════                                    │
│                                                                             │
│   Site A (Primary Cluster)               Site B (Replica Cluster)          │
│   ┌──────────────────────────┐           ┌──────────────────────────┐      │
│   │                          │           │                          │      │
│   │  .spec.replica:          │           │  .spec.replica:          │      │
│   │    primary: cluster-site-a│           │    primary: cluster-site-a│     │
│   │    source: cluster-site-b│           │    source: cluster-site-a│      │
│   │                          │           │                          │      │
│   │  externalClusters:       │           │  externalClusters:       │      │
│   │    - cluster-site-b      │           │    - cluster-site-a      │      │
│   │                          │           │                          │      │
│   │  Role: PRIMARY           │           │  Role: REPLICA           │      │
│   │  (can accept writes)     │           │  (continuous recovery)   │      │
│   └──────────────┬───────────┘           └──────────────┬───────────┘      │
│                  │                                      │                   │
│                  │         EDB Streaming Replication    │                   │
│                  │         + WAL Archive (Hybrid)       │                   │
│                  └──────────────────────────────────────┘                   │
│                                                                             │
│   Key Points:                                                               │
│   • Both clusters define .spec.replica stanza                             │
│   • primary field determines who is current primary                       │
│   • source field determines where WAL comes from                         │
│   • Controlled switchover via demotionToken → promotionToken             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.4 CNPG Distributed Topology YAML

```yaml
# Site A - Primary Cluster
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-a
  namespace: edb-app1-production
spec:
  instances: 3
  # Add resources (CPU/memory requests and limits) for production

  # .spec.replica stanza for PRIMARY cluster
  # primary = self (this cluster is the primary)
  # source = Site B (for failback when Site B becomes primary)
  replica:
    primary: cluster-site-a    # Self is primary
    source: cluster-site-b     # WAL source for failback

  # Primary configuration
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
      max_wal_senders: "10"

  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a

  # Backup configuration
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-a/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
    scheduledBackup:
      - name: site-a-backup
        schedule: "0 */5 * * * *"
        backupOwnerReference: self

  # External clusters definition (points to Site B)
  externalClusters:
    - name: cluster-site-b
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-b  # Site B's backup location
          serverName: cluster-site-b
```

```yaml
# Site B - Replica Cluster
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-b
  namespace: edb-app1-production
spec:
  instances: 3
  # Add resources (CPU/memory requests and limits) for production

  # .spec.replica stanza for REPLICA cluster
  # primary = Site A (this cluster is replica, Site A is primary)
  # source = Site A (WAL comes from Site A)
  replica:
    primary: cluster-site-a    # Site A is primary
    source: cluster-site-a     # WAL comes from Site A

  # Designated Primary receives WAL from Site A
  bootstrap:
    pg_basebackup:
      source: cluster-site-a

  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"

  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b

  # Backup configuration (symmetric - same as Site A)
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-b/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
    scheduledBackup:
      - name: site-b-backup
        schedule: "0 */5 * * * *"
        backupOwnerReference: self

  # External clusters definition (points back to Site A)
  externalClusters:
    - name: cluster-site-a
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-a  # Site A's backup location
          serverName: cluster-site-a
```

### 4.5 Controlled Switchover (Two-Step Process)

> **⚠️ EDB Important:** Controlled switchover is a TWO-STEP process:
> 1. Demote Primary to Replica (generates demotionToken)
> 2. Promote Replica to Primary (using promotionToken)
> 
> Must apply primary and promotionToken simultaneously. If promotionToken is omitted → failover (data loss risk).

```bash
# ============================================================
# CONTROLLED SWITCHOVER (EDB Recommended Method)
# ============================================================

# Step 1: DEMOTE Primary on Site A
# Change .spec.replica.primary to Site B
oc config use-context site-a
oc patch cluster cluster-site-a -n edb-app1-production --type merge -p '
{
  "spec": {
    "replica": {
      "primary": "cluster-site-b",
      "source": "cluster-site-b"
    }
  }
}'

# Wait for Site A to become standby
oc get cluster cluster-site-a -n edb-app1-production -o jsonpath='{.status.phase}'
# Should return: "Cluster in healthy state"

# Step 2: Get demotionToken from Site A
TOKEN=$(oc get cluster cluster-site-a -n edb-app1-production -o jsonpath='{.status.demotionToken}')
echo "Demotion Token: $TOKEN"

# Step 3: PROMOTE Site B using promotionToken
# Must apply primary and promotionToken SIMULTANEOUSLY
oc config use-context site-b
oc patch cluster cluster-site-b -n edb-app1-production --type merge -p "
{
  \"spec\": {
    \"replica\": {
      \"primary\": \"cluster-site-b\",
      \"promotionToken\": \"$TOKEN\",
      \"source\": \"cluster-site-a\"
    }
  }
}"

# Step 4: Verify Site B is now primary
oc exec -it cluster-site-b-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: f (not in recovery = primary)

# Step 5: Update Submariner ServiceExport
cat <<EOF | oc apply -f -
apiVersion: submariner.io/v1alpha1
kind: ServiceExport
metadata:
  name: cluster-site-b-rw
  namespace: edb-app1-production
EOF

# Step 6: Delete old export on Site A
oc config use-context site-a
oc delete serviceexport cluster-site-a-rw -n edb-app1-production --ignore-not-found
```

### 4.6 Failover vs Switchover

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   FAILOVER vs SWITCHOVER (EDB Definition)                                  │
│   ═══════════════════════════════════════                                   │
│                                                                             │
│   SWITCHOVER (Controlled):                                                  │
│   ─────────────────────────                                                 │
│   • Planned operation (maintenance window)                                 │
│   • Two-step process: Demote → Promote                                    │
│   • Uses promotionToken (zero data loss)                                   │
│   • Former primary becomes replica (no re-clone needed)                   │
│                                                                             │
│   FAILOVER (Unexpected):                                                    │
│   ───────────────────────                                                   │
│   • Unplanned operation (site failure)                                     │
│   • One-step process: Promote only                                         │
│   • No promotionToken (potential data loss)                                │
│   • Former primary must be re-cloned when it returns                      │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐      │
│   │                                                                 │      │
│   │   SWITCHOVER:                                                   │      │
│   │   Site A (Primary) ──demote──► Site A (Replica)                │      │
│   │                                                                 │      │
│   │   Site B (Replica) ──promote──► Site B (Primary)               │      │
│   │                                                                 │      │
│   │   Result: Site A becomes replica of Site B (no re-clone)       │      │
│   │                                                                 │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐      │
│   │                                                                 │      │
│   │   FAILOVER:                                                     │      │
│   │   Site A (Primary) ──CRASH──► Site A (DOWN)                    │      │
│   │                                                                 │      │
│   │   Site B (Replica) ──promote──► Site B (Primary)               │      │
│   │                                                                 │      │
│   │   Result: Site A must be RE-CLONED from Site B when it returns │      │
│   │                                                                 │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.7 Hybrid Replication (Streaming + WAL Archive)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   HYBRID REPLICATION (EDB Recommended)                                     │
│   ════════════════════════════════════                                      │
│                                                                             │
│   Primary Method: Streaming Replication                                    │
│   • Direct connection between clusters (via Submariner)                   │
│   • Lower latency, near real-time                                          │
│   • Requires network connectivity                                          │
│                                                                             │
│   Fallback Method: WAL Archive (Object Store)                              │
│   • WAL files stored in PureStorage S3                                     │
│   • Used when streaming fails                                              │
│   • Higher latency (depends on backup interval)                           │
│                                                                             │
│   Hybrid Approach:                                                         │
│   • PostgreSQL automatically switches between methods                     │
│   • Streaming fails → falls back to WAL archive                           │
│   • Streaming recovers → switches back automatically                      │
│                                                                             │
│   Benefits:                                                                │
│   • High availability (multiple replication paths)                        │
│   • Defense in depth (not single point of failure)                        │
│   • Automatic failover between methods                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.8 Three Replication Methods (Complete Configuration)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3 REPLICATION METHODS - WHEN TO USE                                      │
│   ═══════════════════════════════════                                       │
│                                                                             │
│   Method 1: Streaming Only                                                 │
│   ─────────────────────────                                                │
│   • Network: Submariner connected                                         │
│   • S3: Not required                                                       │
│   • RPO: 5-30 seconds (streaming lag)                                     │
│   • Use case: Development/Test, non-critical workloads                    │
│   • Risk: WAL loss if streaming fails                                     │
│                                                                             │
│   Method 2: WAL Archive Only                                               │
│   ───────────────────────────                                              │
│   • Network: Not required (uses S3)                                       │
│   • S3: Required (PureStorage)                                            │
│   • RPO: 5-15 minutes (archive interval)                                  │
│   • Use case: Network restrictions, PITR requirement                      │
│   • Risk: Higher RPO than streaming                                       │
│                                                                             │
│   Method 3: Hybrid (Recommended)                                           │
│   ────────────────────────────────                                         │
│   • Network: Submariner connected (for streaming)                         │
│   • S3: Required (for WAL archive fallback)                               │
│   • RPO: 5-30 seconds (streaming) + 5-15 min (archive fallback)          │
│   • Use case: Production, highest availability                            │
│   • Risk: Lowest (multiple paths)                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Method | Needs Submariner? | Needs S3? | RPO | Use Case |
|--------|-------------------|-----------|-----|----------|
| Streaming Only | ✓ | ✗ | 5-30s | Development/Test |
| WAL Archive Only | ✗ | ✓ | 5-15 min | Network restrictions |
| Hybrid | ✓ | ✓ | 5-30s + fallback | **Production (Recommended)** |

#### Method 1: Streaming Only

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STREAMING ONLY                                                           │
│   ═══════════════                                                          │
│                                                                             │
│   Site A (Primary)                 Site B (Replica)                        │
│   ┌──────────────────┐            ┌──────────────────┐                    │
│   │ EDB Primary      │──stream──► │ EDB Replica      │                    │
│   │                  │   (WAL)    │                  │                    │
│   └──────────────────┘            └──────────────────┘                    │
│            │                              │                               │
│            └──────────────┬───────────────┘                               │
│                           │                                                │
│                    Submariner (IPsec)                                     │
│                                                                             │
│   ✅ Simple configuration                                                  │
│   ✅ Low latency (real-time)                                              │
│   ❌ No fallback if streaming fails                                       │
│   ❌ WAL loss risk                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Method 2: WAL Archive Only

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   WAL ARCHIVE ONLY                                                         │
│   ════════════════                                                         │
│                                                                             │
│   Site A (Primary)                 Site B (Replica)                        │
│   ┌──────────────────┐            ┌──────────────────┐                    │
│   │ EDB Primary      │            │ EDB Replica      │                    │
│   │                  │            │                  │                    │
│   └────────┬─────────┘            └────────┬─────────┘                    │
│            │ archive WAL                   │ restore WAL                  │
│            ▼                               ▲                               │
│   ┌──────────────────────────────────────────────────────┐               │
│   │              PureStorage S3 Object Store              │               │
│   │                                                      │               │
│   │   site-a/                                            │               │
│   │   ├── base_backup.tar.gz                             │               │
│   │   └── wal_000000010000000000000001.gz               │               │
│   │                                                      │               │
│   └──────────────────────────────────────────────────────┘               │
│                                                                             │
│   ✅ No network dependency (uses S3)                                      │
│   ✅ Can do PITR (Point-in-Time Recovery)                                 │
│   ❌ Higher RPO (5-15 min)                                                │
│   ❌ Slower replication                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Method 3: Hybrid (Recommended)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   HYBRID (Streaming + WAL Archive) - RECOMMENDED                          │
│   ═══════════════════════════════════════════════                           │
│                                                                             │
│   Site A (Primary)                 Site B (Replica)                        │
│   ┌──────────────────┐            ┌──────────────────┐                    │
│   │ EDB Primary      │──stream──► │ EDB Replica      │                    │
│   │                  │   (WAL)    │                  │                    │
│   └────────┬─────────┘            └────────┬─────────┘                    │
│            │                              │                               │
│            │ archive WAL                  │ restore WAL (fallback)        │
│            ▼                              ▲                               │
│   ┌──────────────────────────────────────────────────────┐               │
│   │              PureStorage S3 Object Store              │               │
│   │                                                      │               │
│   │   • Primary path: Streaming (low latency)            │               │
│   │   • Fallback path: WAL archive (high availability)   │               │
│   │                                                      │               │
│   └──────────────────────────────────────────────────────┘               │
│            │                                                              │
│            └──────────────────┬─────────────────────────┘                 │
│                               │                                            │
│                        Submariner (IPsec)                                 │
│                                                                             │
│   ✅ Highest availability (multiple paths)                                │
│   ✅ Auto failover between methods                                        │
│   ✅ Can do PITR                                                          │
│   ✅ EDB Recommended                                                      │
│   ❌ Most complex configuration                                           │
│   ❌ Requires both Submariner + S3                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.9 Method 1: Streaming Only YAML

```yaml
# Site A - Primary Cluster (Streaming Only)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-a
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-b
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
      max_wal_senders: "10"
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a
  externalClusters:
    - name: cluster-site-b
      connectionParameters:
        host: cluster-site-b-rw.edb-app1-production.svc  # Via Submariner
        user: streaming_replica
        dbname: postgres
        # TLS: Configure sslmode, sslKey, sslCert, sslRootCert for production
```

```yaml
# Site B - Replica Cluster (Streaming Only)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-b
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-a
  bootstrap:
    pg_basebackup:
      source: cluster-site-a
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  externalClusters:
    - name: cluster-site-a
      connectionParameters:
        host: cluster-site-a-rw.edb-app1-production.svc  # Via Submariner
        user: streaming_replica
        dbname: postgres
        # TLS: Configure sslmode, sslKey, sslCert, sslRootCert for production
```

### 4.10 Method 2: WAL Archive Only YAML

```yaml
# Site A - Primary Cluster (WAL Archive Only)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-a
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-b
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-a/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
  externalClusters:
    - name: cluster-site-b
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-b
          serverName: cluster-site-b
```

```yaml
# Site B - Replica Cluster (WAL Archive Only)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-b
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-a
  bootstrap:
    recovery:
      source: cluster-site-a
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-b/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
  externalClusters:
    - name: cluster-site-a
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-a
          serverName: cluster-site-a
```

### 4.11 Method 3: Hybrid YAML (Recommended)

```yaml
# Site A - Primary Cluster (Hybrid)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-a
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-b
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
      max_wal_senders: "10"
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-a/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
  externalClusters:
    - name: cluster-site-b
      # Streaming connection (via Submariner)
      connectionParameters:
        host: cluster-site-b-rw.edb-app1-production.svc
        user: streaming_replica
        dbname: postgres
        # TLS: Configure sslmode, sslKey, sslCert, sslRootCert for production
      # WAL archive connection (via S3)
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-b
          serverName: cluster-site-b
```

```yaml
# Site B - Replica Cluster (Hybrid)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-b
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a
    source: cluster-site-a
  bootstrap:
    pg_basebackup:
      source: cluster-site-a
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-b/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
  externalClusters:
    - name: cluster-site-a
      # Streaming connection (via Submariner)
      connectionParameters:
        host: cluster-site-a-rw.edb-app1-production.svc
        user: streaming_replica
        dbname: postgres
        # TLS: Configure sslmode, sslKey, sslCert, sslRootCert for production
      # WAL archive connection (via S3)
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cluster-site-a
          serverName: cluster-site-a
```

### 4.12 Replica Cluster vs Single Standby

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SINGLE STANDBY (Previous)         REPLICA CLUSTER (EDB Recommended)      │
│   ════════════════════════          ════════════════════════════════        │
│                                                                             │
│   Site B:                           Site B:                                 │
│   ┌─────────────┐                   ┌─────────────────┐                    │
│   │   Standby   │                   │ Designated      │                    │
│   │   (1 pod)   │                   │ Primary (RO)    │                    │
│   └─────────────┘                   ├─────────────────┤                    │
│                                     │ Replica-1 (RO)  │                    │
│   Limitations:                      ├─────────────────┤                    │
│   • Single point of failure        │ Replica-2 (RO)  │                    │
│   • No read scaling                └─────────────────┘                    │
│   • After promotion = only 1 instance                                     │
│                                                                             │
│                                     Advantages:                             │
│                                     • HA within Site B                     │
│                                     • Read scaling (3 replicas)            │
│                                     • After promotion = full cluster       │
│                                     • Follows EDB best practice            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.13 EDB Official Warnings

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ⚠️  WARNING 1: Storage-Level Replication                                 │
│   ══════════════════════════════════════════                                │
│                                                                             │
│   Source: EDB Documentation                                                 │
│   "We recommend AGAINST storage-level replication with PostgreSQL,         │
│    although CNPG allows you to adopt that strategy."                       │
│                                                                             │
│   Our Architecture:                                                         │
│   • Portworx provides storage-level replication (additional safety net)    │
│   • EDB streaming provides application-level replication (primary)         │
│   • Both layers serve different purposes (see Section 5)                   │
│                                                                             │
│   Risk: Storage replication can cause split-brain if not managed properly  │
│   Mitigation: Always prioritize EDB streaming for data consistency         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ⚠️  WARNING 2: Cross-Cluster Automated Failover                          │
│   ═══════════════════════════════════════════════                           │
│                                                                             │
│   Source: EDB Documentation                                                 │
│   "CNPG cannot perform any cross-cluster automated failover,              │
│    as it does not have authority beyond a single Kubernetes cluster.       │
│    Such operations must be performed manually or delegated to a            │
│    multi-cluster/federated cluster-aware authority."                       │
│                                                                             │
│   Our Architecture:                                                         │
│   • Submariner provides cross-cluster connectivity                         │
│   • But CNPG operator CANNOT auto-failover across clusters                │
│   • Failover requires manual intervention or GitOps automation            │
│                                                                             │
│   Implication:                                                              │
│   • 3-layer failover (DB/Storage/Backup) still needs human decision       │
│   • Consider GitOps (ArgoCD/Flux) for automated failover orchestration   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Data Replication Strategy

> **⚠️ EDB Official Position:**
> "We recommend AGAINST storage-level replication with PostgreSQL."
> - Application-level replication (WAL shipping) is the PRIMARY method
> - Storage-level replication is an ADDITIONAL safety net, not primary
> - Both layers serve different purposes (see below)

### 5.1 Why Two Layers?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   THE CORE QUESTION                                                         │
│   ══════════════════                                                        │
│                                                                             │
│   Do we need BOTH EDB streaming AND Portworx volume replication?            │
│                                                                             │
│   Answer: YES - they solve DIFFERENT problems.                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 What Each Layer Does

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   EDB STREAMING REPLICATION                                                 │
│   ════════════════════════                                                  │
│                                                                             │
│   What: PostgreSQL WAL (Write-Ahead Log) shipping                           │
│   Level: Database transaction level                                         │
│   Scope: Logical data (tables, rows, indexes)                               │
│   RPO: 5-30 seconds (async)                                                 │
│                                                                             │
│   Provides:                                                                 │
│   ✓ Transaction consistency                                                 │
│   ✓ Crash recovery                                                          │
│   ✓ Point-in-time recovery                                                  │
│   ✓ Read scaling (standby for reads)                                        │
│                                                                             │
│   Does NOT provide:                                                         │
│   ✗ Storage-level DR                                                       │
│   ✗ Protection against disk corruption                                     │
│   ✗ Cross-site volume failover                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   PORTWORX STORAGE REPLICATION                                              │
│   ════════════════════════════                                              │
│                                                                             │
│   What: Block-level volume replication                                      │
│   Level: Storage disk level                                                 │
│   Scope: Raw blocks (filesystem + data)                                     │
│   RPO: Near real-time (sync within cluster)                                 │
│                                                                             │
│   Provides:                                                                 │
│   ✓ Node failure tolerance                                                 │
│   ✓ Disk failure tolerance                                                 │
│   ✓ Storage HA                                                             │
│   ✓ Volume migration                                                       │
│                                                                            │
│   Does NOT provide:                                                        │
│   ✗ Transaction consistency                                                │
│   ✗ Crash recovery                                                         │
│   ✗ Logical replication                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.3 Failure Scenarios Analysis

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SCENARIO 1: Node/Disk Failure (Site A)                                    │
│   ════════════════════════════════════════                                  │
│                                                                             │
│   What fails: Single NVMe disk or node                                     │
│                                                                             │
│   With CloudNativePG + Portworx:                                          │
│   • Kubernetes detects node failure                                        │
│   • CNPG operator reschedules EDB pod to healthy node                     │
│   • Portworx provides PV from replicas (data available)                   │
│   • EDB restarts on new node                                              │
│   • CNPG rebuilds failed replica automatically                            │
│   • RTO: Seconds (automatic)                                              │
│                                                                             │
│   Without Portworx:                                                        │
│   • PV lost, EDB crashes                                                  │
│   • Need to restore from backup                                           │
│   • RTO: Hours                                                            │
│                                                                             │
│   EDB Streaming: Not relevant here (same site)                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SCENARIO 2: Site A Complete Failure                                       │
│   ════════════════════════════════════                                      │
│                                                                             │
│   What fails: Entire Site A (power, network, etc.)                          │
│                                                                             │
│   Without EDB Streaming:                                                    │
│   • Site B has no data (standby never received WAL)                         │
│   • Need to restore from backup                                             │
│   • RPO: Hours/Days (last backup)                                           │
│   • RTO: Hours                                                              │
│                                                                             │
│   With EDB Streaming:                                                       │
│   • Site B standby has recent data (WAL shipped)                            │
│   • Promote standby to primary                                              │
│   • RPO: 5-30 seconds                                                       │
│   • RTO: 3-5 minutes                                                        │
│                                                                             │
│   Portworx: Volumes replicated but not mounted on Site B                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SCENARIO 3: Storage Corruption (Silent)                                   │
│   ═════════════════════════════════════════                                 │
│                                                                             │
│   What fails: Bit-rot, firmware bug, silent data corruption                 │
│                                                                             │
│   Without Both:                                                             │
│   • Corrupted data propagates                                               │
│   • Both primary and standby have bad data                                  │
│   • Data loss                                                               │
│                                                                             │
│   With Both:                                                                │
│   • Portworx: Can detect corruption via checksums                           │
│   • EDB Streaming: Can rebuild standby from clean WAL                       │
│   • Multiple recovery paths                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.4 Trade-Off Analysis

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                    OPTION COMPARISON                                        │
│                                                                             │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│                     │   EDB Streaming     │   EDB + Portworx                │
│                     │   Only              │   (Recommended)                 │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Transaction         │   ✓ Yes             │   ✓ Yes                        │
│ Consistency         │                     │                                 │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Node/Disk Failure   │   ✗ No              │   ✓ Yes                        │
│ Recovery            │   (manual restore)  │   (automatic)                   │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Site Failure RPO    │   5-30 seconds      │   5-30 seconds                  │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Site Failure RTO    │   3-5 minutes       │   3-5 minutes                   │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Storage HA          │   ✗ No              │   ✓ Yes                        │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Complexity          │   Low               │   Medium                        │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Storage Overhead    │   0%                │   100% (2x)                     │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│ Operational Risk    │   Medium            │   Low                           │
└─────────────────────┴─────────────────────┴─────────────────────────────────┘
```

### 5.5 Recommendation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                    RECOMMENDATION: USE BOTH                                 │
│                                                                             │
│   Why:                                                                      │
│   ─────                                                                     │
│   1. Different layers protect against different failures                    │
│      • EDB: Database consistency + site failover                            │
│      • Portworx: Storage HA + node/disk failure                             │
│                                                                             │
│   2. Storage is cheap, data loss is expensive                               │
│      • 2x storage overhead is acceptable for production DB                  │
│      • Cost of data loss >> cost of extra storage                           │
│                                                                             │
│   3. Operational simplicity in failover                                     │
│      • No PV migration needed (already local)                               │
│      • Just promote DB + update DNS                                         │
│                                                                             │
│   4. Defense in depth                                                       │
│      • Multiple recovery paths                                              │
│      • No single point of failure                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SIMPLIFIED VIEW (What you actually need):                                 │
│                                                                             │
│   The "two layers" are NOT redundant - they serve different purposes:       │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EDB Streaming ──► "How to failover between sites"                 │   │
│   │                     (database-level replication)                    │   │
│   │                                                                     │   │
│   │   Portworx ───────► "How to survive disk/node failure"              │   │
│   │                     (storage-level HA)                              │   │
│   │                                                                     │   │
│   │   They complement, not duplicate.                                   │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.6 When to Use Only EDB Streaming

```
If you want to simplify (single layer):

Use ONLY EDB Streaming when:
• Budget is very tight (can't afford 2x storage)
• Non-critical workloads (dev/test)
• Can tolerate manual PV restoration on failure
• Single-site deployment (no cross-site DR needed)

Risks:
• Node/disk failure = manual restore from backup
• Longer RTO (hours vs minutes)
• More operational overhead during failures
```

---

## 6. Failover Architecture

### 6.1 Normal Operation

```
    ┌─────────┐      ┌─────────────┐      ┌─────────────┐
    │   DNS   │─────►│  OCP Site A │─────►│ EDB Primary │
    │ (Active)│      │             │      │    (RW)     │
    └─────────┘      └─────────────┘      └─────────────┘
                          │                      │
                          │               PV on Site A
                          │               (A1 local + B2 remote)
                          │                      │
                          │              EDB Streaming
                          │              (Async WAL)
                          │                      │
                          ▼                      ▼
                    ┌─────────────┐      ┌─────────────┐
                    │  OCP Site B │◄─────│ EDB Standby │
                    │             │      │    (RO)     │
                    └─────────────┘      └─────────────┘
                                              │
                                         PV on Site B
                                         (B1 local + A2 remote)
```

### 6.2 Failover (Site A Down)

```
    ┌─────────┐      ┌─────────────┐      ┌─────────────┐
    │   DNS   │─────►│  OCP Site B │─────►│ EDB Primary │
    │(Updated)│      │             │      │  (Promoted) │
    └─────────┘      └─────────────┘      └─────────────┘
                                              │
                                         PV on Site B
                                         (Already Local!)
                                         (No Migration Needed!)
```

### 6.3 Failover Advantage

```
┌─────────────────────────────────────────────────────────────────┐
│                    FAILOVER COMPARISON                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Without PV Locality (Wrong)                                   │
│   ═══════════════════════════                                   │
│   • PV on Site A → Need to copy to Site B                       │
│   • Data transfer: 100GB+ across sites                          │
│   • Time: 30-60 minutes                                         │
│   • Risk: Data loss during transfer                             │
│                                                                 │
│   With PV Locality (Correct)                                    │
│   ════════════════════════════                                  │
│   • PV already on Site B (local copy exists)                    │
│   • No data transfer needed                                     │
│   • Time: 1-2 minutes (just promote DB)                         │
│   • Risk: Minimal                                               │
│                                                                 │
│   RTO Improvement: 30-60 min → 3-5 min                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. Recovery Procedures

### 7.1 Failback (Site A Recovery)

```
Phase 1: Site A Returns as Standby
────────────────────────────────────

    Applications ──► Site B (Active) ──► EDB Primary ──► PV (B1 local)
                                          │
                                   EDB Streaming
                                          │
                                          ▼
                                Site A (Standby) ──► EDB Standby ──► PV (A1 local)
                                                │
                                           Portworx
                                           Re-sync


Phase 2: Optional Switchover Back
───────────────────────────────────

    Applications ──► Site A (Active) ──► EDB Primary ──► PV (A1 local)
                                          │
                                   EDB Streaming
                                          │
                                          ▼
                                Site B (Passive) ──► EDB Standby ──► PV (B1 local)
```

---

## 8. Cross-Cluster Connectivity (Submariner)

### 8.1 Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SUBMARINER: CROSS-CLUSTER CONNECTIVITY                                    │
│   ══════════════════════════════════════                                    │
│                                                                             │
│   Problem: 2 independent OCP clusters with NO network path                 │
│   Solution: Submariner (OCP native) provides:                              │
│                                                                             │
│   1. IPsec/WireGuard tunnel between clusters                               │
│   2. Cross-cluster service discovery (Lighthouse)                          │
│   3. Service Export/Import across clusters                                 │
│   4. Pod-to-Pod connectivity across clusters                               │
│                                                                             │
│   Why Submariner:                                                           │
│   • OCP native support (Red Hat certified)                                 │
│   • Works with OVN-Kubernetes (OCP default CNI)                            │
│   • Automatic service discovery via DNS                                    │
│   • No manual VPN configuration                                            │
│                                                                             │
│   Prerequisites:                                                            │
│   • OCP 4.x on both clusters                                              │
│   • OVN-Kubernetes CNI (default)                                           │
│   • Submariner operator installed                                          │
│   • Network: clusters must reach broker endpoint                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                     SUBMARINER COMPONENTS                                   │
│                                                                             │
│   Cluster A (Broker)                       Cluster B                        │
│   ┌─────────────────────────────────┐     ┌─────────────────────────────┐   │
│   │                                 │     │                             │   │
│   │  ┌─────────────────────────┐    │     │    ┌─────────────────────┐  │   │
│   │  │       Broker            │    │     │    │                     │  │   │
│   │  │  (runs on Cluster A)    │◄───┼─────┼───►│   submariner-agent  │  │   │
│   │  │  • API server           │    │     │    │   (runs on Cluster B)│  │   │
│   │  │  • Certificate mgmt     │    │     │    │   • Connects to     │  │   │
│   │  └─────────────────────────┘    │     │    │     broker          │  │   │
│   │                                 │     │    │   • Registers       │  │   │
│   │  ┌─────────────────────────┐    │     │    │     cluster         │  │   │
│   │  │    submariner-gateway   │    │     │    └─────────────────────┘  │   │
│   │  │  • IPsec tunnel         │◄───┼─────┼───►┌─────────────────────┐  │   │
│   │  │  • Route agent          │    │     │    │  submariner-gateway │  │   │
│   │  └─────────────────────────┘    │     │    │  • IPsec tunnel     │  │   │
│   │                                 │     │    │  • Route agent      │  │   │
│   │  ┌─────────────────────────┐    │     │    └─────────────────────┘  │   │
│   │  │      Lighthouse         │    │     │                             │   │
│   │  │  • DNS service discovery│    │     │    ┌─────────────────────┐  │   │
│   │  │  • ServiceExport/Import │    │     │    │     Lighthouse      │  │   │
│   │  └─────────────────────────┘    │     │    │  • DNS resolution   │  │   │
│   │                                 │     │    │  • ServiceExport    │  │   │
│   └─────────────────────────────────┘     │    └─────────────────────┘  │   │
│                                           │                             │   │
│                                           └─────────────────────────────┘   │
│                                                                             │
│   Network Path:                                                             │
│   Cluster A Pod ──► submariner-gateway ──► IPsec Tunnel ──► Cluster B Pod  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.3 Installation

```bash
# ============================================================
# STEP 1: Install Submariner Operator (Both Clusters)
# ============================================================

# On Cluster A and Cluster B
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: submariner
  namespace: openshift-operators
spec:
  channel: stable
  name: submariner
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator pods
oc get pods -n openshift-operators -w

# ============================================================
# STEP 2: Deploy Broker on Cluster A
# ============================================================

# On Cluster A
subctl deploy-broker

# Output will include:
# - Broker URL
# - Broker token
# - CA certificate
# SAVE THESE for Cluster B

# ============================================================
# STEP 3: Join Cluster B to Broker
# ============================================================

# On Cluster B
subctl join broker-info.subm --clusterid site-b

# Enter when prompted:
# - Broker URL (from Step 2)
# - Broker token (from Step 2)

# ============================================================
# STEP 4: Verify Gateway Pods
# ============================================================

# On both clusters
oc get pods -n submariner-operator

# Check tunnel status
subctl show connections
subctl show endpoints
# NOTE: For production OCP deployments, consider using Red Hat Advanced Cluster
# Management (RHACM) Submariner add-on instead of manual installation.
# RHACM provides managed lifecycle, certificate rotation, and upgrade support.
```

### 8.4 Service Export/Import

```bash
# ============================================================
# Export EDB Service from Cluster A
# ============================================================

# On Cluster A
cat <<EOF | oc apply -f -
apiVersion: submariner.io/v1alpha1
kind: ServiceExport
metadata:
  name: edb-app1-cluster-rw
  namespace: edb-app1-production
EOF

# Verify export
subctl show serviceexports -n edb-app1-production

# ============================================================
# Verify DNS Resolution from Cluster B
# ============================================================

# On Cluster B - test DNS
oc run dns-test --image=busybox --rm -it -- \
  nslookup edb-app1-cluster-rw.edb-app1-production.clusterset.local

# Should resolve to Cluster A Pod IP
```

### 8.5 Application Access Pattern

```yaml
# App on Cluster B accessing Cluster A's DB via Submariner
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: edb-app1-production
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: myapp:latest
        env:
        # Submariner DNS: cross-cluster service discovery
        - name: DB_HOST
          value: "edb-app1-cluster-rw.edb-app1-production.clusterset.local"
        - name: DB_PORT
          value: "5432"
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SUBMARINER DNS RESOLUTION                                                 │
│   ═══════════════════════════                                               │
│                                                                             │
│   Format: <service>.<namespace>.clusterset.local                           │
│                                                                             │
│   Example:                                                                  │
│   edb-app1-cluster-rw.edb-app1-production.clusterset.local                 │
│   │              │           │                                              │
│   │              │           └── Submariner DNS domain                      │
│   │              └── Namespace                                              │
│   └── Service name                                                          │
│                                                                             │
│   Resolution Flow:                                                          │
│   1. App queries DNS: edb-app1-cluster-rw.edb-app1-production.clusterset.local│
│   2. Lighthouse intercepts query                                            │
│   3. Returns Cluster A Pod IP (ServiceExport on Cluster A)                 │
│   4. App connects to Cluster A Pod (through IPsec tunnel)                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.6 Failover with Submariner

```bash
# ============================================================
# FAILOVER PROCEDURE (Cluster A down)
# ============================================================

# Step 1: Promote EDB standby on Cluster B
oc config use-context site-b
oc exec -it edb-app1-cluster-standby-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_promote();"

# Step 2: Verify EDB is promoted
oc exec -it edb-app1-cluster-standby-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: f

# Step 3: Export new service on Cluster B
cat <<EOF | oc apply -f -
apiVersion: submariner.io/v1alpha1
kind: ServiceExport
metadata:
  name: edb-app1-cluster-rw
  namespace: edb-app1-production
EOF

# Step 4: (Optional) Delete old export on Cluster A
oc config use-context site-a
oc delete serviceexport edb-app1-cluster-rw -n edb-app1-production --ignore-not-found

# Step 5: Verify DNS updated
oc run dns-test --image=busybox --rm -it -- \
  nslookup edb-app1-cluster-rw.edb-app1-production.clusterset.local
# Should now resolve to Cluster B Pod IP

# Step 6: Test connectivity
oc run db-test --image=busybox --rm -it -- \
  nc -zv edb-app1-cluster-rw.edb-app1-production.clusterset.local 5432
```

### 8.7 Failback (Cluster A Recovery)

```bash
# ============================================================
# FAILBACK PROCEDURE (Cluster A returns)
# ============================================================

# Step 1: Verify Cluster A is back
oc config use-context site-a
subctl show connections
subctl show endpoints

# Step 2: Re-establish EDB streaming replication
# (Site A becomes standby, Site B remains primary)

# Step 3: Export service on Cluster A (when ready to failback)
cat <<EOF | oc apply -f -
apiVersion: submariner.io/v1alpha1
kind: ServiceExport
metadata:
  name: edb-app1-cluster-rw
  namespace: edb-app1-production
EOF

# Step 4: Delete export on Cluster B
oc config use-context site-b
oc delete serviceexport edb-app1-cluster-rw -n edb-app1-production

# Step 5: Promote EDB on Cluster A (optional - if switching back)
oc config use-context site-a
oc exec -it edb-app1-cluster-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_promote();"
```

### 8.8 Network Requirements

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SUBMARINER NETWORK REQUIREMENTS                                           │
│   ════════════════════════════════                                          │
│                                                                             │
│   Minimum Connectivity:                                                     │
│   • Broker endpoint must be reachable from both clusters                   │
│   • Default: UDP port 4500 (IPsec NAT-T)                                  │
│   • Default: UDP port 4490 (NAT Traversal Discovery)                       │
│   • TCP port 443 (Broker API)                                              │
│                                                                             │
│   Firewall Rules:                                                           │
│   ┌─────────────────────────────────────────────────────────────────┐      │
│   │ Direction  │ Port   │ Protocol │ Purpose                       │      │
│   ├────────────┼────────┼──────────┼───────────────────────────────┤      │
│   │ Inbound    │ 4500   │ UDP      │ IPsec NAT Traversal           │      │
│   │ Inbound    │ 4490   │ UDP      │ NAT Traversal Discovery        │      │
│   │ Inbound    │ 443    │ TCP      │ Broker API                    │      │
│   │ Outbound   │ 4500   │ UDP      │ IPsec NAT Traversal           │      │
│   │ Outbound   │ 4490   │ UDP      │ NAT Traversal Discovery        │      │
│   │ Outbound   │ 443    │ TCP      │ Broker API                    │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│   Pod CIDR:                                                                 │
│   • Cluster A Pod CIDR must NOT overlap Cluster B Pod CIDR                │
│   • Example: Cluster A: 10.244.0.0/16, Cluster B: 10.245.0.0/16          │
│                                                                             │
│   Service CIDR:                                                             │
│   • Cluster A Service CIDR must NOT overlap Cluster B Service CIDR        │
│   • Example: Cluster A: 10.243.0.0/16, Cluster B: 10.242.0.0/16          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.9 Verification Commands

```bash
# ============================================================
# SUBMARINER VERIFICATION
# ============================================================

# Check operator status
oc get pods -n submariner-operator

# Check gateway pods
oc get pods -n submariner-operator -l app=submariner-gateway

# Check Lighthouse DNS
oc get pods -n submariner-operator -l app=submariner-lighthouse

# Show connections between clusters
subctl show connections

# Show endpoints (cluster gateways)
subctl show endpoints

# Show service exports
subctl show serviceexports

# Show service imports (on receiving cluster)
subctl show serviceimports

# Test cross-cluster connectivity
subctl show connections

# Verify DNS resolution
oc run dns-test --image=busybox --rm -it -- \
  nslookup <service>.<namespace>.clusterset.local

# Check IPsec tunnel status
oc exec -n submariner-operator $(oc get pods -n submariner-operator -l app=submariner-gateway -o name) -- \
  ipsec status
```

---

## 9. Storage-Level Failover (Portworx Metro)

### 9.1 Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   STORAGE-LEVEL FAILOVER                                                   │
│   ════════════════════════                                                  │
│                                                                             │
│   When: EDB streaming replication fails, but storage is healthy             │
│   How:  Use Portworx Stork to migrate entire namespace to Site B            │
│   Then: Bootstrap new EDB cluster from existing PV (no WAL needed)          │
│                                                                             │
│   RPO: Near real-time (PX sync lag)                                         │
│   RTO: 5-10 minutes (namespace migration + EDB bootstrap)                   │
│                                                                             │
│   Prerequisites:                                                            │
│   • Network: Maximum 10 ms round-trip latency between sites (Portworx Metro DR requirement)
│   • Stork 24.2.0+ on both clusters                                         │
│   • ClusterPair configured between Site A and Site B                       │
│   • MigrationSchedule running (namespace-level sync)                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 When to Use

```
Use Storage-Level Failover when:

✓ EDB streaming replication is broken (WAL ship interrupted)
✓ EDB standby is out of sync or unreachable
✓ Storage (Portworx) is healthy and PVs are in sync
✓ Need faster recovery than backup restore
✗ Do NOT use when PV data is corrupted (use Section 10 instead)
✗ Do NOT use when Site A storage is also down (use Section 10 instead)
```

### 9.3 Architecture Flow

```
Normal Operation:
─────────────────

    Site A                                    Site B
    ┌──────────────────────┐                 ┌──────────────────────┐
    │ EDB Primary (RW)     │──streaming──►  │ EDB Standby (RO)     │
    │ PV: A1 local + B2    │   (WAL)        │ PV: B1 local + A2    │
    │                      │                 │                      │
    │ Stork MigrationSchedule ──────────────►│ (namespace sync)     │
    └──────────────────────┘                 └──────────────────────┘


Storage-Level Failover (EDB streaming broken):
──────────────────────────────────────────────

    Step 1: storkctl perform failover
    ───────────────────────────────────
    Site A (DOWN)                          Site B
    ┌──────────────────────┐               ┌──────────────────────────────┐
    │ EDB Primary ✗        │               │ Namespace migrated           │
    │ Stork scales down    │               │ PV activated (B1 local)      │
    │                      │               │ EDB pod starts from PV data  │
    └──────────────────────┘               └──────────────────────────────┘

    Step 2: Bootstrap EDB from PV
    ──────────────────────────────
    ┌──────────────────────────────────────────────────────────────────────┐
    │ Site B                                                              │
    │                                                                     │
    │   New EDB Cluster (CNPG recovery from PV)                          │
    │   ┌─────────────┐                                                  │
    │   │ Primary (RW)│ ◄── PV already contains DB data                 │
    │   └─────────────┘                                                  │
    │                                                                     │
    │   RTO: 5-10 min (PV is local, no data transfer)                    │
    │   RPO: PX sync lag (near real-time)                                │
    └──────────────────────────────────────────────────────────────────────┘
```

### 9.4 Prerequisites: ClusterPair Setup

```yaml
# On Site A (source cluster)
# Generate cluster pair token
PX_POD=$(oc get pods -l name=portworx -n kube-system -o jsonpath='{.items[0].metadata.name}')
oc exec $PX_POD -n kube-system -- /opt/pwx/bin/pxctl cluster token show

# On Site B (destination cluster) - create ClusterPair
cat <<EOF | oc apply -f -
apiVersion: stork.libopenstorage.org/v1alpha1
kind: ClusterPair
metadata:
  name: site-b-pair
  namespace: edb-app1-production
spec:
  storageOptions:
    defaultStorageClass: portworx-edb-site-b
    provisioner: kubernetes.io/portworx-volume
  schedulerOptions:
    defaultScheduler: stork
  cmOptions: {}
  credentials:
    name: cluster-pair-secret
    namespace: edb-app1-production
EOF
```

### 9.5 MigrationSchedule Configuration

```yaml
# Create MigrationSchedule for each EDB namespace
# This ensures namespace state is continuously synced to Site B
cat <<EOF | oc apply -f -
apiVersion: stork.libopenstorage.org/v1alpha1
kind: MigrationSchedule
metadata:
  name: edb-app1-migration
  namespace: edb-app1-production
spec:
  template:
    spec:
      clusterPair: site-b-pair
      includeResources: true
      startApplications: false  # Don't start apps on Site B (standby)
      preExecRules: []
      postExecRules: []
  schedulePolicy:
    intervalMinutes: 5  # Sync namespace state every 5 minutes
    selected:
      - schedulePolicyName: interval
  suspend: false
EOF
```

### 9.6 Failover Procedure (storkctl)

```bash
# ============================================================
# STEP 1: Confirm Site A is down / EDB streaming broken
# ============================================================
# Check from Site B:
oc get pods -n edb-app1-production
# EDB standby should be out of sync or crashing

# ============================================================
# STEP 2: Perform failover from Site B
# ============================================================
# Switch to Site B context
oc config use-context site-b

# Perform namespace-level failover
storkctl perform failover \
  -c site-b-pair \
  -n edb-app1-production \
  migration-schedule \
  --exclude-resource-types ClusterServiceVersion,operatorconditions,OperatorGroup,InstallPlan,Subscription

# Verify migration status
oc get actions -n edb-app1-production
# Status should show: "Successful"

# ============================================================
# STEP 3: Verify PV is activated on Site B
# ============================================================
oc get pvc -n edb-app1-production
# PVs should be Bound on Site B

# ============================================================
# STEP 4: Bootstrap new EDB cluster from existing PV data
# ============================================================
# See Section 9.7 for CNPG recovery YAML

# ============================================================
# STEP 5: Update DNS/Route to point to Site B
# ============================================================
oc patch route edb-app1-rw -n edb-app1-production \
  --type merge \
  -p '{"spec":{"to":{"name":"edb-app1-cluster-rw"}}}'

# ============================================================
# STEP 6: Verify Site B is serving traffic
# ============================================================
oc exec -it edb-app1-cluster-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: f (not in recovery = primary)
```

### 9.7 CNPG Recovery from Existing PV

```yaml
# NOTE: This is a CONCEPTUAL example. The bootstrap.recovery method restores from
# a Barman Cloud object store, NOT from an existing PV directly. After Portworx
# Stork namespace migration, the PV containing PGDATA is already mounted on Site B.
# The correct approach is to pre-create the PVC bound to the migrated PV, then
# create the CNPG Cluster without a bootstrap stanza so CNPG detects the existing
# data directory. The exact adoption procedure depends on CNPG version.
# This YAML shows the conceptual flow; adjust for your specific CNPG version.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: edb-app1-cluster-recovered
  namespace: edb-app1-production
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  bootstrap:
    recovery:
      source: edb-app1-pv-backup
  externalClusters:
    - name: edb-app1-pv-backup
      # Point to the existing PV that was migrated via Portworx
      # The PV contains valid PGDATA from the failover
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: edb-app1-pv-store
          serverName: edb-app1-cluster
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
```

### 9.8 Failback (Site A Recovery)

```bash
# ============================================================
# After Site A recovers, activate PX domain and failback
# ============================================================

# Step 1: Activate Site A domain in Portworx
# (PX nodes will be "Out of Quorum" after outage)
oc config use-context site-a
PX_POD=$(oc get pods -l name=portworx -n kube-system -o jsonpath='{.items[0].metadata.name}')
oc exec $PX_POD -n kube-system -- /opt/pwx/bin/pxctl cluster domain activate site-a

# Step 2: Wait for Site A to rejoin cluster
oc exec $PX_POD -n kube-system -- /opt/pwx/bin/pxctl status
# All nodes should be "Online"

# Step 3: Failback from Site B
oc config use-context site-b
storkctl perform failback \
  -c site-b-pair \
  -n edb-app1-production \
  migration-schedule

# Step 4: Verify Site A is active again
oc config use-context site-a
oc get pods -n edb-app1-production

# Step 5: Re-establish EDB streaming replication
# Promote Site A as primary, Site B as standby
```

### 9.9 Comparison: DB-Level vs Storage-Level Failover

```
┌─────────────────────────────────┬────────────────────┬─────────────────────┐
│                                 │   DB-Level         │   Storage-Level     │
│                                 │   (Section 6)      │   (Section 9)       │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ Trigger                         │ EDB streaming      │ EDB streaming       │
│                                 │ broken             │ broken + need       │
│                                 │                    │ faster than backup  │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ Data Source                     │ WAL shipping       │ Portworx PV sync    │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ Consistency                     │ Transaction-level  │ Block-level         │
│                                 │ (WAL replay)       │ (may lose unflushed │
│                                 │                    │  WAL segments)      │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ RPO                             │ 5-30 seconds       │ Near real-time      │
│                                 │                    │ (PX sync lag)       │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ RTO                             │ 3-5 minutes        │ 5-10 minutes        │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ Complexity                      │ Low                │ Medium              │
├─────────────────────────────────┼────────────────────┼─────────────────────┤
│ Prerequisite                    │ Standby in sync    │ Stork + ClusterPair │
└─────────────────────────────────┴────────────────────┴─────────────────────┘
```

---

## 10. Backup Restore (PureStorage Object Store)

### 10.1 Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   BACKUP-LEVEL FAILOVER (Last Resort)                                       │
│   ════════════════════════════════════                                      │
│                                                                             │
│   When: Both EDB streaming AND Portworx sync are compromised                │
│   How:  Restore from incremental backup in PureStorage object store         │
│   Then: Bootstrap brand-new EDB cluster from Barman Cloud backup            │
│                                                                             │
│   RPO: Backup interval (5-15 minutes, configurable)                         │
│   RTO: 15-60 minutes (depends on DB size + network speed)                   │
│                                                                             │
│   Prerequisites:                                                            │
│   • CNPG Barman Cloud Plugin configured                                     │
│   • PureStorage object store (S3-compatible) accessible                     │
│   • Incremental backups with WAL archive in object store                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.2 When to Use

```
Use Backup Restore when:

✓ Both sites have storage corruption / data loss
✓ EDB streaming is broken AND Portworx PVs are out of sync
✓ Need to restore to specific point-in-time (PITR)
✓ New cluster needed (Site B PV not可用)
✗ Do NOT use when PV data is intact (use Section 9 instead — faster)
✗ Do NOT use as first resort (higher RPO/RTO than Sections 6 & 9)
```

### 10.3 Architecture Flow

```
Normal Operation (Backup Path):
───────────────────────────────

    Site A (Active)
    ┌─────────────────────────────────────────────────────────┐
    │ EDB Primary (RW)                                        │
    │   │                                                     │
    │   ├── EDB Streaming ──────────────────► Site B Standby  │
    │   │                                                     │
    │   └── Barman Cloud (Incremental Backup)                │
    │       ├── Base backup ──────────► PureStorage S3        │
    │       └── WAL archive ──────────► PureStorage S3        │
    └─────────────────────────────────────────────────────────┘


Backup Restore (Disaster Recovery):
────────────────────────────────────

    Site A (DOWN) + Site B (PV corrupted)
    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │   PureStorage Object Store                              │
    │   ┌─────────────────────────────────────────────┐       │
    │   │ ├── base_backup_20260915.tar.gz             │       │
    │   │ ├── wal_000000010000000000000001.gz         │       │
    │   │ ├── wal_000000010000000000000002.gz         │       │
    │   │ └── ... (incremental WAL segments)          │       │
    │   └─────────────────────────────────────────────┘       │
    │              │                                          │
    │              ▼ barman-cloud-restore                     │
    │                                                         │
    │   Site B (New EDB Cluster)                              │
    │   ┌─────────────────────────────────────────────┐       │
    │   │ CNPG Bootstrap: recovery from object store  │       │
    │   │ ├── Base backup restore                     │       │
    │   │ ├── WAL replay (PITR)                       │       │
    │   │ └── New primary running                     │       │
    │   └─────────────────────────────────────────────┘       │
    │                                                         │
    │   RPO: Backup interval (5-15 min)                       │
    │   RTO: 15-60 min (depends on DB size)                   │
    └─────────────────────────────────────────────────────────┘
```

### 10.4 Barman Cloud Plugin Configuration

```yaml
# CNPG Cluster with Barman Cloud backup to PureStorage
# (Incremental backup + WAL archive)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: edb-app1-cluster
  namespace: edb-app1-production
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/app1/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 4
      data:
        compression: gzip
        jobs: 2
      retentionPolicy: "30d"
    scheduledBackup:
      - name: edb-app1-backup
        schedule: "0 */5 * * * *"  # Every 5 minutes
        backupOwnerReference: self
```

### 10.5 PureStorage Credentials Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: purestorage-credentials
  namespace: edb-app1-production
type: Opaque
stringData:
  ACCESS_KEY_ID: "<YOUR_PURESTORAGE_ACCESS_KEY>"
  ACCESS_SECRET_KEY: "<YOUR_PURESTORAGE_SECRET_KEY>"
```

### 10.6 Full Restore (Latest State)

```yaml
# Restore to latest available backup
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: edb-app1-cluster-restored
  namespace: edb-app1-production
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b  # Restore to Site B
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  bootstrap:
    recovery:
      source: edb-app1-purestorage
  externalClusters:
    - name: edb-app1-purestorage
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: edb-app1-purestorage
          serverName: edb-app1-cluster
```

### 10.7 Point-in-Time Recovery (PITR)

```yaml
# Restore to specific point in time
# Useful when data corruption occurred at known time
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: edb-app1-cluster-pitr
  namespace: edb-app1-production
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  bootstrap:
    recovery:
      source: edb-app1-purestorage
      recoveryTarget:
        # Recover to specific timestamp (before corruption)
        targetTime: "2026-09-15T10:30:00+08:00"
        # OR recover to specific transaction ID
        # targetXID: "12345678"
        # OR recover to specific backup
        # backupID: "20260915T100000"
  externalClusters:
    - name: edb-app1-purestorage
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: edb-app1-purestorage
          serverName: edb-app1-cluster
```

### 10.8 Restore Procedure

```bash
# ============================================================
# STEP 1: Verify PureStorage object store is accessible
# ============================================================
# From Site B, check connectivity
oc exec -it <any-pod> -- curl -s https://purestorage-objectstore.example.com

# ============================================================
# STEP 2: Create credentials secret (if not exists)
# ============================================================
oc apply -f purestorage-credentials-secret.yaml

# ============================================================
# STEP 3: Apply recovery cluster YAML
# ============================================================
oc apply -f edb-app1-cluster-restored.yaml

# ============================================================
# STEP 4: Monitor restore progress
# ============================================================
# Watch pod status
oc get pods -n edb-app1-production -w

# Check restore logs
oc logs -f edb-app1-cluster-restored-1 -n edb-app1-production

# Check CNPG status
oc get cluster edb-app1-cluster-restored -n edb-app1-production -o yaml

# ============================================================
# STEP 5: Verify data integrity
# ============================================================
oc exec -it edb-app1-cluster-restored-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "
    SELECT pg_is_in_recovery(),
           pg_last_wal_receive_lsn(),
           pg_last_wal_replay_lsn();
  "

# ============================================================
# STEP 6: Update DNS/Route
# ============================================================
oc patch route edb-app1-rw -n edb-app1-production \
  --type merge \
  -p '{"spec":{"to":{"name":"edb-app1-cluster-restored-rw"}}}'

# ============================================================
# STEP 7: Re-enable scheduled backups
# ============================================================
# After restore, create new backup schedule for the new cluster
```

### 10.9 Comparison: Three Failover Methods

```
┌─────────────────────────────────┬──────────────┬──────────────┬──────────────┐
│                                 │   DB-Level   │   Storage-   │   Backup     │
│                                 │   (Sec 6)    │   Level      │   Restore    │
│                                 │              │   (Sec 9)    │   (Sec 10)   │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Data Source                     │ EDB WAL      │ PX PV sync   │ PureStorage  │
│                                 │              │              │ S3 backup    │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ RPO                             │ 5-30 sec     │ Near         │ 5-15 min     │
│                                 │              │ real-time    │ (backup      │
│                                 │              │              │  interval)   │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ RTO                             │ 3-5 min      │ 5-10 min     │ 15-60 min    │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Consistency                     │ Transaction  │ Block-level  │ Transaction  │
│                                 │ (WAL replay) │ (PX sync)    │ (WAL replay) │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Use Case                        │ EDB repl     │ EDB broken,  │ Both sites   │
│                                 │ broken       │ PX healthy   │ compromised  │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Complexity                      │ Low          │ Medium       │ Medium       │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Prerequisite                    │ Standby in   │ Stork +      │ Object store │
│                                 │ sync         │ ClusterPair  │ accessible   │
├─────────────────────────────────┼──────────────┼──────────────┼──────────────┤
│ Storage Needed                  │ None extra   │ None extra   │ S3 bucket    │
│                                 │              │              │ (PureStorage)│
└─────────────────────────────────┴──────────────┴──────────────┴──────────────┘
```

---

## 11. Multiple EDB Instances

### 11.1 Namespace Pattern (EDB Distributed Topology)

> **⚠️ EDB Recommendation:** Use "Distributed Topology" for DR/HA across clusters
> - Both clusters define `externalClusters` pointing to each other
> - Symmetric configuration (both clusters have same structure)
> - Controlled switchover via promotion token

```
Site A (Primary Cluster):                Site B (Replica Cluster):
─────────────────────                    ───────────────────────

edb-app1-production                      edb-app1-production
  └─ cluster-site-a (3 reps)               └─ cluster-site-b (3 reps)
       ├─ Primary (RW)                          ├─ Designated Primary (RO)
       ├─ Replica-1 (RO)                       ├─ Replica-1 (RO)
       └─ Replica-2 (RO)                       └─ Replica-2 (RO)

       externalClusters:                      externalClusters:
         - cluster-site-b                       - cluster-site-a

edb-app2-production                      edb-app2-production
  └─ cluster-site-a-app2 (3 reps)           └─ cluster-site-b-app2 (3 reps)
       ├─ Primary (RW)                          ├─ Designated Primary (RO)
       ├─ Replica-1 (RO)                       ├─ Replica-1 (RO)
       └─ Replica-2 (RO)                       └─ Replica-2 (RO)

edb-app3-production                      edb-app3-production
  └─ cluster-site-a-app3 (3 reps)           └─ cluster-site-b-app3 (3 reps)
       ├─ Primary (RW)                          ├─ Designated Primary (RO)
       ├─ Replica-1 (RO)                       ├─ Replica-1 (RO)
       └─ Replica-2 (RO)                       └─ Replica-2 (RO)
```

### 11.2 CNPG Distributed Topology YAML (Multiple Apps)

```yaml
# Site A - Primary Cluster for App1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-a-app1
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a-app1
    source: cluster-site-b-app1
  postgres:
    parameters:
      max_connections: "200"
      shared_buffers: "256MB"
      wal_level: "replica"
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-a
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-a
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-a-app1/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
  externalClusters:
    - name: cluster-site-b-app1
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: site-b-app1-backup
          serverName: cluster-site-b-app1
```

```yaml
# Site B - Replica Cluster for App1
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-site-b-app1
  namespace: edb-app1-production
spec:
  instances: 3
  replica:
    primary: cluster-site-a-app1
    source: cluster-site-a-app1
    self: cluster-site-b-app1
  bootstrap:
    pg_basebackup:
      source: cluster-site-a-app1
  storage:
    size: 100Gi
    storageClass: portworx-edb-site-b
  walStorage:
    size: 50Gi
    storageClass: portworx-edb-site-b
  backup:
    barmanObjectStore:
      destinationPath: "s3://edb-backups/site-b-app1/"
      endpointURL: "https://purestorage-objectstore.example.com"
      s3Credentials:
        accessKeyId:
          name: purestorage-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: purestorage-credentials
          key: ACCESS_SECRET_KEY
  externalClusters:
    - name: cluster-site-a-app1
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: site-a-app1-backup
          serverName: cluster-site-a-app1
```

### 11.3 Promotion: Replica Cluster → Primary Cluster

```bash
# ============================================================
# PROMOTE REPLICA CLUSTER TO PRIMARY CLUSTER
# ============================================================

# Step 1: Promote Designated Primary on Site B
oc config use-context site-b
oc exec -it edb-app1-replica-cluster-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_promote();"

# Step 2: Verify promotion
oc exec -it edb-app1-replica-cluster-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: f (not in recovery = primary)

# Step 3: Verify replicas are following
oc exec -it edb-app1-replica-cluster-2 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: t (in recovery = replica)

# Step 4: Update DNS/Route to point to Site B
oc patch route edb-app1-rw -n edb-app1-production \
  --type merge \
  -p '{"spec":{"to":{"name":"edb-app1-replica-cluster-rw"}}}'

# Step 5: Update Submariner ServiceExport
cat <<EOF | oc apply -f -
apiVersion: submariner.io/v1alpha1
kind: ServiceExport
metadata:
  name: edb-app1-replica-cluster-rw
  namespace: edb-app1-production
EOF

# Step 6: Verify Site B is serving traffic
oc exec -it edb-app1-replica-cluster-1 -n edb-app1-production -- \
  psql -U edb_admin -d edb_app1_db -c "SELECT pg_is_in_recovery();"
# Should return: f (primary)
```

### 11.4 Storage Allocation (Replica Cluster)

```
┌─────────────────────────────────────────────────────────────────┐
│                  PORTWORX STORAGE ALLOCATION                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Active PVs (Site A Local):                                    │
│   ──────────────────────────                                    │
│   • PV-App1-Data: A1 (local) + B2 (remote)                      │
│   • PV-App2-Data: A2 (local) + B3 (remote)                      │
│   • PV-App3-Data: A3 (local) + B1 (remote)                      │
│                                                                 │
│   Standby PVs (Site B Local):                                   │
│   ────────────────────────────                                  │
│   • PV-App1-Standby: B1 (local) + A2 (remote)                   │
│   • PV-App2-Standby: B2 (local) + A3 (remote)                   │
│   • PV-App3-Standby: B3 (local) + A1 (remote)                   │
│                                                                 │
│   Result:                                                       │
│   • Each app has local PV on both sites                         │
│   • Failover is instant (PV already local)                      │
│   • Storage distributed evenly across 6 nodes                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 12. Monitoring

### 12.1 Key Metrics

```
┌─────────────────────────────────────────────────────────────────┐
│                    MONITORING METRICS                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   EDB Metrics:                                                  │
│   ─────────────                                                 │
│   • pg_up                          (instance running?)          │
│   • pg_replication_lag_seconds     (replication lag)            │
│   • pg_stat_activity_count         (active connections)         │
│   • pg_database_size_bytes         (database size)              │
│   • pg_stat_database_xact_commit   (transactions)               │
│                                                                 │
│   Portworx Metrics:                                             │
│   ──────────────────                                            │
│   • portworx_volume_repl_state     (replication health)         │
│   • portworx_volume_repl_lag       (sync lag)                   │
│   • portworx_cluster_status        (cluster health)             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 12.2 Alert Rules

```
┌─────────────────────────────────────────────────────────────────┐
│                    CRITICAL ALERTS                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Alert                        Condition        Action          │
│   ─────                        ─────────        ──────          │
│   EDBPrimaryDown              pg_up == 0       Failover         │
│   EDBReplicationLagHigh       lag > 30s        Investigate      │
│   EDBConnectionsHigh          count > 180      Scale up         │
│   PortworxVolumeDegraded      repl != OK       Check storage    │
│   PortworxNodeDown            node unreachable  Check node      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 13. Summary

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    ARCHITECTURE SUMMARY                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Infrastructure:                                               │
│   • 2 OCP clusters (3 nodes each) = 6 nodes                     │
│   • Unified Portworx storage pool (6 NVMe)                      │
│   • EDB CloudNativePG operator                                  │
│                                                                 │
│   Storage Design:                                               │
│   • 2 Replicas per volume: 1 Local + 1 Remote                   │
│   • Active PVs: Local on Site A, Remote on Site B               │
│   • Standby PVs: Local on Site B, Remote on Site A              │
│   • Both sites always have fast local access                    │
│                                                                 │
│   Replication:                                                  │
│   • EDB streaming (database level) for consistency              │
│   • Portworx sync (storage level) for HA                        │
│   • Combined: Full coverage                                     │
│                                                                 │
│   Cross-Cluster Connectivity:                                   │
│   • Submariner (OCP native) for IPsec tunnel                   │
│   • Lighthouse for cross-cluster service discovery              │
│   • ServiceExport/Import for DB access across clusters          │
│                                                                 │
│   EDB Official Pattern:                                         │
│   • Single Availability Zone (2 data centers)                  │
│   • Replica Cluster model (not single standby)                 │
│   • CNPG cannot auto-failover across clusters (manual/GitOps) │
│                                                                 │
│   Failover (3 Layers):                                          │
│   • Layer 1: DB-Level (Section 6)                               │
│     - EDB streaming promote, RPO 5-30s, RTO 3-5 min            │
│   • Layer 2: Storage-Level (Section 9)                           │
│     - Portworx Metro failover, RPO near real-time, RTO 5-10 min│
│   • Layer 3: Backup Restore (Section 10)                        │
│     - PureStorage object store, RPO 5-15 min, RTO 15-60 min    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### RPO/RTO Targets (3-Layer Failover)

| Metric | Layer 1: DB-Level | Layer 2: Storage-Level | Layer 3: Backup Restore |
|--------|-------------------|----------------------|------------------------|
| RPO | 5-30 seconds | Near real-time | 5-15 minutes |
| RTO | 3-5 minutes | 5-10 minutes | 15-60 minutes |
| Trigger | EDB streaming broken | EDB broken, PX healthy | Both sites compromised |
| Consistency | Transaction-level | Block-level | Transaction-level |

### Key Benefits

```
1. Performance    - NVMe local access on both sites
2. Fast Failover  - PV already local, no migration
3. Data Safety    - 2 copies (local + remote)
4. Simplicity     - Standard EDB + Portworx
5. Scalability    - Add more EDB instances easily
6. 3-Layer DR     - DB + Storage + Backup, no single point of failure
7. Cross-Cluster  - Submariner for independent OCP clusters
```

---

*Document Version: 9.0*
*Created: 2026-08-27*
*Updated: 2026-09-15 - v9.0: Fixed cross-references (Section 10.9 + Summary), added .spec.replica to Section 11.2 Site A, corrected bootstrap source in 11.2 Site B, added conceptual disclaimer to Section 9.7, removed empty postgres: blocks*
*Author: Hermes Agent & Paul Wong*

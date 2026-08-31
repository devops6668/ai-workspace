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
- [8. Multiple EDB Instances](#8-multiple-edb-instances)
- [9. Monitoring](#9-monitoring)
- [10. Summary](#10-summary)

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
│   │  Node A1  │ │  Node A2  │ │  Node A3  │ │  Node B1  │ │  Node B2  │ │  Node B3  │   │ 
│   │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │ │   NVMe    │   │
│   └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘   │
│         │             │             │             │             │             │         │
│         └─────────────┴─────────────┘             └─────────────┴─────────────┘         │
│                       │                                         │                       │
│                       ▼                                         ▼                       │ 
│              ┌─────────────────┐                    ┌─────────────────┐                 │   
│              │  Active EDB PV  │                    │ Standby EDB PV  │                 │    
│              │                 │                    │                 │                 │
│              │  Replica 1: A1  │◄──── Sync ───────► │  Replica 1: B1  │                 │
│              │  (Local NVMe)   │                    │  (Local NVMe)   │                 │
│              │                 │                    │                 │                 │
│              │  Replica 2: B2  │◄──── Sync ───────► │  Replica 2: A2  │                 │
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

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SITE A (ACTIVE)                          SITE B (PASSIVE)                 │
│   ═══════════════                          ════════════════                 │
│                                                                             │
│   ┌───────────────────────────────────────────────────────────────────┐     │
│   │                        OCP Cluster A                              │     │
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
│   │                        OCP Cluster B                              │     │
│   │                                                                   │     │
│   │                      ┌─────────────┐                              │     │
│   │                      │   Standby   │                              │     │
│   │                      │    (RO)     │                              │     │
│   │                      └─────────────┘                              │     │
│   │                                                                   │     │
│   └───────────────────────────────────────────────────────────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Instance Allocation

| Site | Role | Instances | PV Location | StorageClass |
|------|------|-----------|-------------|--------------|
| Site A | Active | 3 (Primary + 2 Replicas) | Site A NVMe | portworx-edb-site-a |
| Site B | Passive | 1 (Standby) | Site B NVMe | portworx-edb-site-b |

---

## 5. Data Replication Strategy

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

## 8. Multiple EDB Instances

### 8.1 Namespace Pattern

```
Site A (Active):                          Site B (Passive):
──────────────                            ────────────────

edb-app1-production                       edb-app1-production
  └─ edb-app1-cluster (3 reps)             └─ edb-app1-standby (1 rep)

edb-app2-production                       edb-app2-production
  └─ edb-app2-cluster (3 reps)             └─ edb-app2-standby (1 rep)

edb-app3-production                       edb-app3-production
  └─ edb-app3-cluster (3 reps)             └─ edb-app3-standby (1 rep)
```

### 8.2 Storage Allocation

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

## 9. Monitoring

### 9.1 Key Metrics

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

### 9.2 Alert Rules

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

## 10. Summary

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
│   Failover:                                                     │
│   • Promote standby on Site B                                   │
│   • Update DNS/Route                                            │
│   • PV already local (no migration)                             │
│   • RTO: 3-5 minutes                                            │
│   • RPO: 5-30 seconds                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### RPO/RTO Targets

| Metric | Value | Notes |
|--------|-------|-------|
| RPO | 5-30 seconds | EDB streaming lag |
| RTO | 3-5 minutes | Promote + DNS update |
| Storage | 2x per volume | 1 local + 1 remote |
| Availability | 99.9%+ | Site-level DR |

### Key Benefits

```
1. Performance    - NVMe local access on both sites
2. Fast Failover  - PV already local, no migration
3. Data Safety    - 2 copies (local + remote)
4. Simplicity     - Standard EDB + Portworx
5. Scalability    - Add more EDB instances easily
```

---

*Document Version: 1.0*
*Created: 2026-08-27*
*Author: Hermes Agent & Paul Wong*

# OCP + ACM Upgrade Plan — Hub (VMWare) + 2 Bare Metal Managed Clusters

> **Document Date:** September 2026
> **Target:** OCP 4.20.30 / ACM 2.16 / MCE 2.11
> **Current:** OCP 4.19.17 / ACM 2.14.1 / MCE 2.9.7

---

## Table of Contents

- [Environment Overview](#environment-overview)
- [Target State](#target-state)
- [Version Compatibility Check](#version-compatibility-check)
- [Upgrade Sequence Summary](#upgrade-sequence-summary)
- [Phase 1: Upgrade ACM on Hub](#phase-1-upgrade-acm-on-hub)
- [Phase 2: Upgrade Hub OCP](#phase-2-upgrade-hub-ocp)
- [Phase 3: Upgrade ACM to 2.16](#phase-3-upgrade-acm-to-216)
- [Phase 4: Upgrade Managed Cluster 1](#phase-4-upgrade-managed-cluster-1)
- [Phase 5: Upgrade Managed Cluster 2](#phase-5-upgrade-managed-cluster-2)
- [Phase 6: Final Verification](#phase-6-final-verification)
- [Rollback Plan](#rollback-plan)
- [Known Issues During Upgrade](#known-issues-during-upgrade)
- [Pre-Upgrade Checklist](#pre-upgrade-checklist)

---

## Environment Overview

| Cluster | Type | Nodes | Current OCP | Current ACM | Current MCE |
|---------|------|-------|-------------|-------------|-------------|
| Hub | VMWare compact | 3 masters (no dedicated workers) | 4.19.17 | 2.14.1 | 2.9.7 |
| BM OCP1 | Bare metal compact | 3 masters (no dedicated workers) | 4.19.17 | — | — |
| BM OCP2 | Bare metal compact | 3 masters (no dedicated workers) | 4.19.17 | — | — |

**Cluster Topology:**
```
┌─────────────────────────────────────────────────────┐
│  Hub Cluster (VMWare)                               │
│  - 3-node compact (masters also run workloads)      │
│  - ACM 2.14.1 / MCE 2.9.7 / OCP 4.19.17           │
│  - Manages 2 bare metal clusters                    │
└──────────────┬──────────────────────┬───────────────┘
               │                      │
    ┌──────────▼──────────┐ ┌────────▼──────────────┐
    │ BM OCP1 (Bare Metal)│ │ BM OCP2 (Bare Metal)  │
    │ 3-node compact      │ │ 3-node compact        │
    │ OCP 4.19.17         │ │ OCP 4.19.17           │
    └─────────────────────┘ └───────────────────────┘
```

---

## Target State

| Cluster | Target OCP | Target ACM | Target MCE |
|---------|-----------|------------|------------|
| Hub | 4.20.30 | 2.16 | 2.11 |
| BM OCP1 | 4.20.30 | — | — |
| BM OCP2 | 4.20.30 | — | — |

---

## Version Compatibility Check

| ACM Version | MCE Version | OCP Support |
|-------------|-------------|-------------|
| ACM 2.14 | MCE 2.9 | OCP 4.16, 4.17, 4.18 |
| ACM 2.15 | MCE 2.10 | OCP 4.18, 4.19, 4.20 |
| ACM 2.16 | MCE 2.11 | OCP 4.19, 4.20, 4.21 |
| ACM 2.17 | MCE 2.12 | OCP 4.20, 4.21, 4.22 |

**Compatibility Notes:**
- ACM 2.14 officially supports up to OCP 4.18. Running OCP 4.19 with ACM 2.14 works but is beyond official support matrix.
- ACM 2.15+ properly supports OCP 4.20. **ACM must be upgraded to 2.15 before OCP 4.20 upgrade.**
- ACM 2.16 is the recommended target for OCP 4.20 (provides headroom for future OCP 4.21 upgrades).

---

## Upgrade Sequence Summary

```
┌─────────────────────────────────────────────────────────────┐
│  UPGRADE ORDER (DO NOT SKIP STEPS)                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Step 1: ACM 2.14 -> 2.15  (Hub, MCE 2.9 -> 2.10)         │
│          WHY: ACM 2.15 properly supports OCP 4.20           │
│                                                             │
│  Step 2: Hub OCP 4.19.17 -> 4.20.30                        │
│          WHY: Hub must be on target OCP before managed      │
│                                                             │
│  Step 3: ACM 2.15 -> 2.16  (Hub, MCE 2.10 -> 2.11)         │
│          WHY: Official OCP 4.20 support + future headroom   │
│                                                             │
│  Step 4: BM OCP1 4.19.17 -> 4.20.30                        │
│          WHY: First managed cluster, validate before second │
│                                                             │
│  Step 5: BM OCP2 4.19.17 -> 4.20.30                        │
│          WHY: Second managed cluster, same process          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Estimated Total Time:**
- Phase 1 (ACM upgrade): ~15-20 min
- Phase 2 (Hub OCP upgrade): ~45-60 min (3-node compact, one at a time)
- Phase 3 (ACM upgrade): ~15-20 min
- Phase 4 (BM OCP1 upgrade): ~45-60 min
- Phase 5 (BM OCP2 upgrade): ~45-60 min
- Phase 6 (Verification): ~15 min
- **Total: ~3-4 hours**

---

## Phase 1: Upgrade ACM on Hub

> **Goal:** Upgrade ACM 2.14.1 -> 2.15.x (MCE 2.9 -> 2.10)
> **Location:** Hub cluster (VMWare)
> **Why:** ACM 2.15 properly supports OCP 4.20. Must upgrade ACM before OCP.

### Step 1.1: Pre-Checks

```bash
# On hub cluster

# Check hub OCP is healthy
oc get clusteroperators
# All operators must show Available=True, Upgradeable=True

# Check managed clusters are connected
oc get managedclusters
# Both BM clusters must show Available=True

# Check ACM is healthy
oc get multiclusterhub -n open-cluster-management
# Status should be Running

# Check current ACM/MCE versions
oc get csv -n open-cluster-management
# Should show ACM 2.14.1, MCE 2.9.7
```

### Step 1.2: Upgrade ACM Subscription Channel

```bash
# Check current subscription
oc get subscription advanced-cluster-management \
  -n open-cluster-management -o yaml

# Patch to release-2.15 channel
oc patch subscription advanced-cluster-management \
  -n open-cluster-management \
  --type merge \
  -p '{"spec":{"channel":"release-2.15"}}'
```

### Step 1.3: Wait for ACM CSV Rollout

```bash
# Watch CSV rollout
oc get csv -n open-cluster-management -w

# Wait for new CSV to show phase=Succeeded
# This takes approximately 10-15 minutes
# Do NOT proceed until CSV shows Succeeded
```

### Step 1.4: Verify MCE Upgraded

```bash
# Verify MCE version
oc get multiclusterengine
# Should show version 2.10.x
```

### Step 1.5: Verify ACM Healthy

```bash
# Check MCH status
oc get multiclusterhub -n open-cluster-management
# Status should be Running

# Check all pods
oc get pods -n open-cluster-management
# All pods should be Running, no CrashLoopBackOff
```

### Step 1.6: Verify Managed Clusters Still Connected

```bash
# Check both BM clusters
oc get managedclusters
# Both should show Available=True

# If any cluster shows False, check klusterlet
oc get klusterlet -A
```

### Phase 1 Complete When:
- [ ] ACM CSV shows Succeeded
- [ ] MCE version is 2.10.x
- [ ] MCH status is Running
- [ ] Both managed clusters show Available=True
- [ ] No pods in CrashLoopBackOff

---

## Phase 2: Upgrade Hub OCP

> **Goal:** Upgrade Hub OCP 4.19.17 -> 4.20.30
> **Location:** Hub cluster (VMWare)
> **Why:** Hub must be on target OCP before upgrading managed clusters.

### Step 2.1: Check Available 4.20 Versions

```bash
# Check what 4.20.z versions are available
oc adm upgrade --to=4.20.30

# If 4.20.30 is not available, check available channels
oc adm upgrade --retrieve
# Or check cluster version available updates
oc get clusterversion -o yaml
```

### Step 2.2: Start Hub OCP Upgrade

```bash
# Initiate upgrade
oc adm upgrade --to=4.20.30

# For 3-node compact cluster, OCP upgrade handles
# one node at a time automatically via machine config pool
```

### Step 2.3: Monitor Hub Upgrade

```bash
# Watch cluster version progress
oc get clusterversion -w
# PROGRESSING=True during upgrade, then False when complete

# Watch node status (one node goes NotReady at a time)
oc get nodes -w
# Each node takes ~15-30 minutes to upgrade

# Watch cluster operators
oc get clusteroperators -w
# All operators must return to Available=True
```

**What Happens During Hub OCP Upgrade:**
```
  Node 1: NotReady -> Upgrading -> Ready (new version)
  Node 2: NotReady -> Upgrading -> Ready (new version)
  Node 3: NotReady -> Upgrading -> Ready (new version)

  Total time: ~45-60 minutes for 3-node compact cluster
```

### Step 2.4: Wait for Hub to Stabilize

```bash
# After clusterversion shows Completed, wait 5-10 minutes
# for all operators to stabilize

oc get clusteroperators | grep -v True
# Should return empty (all Available=True)

# Verify version
oc get clusterversion
# Should show 4.20.30
```

### Step 2.5: Verify Hub Health After Upgrade

```bash
# Check all pods are healthy
oc get pods -n open-cluster-management
# All Running

# Check managed clusters still connected
oc get managedclusters
# Both BM clusters Available=True

# Check no new alerts
# Open ACM console, check for warnings
```

### Phase 2 Complete When:
- [ ] Hub clusterversion shows 4.20.30
- [ ] All clusteroperators Available=True
- [ ] All nodes Ready
- [ ] ACM pods still Running
- [ ] Both managed clusters still Available=True

---

## Phase 3: Upgrade ACM to 2.16

> **Goal:** Upgrade ACM 2.15 -> 2.16 (MCE 2.10 -> 2.11)
> **Location:** Hub cluster (VMWare)
> **Why:** Official OCP 4.20 support + headroom for future OCP 4.21 upgrades.

### Step 3.1: CRITICAL — Check for Upgrade Blocker

> **WARNING:** ACM 2.15->2.16 has a MulticlusterRoleAssignment CRD change.
> Existing CRDs will cause the upgrade to fail. Must delete before upgrading.

```bash
# Check for any existing MulticlusterRoleAssignment resources
oc get multiclusterroleassignment --all-namespaces

# If ANY exist, delete them ALL:
oc delete multiclusterroleassignment --all --all-namespaces

# Verify none remain
oc get multiclusterroleassignment --all-namespaces
# Should return "No resources found"
```

### Step 3.2: Upgrade ACM Subscription Channel

```bash
# Patch to release-2.16 channel
oc patch subscription advanced-cluster-management \
  -n open-cluster-management \
  --type merge \
  -p '{"spec":{"channel":"release-2.16"}}'
```

### Step 3.3: Wait for ACM CSV Rollout

```bash
# Watch CSV rollout
oc get csv -n open-cluster-management -w

# Wait for new CSV to show phase=Succeeded
# This takes approximately 10-15 minutes
```

### Step 3.4: Verify MCE Upgraded

```bash
oc get multiclusterengine
# Should show version 2.11.x
```

### Step 3.5: Verify ACM Healthy

```bash
# Check MCH
oc get multiclusterhub -n open-cluster-management
# Status=Running

# Check pods
oc get pods -n open-cluster-management
# All Running

# Check managed clusters
oc get managedclusters
# Both BM clusters Available=True
```

### Step 3.6: Check for Console Warning (Cosmetic)

```bash
# ACM 2.16 may show a console warning about MCE version
# This is cosmetic and can be ignored:
# "ACM in unexpected configuration: MCE 2.11.x is ahead..."

# Verify MCE is actually working fine
oc get multiclusterengine -o yaml
# Check status conditions, all should be True
```

### Phase 3 Complete When:
- [ ] No MulticlusterRoleAssignment CRDs remain
- [ ] ACM CSV shows Succeeded
- [ ] MCE version is 2.11.x
- [ ] MCH status is Running
- [ ] Both managed clusters still Available=True
- [ ] No pods in CrashLoopBackOff

---

## Phase 4: Upgrade Managed Cluster 1

> **Goal:** Upgrade BM OCP1 4.19.17 -> 4.20.30
> **Location:** BM OCP1 (bare metal)
> **Why:** First managed cluster — validate before upgrading second.

### Step 4.1: Check Cluster1 Status

```bash
# From hub cluster
oc get managedcluster <cluster1-name> -o yaml
# STATUS.Conditions must show Available=True

# Check cluster health
oc get clustercurator -n <cluster1-namespace>
```

### Step 4.2: Determine Upgrade Method

**Option A: ACM Console (preferred if available)**
```
1. Open ACM console
2. Navigate to Infrastructure > Clusters
3. Select cluster1
4. Click "Upgrade" button
5. Select target version 4.20.30
6. Confirm upgrade
```

**Option B: ACM CLI (if console not available)**
```bash
# Get cluster kubeconfig from hub
oc get secret -n <cluster1-namespace> \
  <cluster1>-admin-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/cluster1-kubeconfig

# Use cluster kubeconfig to trigger upgrade
export KUBECONFIG=/tmp/cluster1-kubeconfig
oc adm upgrade --to=4.20.30
```

**Option C: Manual SSH (if ACM can't manage bare metal upgrade)**
```bash
# SSH to master nodes one by one
# On master node 1:
ssh core@<master1-ip>
sudo upgrade --to=4.20.30

# OR if using MachineConfigPool approach:
oc adm upgrade --to=4.20.30
```

### Step 4.3: Monitor Cluster1 Upgrade

```bash
# From hub cluster — watch managed cluster status
oc get managedcluster <cluster1-name> -o yaml
# Check STATUS.version.kubernetes updates to 4.20.30

# Watch nodes on managed cluster
oc get nodes -w
# Each node goes NotReady during upgrade (~15-30 min)

# Watch clusteroperators
oc get clusteroperators -w
# All must return to Available=True
```

**What Happens During 3-Node Compact OCP Upgrade:**
```
  Node 1: NotReady -> Upgrading -> Ready (4.20.30)
    (etcd quorum maintained: 2 of 3 nodes up)
  Node 2: NotReady -> Upgrading -> Ready (4.20.30)
    (etcd quorum maintained: 2 of 3 nodes up)
  Node 3: NotReady -> Upgrading -> Ready (4.20.30)
    (etcd quorum maintained: 2 of 3 nodes up)

  Total time: ~45-60 minutes
```

### Step 4.4: Wait for Cluster1 to Stabilize

```bash
# After all nodes are Ready with new version
oc get clusterversion
# Should show 4.20.30

oc get clusteroperators | grep -v True
# Should return empty

oc get nodes
# All Ready, version 4.20.30
```

### Step 4.5: Verify Cluster1 Health

```bash
# From hub cluster
oc get managedcluster <cluster1-name> -o yaml
# STATUS.Conditions Available=True

# Check cluster operators
oc get clusteroperators
# All Available=True

# Open ACM console, verify cluster1 shows Ready
```

### Phase 4 Complete When:
- [ ] Cluster1 clusterversion shows 4.20.30
- [ ] All clusteroperators Available=True
- [ ] All nodes Ready
- [ ] ManagedCluster Available=True
- [ ] ACM console shows cluster1 as Ready

---

## Phase 5: Upgrade Managed Cluster 2

> **Goal:** Upgrade BM OCP2 4.19.17 -> 4.20.30
> **Location:** BM OCP2 (bare metal)
> **Why:** Same process as Phase 4 — second managed cluster.

### Step 5.1-5.5: Same as Phase 4

Repeat all steps from Phase 4 for BM OCP2.

```bash
# Verify cluster2 status first
oc get managedcluster <cluster2-name> -o yaml
# Available=True before starting upgrade
```

### Phase 5 Complete When:
- [ ] Cluster2 clusterversion shows 4.20.30
- [ ] All clusteroperators Available=True
- [ ] All nodes Ready
- [ ] ManagedCluster Available=True
- [ ] ACM console shows cluster2 as Ready

---

## Phase 6: Final Verification

> **Goal:** Verify entire fleet is healthy and consistent.

### Step 6.1: Check All Cluster Versions

```bash
oc get managedclusters -o custom-columns=\
NAME:.metadata.name,\
OCP:.status.version.kubernetes,\
ACM:.status.conditions[0].type
```

Expected output:
```
NAME            OCP        ACM
local-cluster   4.20.30    Available
bm-cluster-1    4.20.30    Available
bm-cluster-2    4.20.30    Available
```

### Step 6.2: Check ACM Versions

```bash
oc get csv -n open-cluster-management
# Should show ACM 2.16.x, MCE 2.11.x

oc get multiclusterengine
# Should show version 2.11.x
```

### Step 6.3: Check Hub OCP

```bash
oc get clusterversion
# Should show 4.20.30

oc get clusteroperators
# All Available=True
```

### Step 6.4: Check All Nodes

```bash
oc get nodes
# Hub: all Ready, version 4.20.30
```

For managed clusters:
```bash
# On each managed cluster
oc get nodes
# All Ready, version 4.20.30
```

### Step 6.5: Check ACM Console

```
1. Open ACM console
2. Verify ALL clusters show as Ready
3. Check Governance compliance status
4. Check Observability dashboards working
5. Check no new alerts or warnings
6. Verify search functionality
```

### Step 6.6: Run Health Checks

```bash
# Check for any degraded operators
oc get clusteroperators | grep -E "True.+False"
# Should return empty

# Check for any failed pods
oc get pods -A | grep -E "CrashLoopBackOff|Error|ImagePullBackOff"
# Should return empty

# Check etcd health (hub)
oc get etcd -o=jsonpath='{.items[0].status.conditions[0]}'
# Should show type=Available, status=True
```

### Phase 6 Complete When:
- [ ] All 3 clusters show OCP 4.20.30
- [ ] ACM 2.16.x / MCE 2.11.x
- [ ] All clusteroperators Available=True
- [ ] All nodes Ready across all clusters
- [ ] ACM console shows all clusters Ready
- [ ] No degraded operators
- [ ] No pods in error states

---

## Rollback Plan

### ACM Rollback

> **WARNING:** ACM rollback is complex and may not always be possible.
> Always take a backup before upgrading.

```bash
# Backup ACM resources before upgrade
oc get multiclusterhub -n open-cluster-management -o yaml > mch-backup.yaml
oc get subscription advanced-cluster-management -n open-cluster-management -o yaml > sub-backup.yaml

# To rollback ACM channel (if needed):
oc patch subscription advanced-cluster-management \
  -n open-cluster-management \
  --type merge \
  -p '{"spec":{"channel":"release-2.15"}}'
# Wait for CSV to roll back

# NOTE: ACM rollback may leave MCE in inconsistent state
# If MCE is stuck, delete and recreate:
oc delete multiclusterengine --all
# Wait for ACM to recreate it
```

### OCP Rollback

> **WARNING:** OCP rollback is complex. Only use if absolutely necessary.

```bash
# If upgrade is in progress and you need to stop it:
oc adm upgrade --to=<previous-version>

# If upgrade completed and you need to rollback:
# This requires reinstalling previous version on all nodes
# Contact Red Hat support for assistance
```

### Best Practice: Backup Before Upgrade

```bash
# Take etcd backup on hub
oc get secret -n openshift-etcd etcd-peer \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/etcd-peer.crt

# Backup ACM resources
oc get mch -A -o yaml > mch-backup.yaml
oc get managedclusters -o yaml > managed-clusters-backup.yaml
oc get placement -A -o yaml > placement-backup.yaml
```

---

## Known Issues During Upgrade

### 1. ACM 2.15->2.16: MulticlusterRoleAssignment CRD Change

> **Issue:** MulticlusterRoleAssignment CRDs from ACM 2.15 are incompatible
> with ACM 2.16. Upgrade will fail if not deleted first.

```bash
# Check
oc get multiclusterroleassignment --all-namespaces

# Fix (delete before upgrade)
oc delete multiclusterroleassignment --all --all-namespaces
```

### 2. ACM 2.16->2.17: kubevirt-hyperconverged Add-on Stuck

> **Issue:** kubevirt-hyperconverged add-on may get stuck during
> ACM 2.16->2.17 upgrade due to operatorpolicies RBAC error.

```bash
# Check
oc get clustermanagementaddon kubevirt-hyperconverged

# Fix: delete and recreate as v1beta1
oc get clustermanagementaddon kubevirt-hyperconverged \
  -o jsonpath='{.metadata.labels.installer\.namespace}'
oc delete clustermanagementaddon kubevirt-hyperconverged
# Recreate as v1beta1
```

### 3. Console Warning: MCE Version Mismatch

> **Issue:** ACM 2.16 console may show warning about MCE version
> being ahead of expected channel. This is cosmetic.

```
"ACM in unexpected configuration: MCE 2.11.x is ahead of
the expected stable-2.11 channel"
```

**Action:** Ignore — MCE 2.11.x works correctly with ACM 2.16.

### 4. 3-Node Compact Cluster: etcd Quorum During Upgrade

> **Issue:** During OCP upgrade, one node goes NotReady at a time.
> etcd quorum requires 2 of 3 nodes.

**Action:** OCP upgrade handles this automatically — one node at a time.
Do NOT manually trigger multiple node upgrades simultaneously.

### 5. Bare Metal Clusters: ACM May Not Manage OCP Upgrade

> **Issue:** ACM console may not support OCP upgrade for bare metal
> managed clusters directly.

**Action:** Use CLI or SSH to master nodes if ACM console upgrade
button is not available for bare metal clusters.

### 6. 2.16 Upgrade: Manual Alert Forwarding Fails

> **Issue:** After ACM 2.15+ upgrade, manual alert forwarding may
> fail due to secret name changes.

```bash
# Check
oc get secret -n open-cluster-management | grep alert

# Fix: recreate the alert forwarding secret
# See ACM 2.16 release notes for exact steps
```

---

## Pre-Upgrade Checklist

### Before Starting Any Upgrade

- [ ] Read this entire document
- [ ] Verify current versions match documented state
- [ ] Take etcd backup on hub cluster
- [ ] Backup ACM resources (MCH, managed clusters, placements)
- [ ] Verify all managed clusters are connected (Available=True)
- [ ] Check cluster operators are all Available=True
- [ ] Verify no pending upgrades: `oc adm upgrade`
- [ ] Checkdisk space on all nodes: `df -h`
- [ ] Check node resource usage: `oc top nodes`
- [ ] Verify network connectivity between hub and managed clusters
- [ ] Check ACM console for any existing warnings/alerts
- [ ] Notify stakeholders of maintenance window
- [ ] Have rollback plan ready
- [ ] Test in non-production environment first if possible

### Day of Upgrade

- [ ] Confirm no ongoing operations on clusters
- [ ] Verify backup completed successfully
- [ ] Have Red Hat support case number ready (if needed)
- [ ] Monitor upgrade progress continuously
- [ ] Do NOT leave upgrades unattended

---

## References

- [OCP 4.20 Release Notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/release_notes/ocp-4-20-release-notes)
- [ACM 2.15 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/release_notes/acm-release-notes)
- [ACM 2.16 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/release_notes/acm-release-notes)
- [Red Hat ACM Support Matrix](https://access.redhat.com/articles/7120842)
- [OCP Upgrade Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/updating_clusters)
- [ACM Upgrade Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/install/upgrading)

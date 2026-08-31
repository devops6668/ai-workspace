# Longhorn Upgrade Guide: v1.8.2 → v1.12.1

## Table of Contents

- [Overview](#overview)
- [Supported Upgrade Path](#supported-upgrade-path)
- [RKE2 Version Support Matrix](#rke2-version-support-matrix)
- [RKE2 Upgrade Requirement](#rke2-upgrade-requirement-for-longhorn-v1113-and-v1121)
- [Prerequisites](#prerequisites)
- [Pre-Upgrade Checklist](#pre-upgrade-checklist)
- [Phase 1: v1.8.2 → v1.9.x](#phase-1-v182--v19x)
- [Phase 2: v1.9.x → v1.10.x](#phase-2-v19x--v110x)
- [Phase 3: v1.10.x → v1.11.x](#phase-3-v110x--v111x)
- [Phase 4: v1.11.x → v1.12.1](#phase-4-v111x--v1121)
- [Post-Upgrade Verification](#post-upgrade-verification)
- [Rollback Plan](#rollback-plan)
- [Troubleshooting](#troubleshooting)

---

## Overview

This guide covers upgrading Longhorn from **v1.8.2** to **v1.12.1** (latest stable) on **RKE2 v1.32.7+rke2r1** (Kubernetes v1.32.7). This is a 4-step sequential upgrade — **you cannot skip minor versions**.

> ⚠️ **IMPORTANT**: RKE2 v1.32.7 (K8s v1.32.7) only supports Longhorn up to **v1.11.2**.
> Longhorn v1.11.3 and v1.12.1 require **K8s v1.34+**. You must upgrade RKE2 to v1.34.2+ before Phase 3 and Phase 4.

| Upgrade | Version Change | Risk Level | RKE2 Required | Estimated Time |
|---------|---------------|------------|---------------|---------------|
| Phase 1 | v1.8.2 → v1.9.x | Medium | v1.32.7 ✓ | 15-30 min |
| Phase 2 | v1.9.x → v1.10.x | **HIGH** (CRD migration) | v1.32.7 ✓ | 30-60 min |
| **Phase 2.5** | **RKE2 v1.32.7 → v1.34.2+** | **Medium** | **Must do before Phase 3** | **30-60 min** |
| Phase 3 | v1.10.x → v1.11.x | Medium | v1.34.2+ ✓ | 15-30 min |
| Phase 4 | v1.11.x → v1.12.1 | Medium | v1.34.2+ ✓ | 15-30 min |

**Total estimated time**: 3-5 hours including RKE2 upgrade and verification between phases

---

## CRD Impact Quick Reference

> All CRD changes across the upgrade path at a glance.

| Phase | CRD Change | Risk | CRDs Affected |
|-------|-----------|------|---------------|
| Phase 1 (→v1.9) | Deprecated v1beta2 fields removed | LOW | Settings, Volume, Replica, Engine (internal fields) |
| Phase 1 (→v1.9) | `orphan-auto-deletion` renamed | LOW | Settings (auto-migrated) |
| Phase 2 (→v1.10) | **v1beta1 API REMOVED** | **HIGH** | ALL 16 Longhorn CRDs |
| Phase 2 (→v1.10) | `replica.status.evictionRequested` removed | LOW | Replica |
| Phase 2 (→v1.10) | New fields added (`backupBlockSize`, etc.) | MEDIUM | Volume (bug #12812) |
| Phase 3 (→v1.11) | V2 Backing Image deprecated | LOW | BackingImage |
| Phase 4 (→v1.12) | V2 Backing Images REMOVED | MEDIUM | BackingImage |
| Phase 4 (→v1.12) | Internal NetworkPolicies added | LOW | NetworkPolicy (new) |
| Phase 4 (→v1.12) | mTLS extended to ALL gRPC | LOW | InstanceManager |

**Key commands to check CRD state before any phase**:

```bash
# Check storedVersions for all Longhorn CRDs
kubectl get crd -o json | python3 -c "
import sys, json
for c in json.load(sys.stdin)['items']:
    if 'longhorn.io' in c['metadata']['name']:
        sv = c.get('status',{}).get('storedVersions',[])
        print(f'{c[\"metadata\"][\"name\"]}: {sv}')
"

# Check for deprecated fields in use
kubectl get replicas.longhorn.io -n longhorn-system -o json | \
  python3 -c "
import sys, json
for r in json.load(sys.stdin).get('items',[]):
    ev = r.get('status',{}).get('evictionRequested')
    if ev is not None:
        print(f'WARNING: {r[\"metadata\"][\"name\"]} has evictionRequested={ev}')
print('Replica field check complete')
"
```

---

## Supported Upgrade Path

```
v1.8.2 → v1.9.x → v1.10.x → v1.11.x → v1.12.1
```

Longhorn enforces sequential minor-version upgrades. Skipping a version will be **rejected** by the upgrade checker.

### Recommended Target Versions

| Step | Target | Why |
|------|--------|-----|
| Phase 1 | **v1.9.1** (or latest v1.9 patch) | v1.9.0 had a regression in longhorn-manager (recurring jobs) |
| Phase 2 | **v1.10.1** (or latest v1.10 patch) | v1.10.0 had a regression (share-manager nil pointer panic) |
| Phase 3 | **v1.11.3** (latest) | v1.11.0 had two regressions; v1.11.3 is stable |
| Phase 4 | **v1.12.1** (latest) | First patch release, includes all hotfixes |

---

## RKE2 Version Support Matrix

### Longhorn + RKE2 Compatibility

Based on the SUSE official support matrix, here is the compatibility between Longhorn versions and RKE2:

| Longhorn Version | Min K8s | Supported RKE2 Versions | Notes |
|-----------------|---------|------------------------|-------|
| **v1.8.x** | v1.25 | v1.25.17+rke2r1+ and later | EOL: 03 Mar 2026 |
| **v1.9.x** | v1.25 | v1.25.17+rke2r1+ and later | Community release |
| **v1.10.x** | v1.25 | v1.25.17+rke2r1+ and later | Community release |
| **v1.11.x** | v1.25 | v1.25.17+rke2r1+ and later | v1.11.3 requires K8s v1.34+ |
| **v1.12.x** | v1.25 | v1.25.17+rke2r1+ and later | v1.12.1 requires K8s v1.34+ |

### RKE2 v1.33 Support Matrix (Latest Stable)

| Component | Version | Architecture |
|-----------|---------|-------------|
| Kubernetes | v1.33.13 | x86_64, arm64 |
| RKE2 | v1.33.13+rke2r2 | x86_64, arm64 |
| Containerd | v2.2.6-k3s1 | - |
| Runc | v1.4.3 | - |
| CNI: Canal | Flannel v0.28.8, Calico v3.32.1 | - |
| CNI: Calico | v3.32.1 | - |
| CNI: Cilium | v1.19.6 | - |
| Traefik | v3.7.8 | - |
| Ingress-Nginx | v1.15.1-prime9 | - |

**Verified OS for RKE2 v1.33**:
- SLES 15 SP4/SP5/SP6/SP7
- SLE Micro 5.4/5.5/6.0/6.1
- openSUSE Leap 15.4/15.5/15.6
- RHEL 8.8-10.2
- Rocky Linux 8.8-9.5
- Oracle Linux 8.8-9.5
- Ubuntu 20.04/22.04/24.04
- Amazon Linux 2/2023

### RKE2 v1.32 Support Matrix

| Component | Version | Architecture |
|-----------|---------|-------------|
| Kubernetes | v1.32.13 | x86_64, arm64 |
| RKE2 | v1.32.13+rke2r1 | x86_64, arm64 |
| Containerd | v2.1.5-k3s1 | - |
| Runc | v1.4.0 | - |
| CNI: Canal | Flannel v0.28.1, Calico v3.31.3 | - |
| CNI: Calico | v3.31.3 | - |
| CNI: Cilium | v1.19.1 | - |
| Traefik | v3.6.9 | - |

### Longhorn + RKE2 + CNI Compatibility

| CNI Plugin | Longhorn 1.8 | Longhorn 1.9 | Longhorn 1.10 | Longhorn 1.11 | Longhorn 1.12 |
|-----------|-------------|-------------|--------------|--------------|--------------|
| Canal (Flannel+Calico) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Calico | ✓ | ✓ | ✓ | ✓ | ✓ |
| Cilium | ✓ | ✓ | ✓ | ✓ | ✓ |
| Flannel | ✓ | ✓ | ✓ | ✓ | ✓ |

> **Note**: Longhorn 1.12.1 enables internal NetworkPolicies by default. Ensure your CNI supports NetworkPolicy enforcement. Canal, Calico, and Cilium all support it. Flannel alone does NOT.

### Longhorn + Rancher Compatibility

| Rancher Version | Longhorn Versions |
|----------------|-------------------|
| v2.14.x | v1.8.x, v1.9.x, v1.10.x, v1.11.x, v1.12.x |
| v2.13.x | v1.8.x, v1.9.x, v1.10.x, v1.11.x |
| v2.12.x | v1.8.x, v1.9.x, v1.10.x |
| v2.11.x | v1.8.x, v1.9.x, v1.10.x |

---

## RKE2 Version Support Matrix

### Your Environment

- **RKE2**: v1.32.7+rke2r1 (Kubernetes v1.32.7)
- **Platform**: Rancher v2.14.3
- **CNI**: Canal (Flannel + Calico) — NetworkPolicy supported ✓

### Longhorn + RKE2 Compatibility

Based on the SUSE official support matrix, here is the compatibility between Longhorn versions and RKE2:

| Longhorn Version | Min K8s | Supported RKE2 Versions | Your RKE2 v1.32.7 |
|-----------------|---------|------------------------|-------------------|
| **v1.8.x** | v1.25 | v1.25.17+rke2r1+ | ✓ Compatible |
| **v1.9.x** | v1.25 | v1.25.17+rke2r1+ | ✓ Compatible |
| **v1.10.x** | v1.25 | v1.25.17+rke2r1+ | ✓ Compatible |
| **v1.11.x** | v1.25 | v1.25.17+rke2r1+ | ⚠️ v1.11.3 needs K8s v1.34+ |
| **v1.12.x** | v1.25 | v1.25.17+rke2r1+ | ⚠️ v1.12.1 needs K8s v1.34+ |

> **Key constraint**: RKE2 v1.32.7 = K8s v1.32.7. Longhorn v1.11.3 and v1.12.1 require K8s v1.34+.
> You must upgrade RKE2 to v1.34.2+ before upgrading to Longhorn v1.11.3 or v1.12.1.

### RKE2 v1.34 Component Versions (Target for RKE2 Upgrade)

| Component | Version | Architecture |
|-----------|---------|-------------|
| Kubernetes | v1.34.x | x86_64, arm64 |
| RKE2 | v1.34.x+rke2rX | x86_64, arm64 |
| Containerd | v2.x-k3s1 | - |
| Runc | v1.4.x | - |
| CNI: Canal | Flannel + Calico | - |
| CNI: Cilium | v1.19.x | - |
| Traefik | v3.x | - |

### Longhorn + RKE2 + CNI Compatibility

| CNI Plugin | Longhorn 1.8 | Longhorn 1.9 | Longhorn 1.10 | Longhorn 1.11 | Longhorn 1.12 |
|-----------|-------------|-------------|--------------|--------------|--------------|
| Canal (Flannel+Calico) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Calico | ✓ | ✓ | ✓ | ✓ | ✓ |
| Cilium | ✓ | ✓ | ✓ | ✓ | ✓ |
| Flannel | ✓ | ✓ | ✓ | ✓ | ✓ |

> **Note**: Longhorn 1.12.1 enables internal NetworkPolicies by default. Ensure your CNI supports NetworkPolicy enforcement. Canal, Calico, and Cilium all support it. Flannel alone does NOT.

### Longhorn + Rancher Compatibility

| Rancher Version | Longhorn Versions |
|----------------|-------------------|
| v2.14.x | v1.8.x, v1.9.x, v1.10.x, v1.11.x, v1.12.x |
| v2.13.x | v1.8.x, v1.9.x, v1.10.x, v1.11.x |
| v2.12.x | v1.8.x, v1.9.x, v1.10.x |
| v2.11.x | v1.8.x, v1.9.x, v1.10.x |

---

## RKE2 Upgrade Requirement for Longhorn v1.11.3 and v1.12.1

### The Problem

Your current RKE2 version is **v1.32.7+rke2r1** (Kubernetes v1.32.7). Longhorn v1.11.3 and v1.12.1 require **Kubernetes v1.34+** due to:

- **v1.11.3**: CSI external provisioner upgraded to v6.3.0 (requires K8s v1.34+)
- **v1.12.1**: CSI external snapshotter upgraded to v8.2.0 (requires K8s v1.34+)

### Supported Upgrade Paths

RKE2 only allows upgrades from one minor version to the next. You cannot skip versions.

```
v1.32.7 → v1.34.2+ (skip v1.33.x)
```

Actually, RKE2 follows Kubernetes versioning which allows minor version skips for some upgrades, but the safest path is:

```
v1.32.7 → v1.33.x → v1.34.2+
```

### Recommended RKE2 Upgrade Path

| Step | From | To | Notes |
|------|------|----|-------|
| 1 | v1.32.7+rke2r1 | v1.33.13+rke2r2 | Latest v1.33 stable |
| 2 | v1.33.13+rke2r2 | v1.34.2+rke2r1+ | Latest v1.34 stable |

### RKE2 Upgrade Procedure

> ⚠️ **RKE2 upgrades should be done BEFORE Phase 3 (Longhorn v1.11.x)**

#### Step 1: Upgrade RKE2 v1.32.7 → v1.33.13

```bash
# On the RKE2 server node:
# 1. Check current version
rke2 --version
# Expected: v1.32.7+rke2r1

# 2. Stop RKE2 (if single-node)
systemctl stop rke2-server

# 3. Install new version
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.33.13+rke2r2 sh -

# 4. Start RKE2
systemctl start rke2-server

# 5. Wait for node to be Ready
kubectl get nodes -w
# Wait for node to show "Ready" status

# 6. Verify version
rke2 --version
# Expected: v1.33.13+rke2r2
kubectl version --short
# Expected: Server: v1.33.13+rke2r2

# 7. Verify all pods are healthy
kubectl get pods -A | grep -v Running | grep -v Completed
# Should be empty or show only non-critical issues
```

#### Step 2: Upgrade RKE2 v1.33.13 → v1.34.2+

```bash
# On the RKE2 server node:
# 1. Check available v1.34 versions
# Visit https://github.com/rancher/rke2/releases for latest v1.34 patch

# 2. Stop RKE2
systemctl stop rke2-server

# 3. Install new version (use latest v1.34 patch)
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.34.2+rke2r1 sh -

# 4. Start RKE2
systemctl start rke2-server

# 5. Wait for node to be Ready
kubectl get nodes -w

# 6. Verify version
rke2 --version
kubectl version --short

# 7. Verify all pods are healthy
kubectl get pods -A | grep -v Running | grep -v Completed
```

#### Post-RKE2 Upgrade Verification

```bash
# Verify node status
kubectl get nodes -o wide

# Verify all system pods
kubectl get pods -n kube-system

# Verify Longhorn is still healthy
kubectl get pods -n longhorn-system
kubectl get volumes.longhorn.io -n longhorn-system -o wide

# Verify etcd health (if using external etcd)
# rke2 etcd-snapshot list

# Check for any issues in RKE2 logs
journalctl -u rke2-server --since "10 minutes ago" | grep -i error
```

### When to Upgrade RKE2

**Recommended order**:

```
Phase 1: Longhorn v1.8.2 → v1.9.1       (RKE2 v1.32.7 OK)
Phase 2: Longhorn v1.9.1 → v1.10.1      (RKE2 v1.32.7 OK)
Phase 2.5: RKE2 v1.32.7 → v1.34.2+     (MUST do before Phase 3)
Phase 3: Longhorn v1.10.1 → v1.11.3     (needs K8s v1.34+)
Phase 4: Longhorn v1.11.3 → v1.12.1     (needs K8s v1.34+)
```

> **Alternative**: You could upgrade RKE2 first (before any Longhorn upgrades), but it's safer to do Longhorn phases 1-2 first to get the CRD migration done, then upgrade RKE2, then continue with Longhorn phases 3-4.

---

## Prerequisites

1. **Kubernetes**: v1.25+ required (v1.34+ for v1.11.3 and v1.12.1)
   - **Your RKE2 v1.32.7**: ✓ for Phases 1-2, ✗ for Phases 3-4 (need RKE2 v1.34.2+)
2. **RKE2**: Plan upgrade from v1.32.7 → v1.34.2+ before Phase 3
3. **Longhorn**: v1.8.2 installed and healthy
4. **Backup**: Full backup of ALL Longhorn volumes before starting
5. **Maintenance window**: Plan 3-5 hours including RKE2 upgrade
6. **Helm or kubectl**: Know your installation method
7. **CNI**: Must support NetworkPolicy for v1.12.1 (Canal supports it ✓)

### Check Installation Method

```bash
# Check if installed via Helm
helm list -n longhorn-system

# Check if installed via kubectl
kubectl get deploy -n longhorn-system longhorn-manager

# Check current RKE2 version
rke2 --version
# Expected: v1.32.7+rke2r1
```

---

## Pre-Upgrade Checklist

Execute these checks before starting:

```bash
# 1. Verify current Longhorn version
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: longhornio/longhorn-manager:v1.8.2

# 2. Verify Kubernetes version (must be v1.25+, v1.34+ for final target)
kubectl version --short | grep Server
# Must be v1.25+ (you have v1.34.1 ✓)

# 3. Check all volumes are healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide
# All should show "Healthy" status

# 4. Check all replicas are healthy
kubectl get replicas.longhorn.io -n longhorn-system -o wide
# All should show "Healthy" status

# 5. Check for V2 backing images (CRITICAL for Phase 4)
kubectl get backingimages.longhorn.io -n longhorn-system
# If any exist and use V2 engine, they MUST be migrated before Phase 4

# 6. Check current CRD API versions
kubectl get crd volumes.longhorn.io -o jsonpath='{.status.storedVersions}'
# May show ["v1beta1"] or ["v1beta1","v1beta2"] at v1.8.x

# 7. Verify Longhorn system is ready
kubectl get pods -n longhorn-system -o wide
# All pods should be Running/Completed

# 8. Check backup target connectivity
kubectl get backuptargets.longhorn.io -n longhorn-system

# 9. Check CNI plugin (need NetworkPolicy support for v1.12.1)
kubectl get pods -n kube-system | grep -E 'calico|cilium|canal|flannel'

# 10. Check disk space on all nodes
df -h /var/lib/longhorn/
```

### Backup All Volumes

```bash
# Option A: Via Longhorn UI
# Go to Backup tab → Create Backup for each volume

# Option B: Create a recurring backup job to ensure all are backed up
# Go to Recurring Job → Create → Type: Backup → Schedule: Run Now

# Option C: Export Longhorn settings
kubectl get settings.longhorn.io -n longhorn-system -o yaml > longhorn-settings-pre-upgrade.yaml
```

---

## Phase 1: v1.8.2 → v1.9.x

**Target**: v1.9.1 (or latest v1.9 patch)
**Risk**: Medium
**Duration**: ~15-30 minutes

### What Changed in v1.9.0

#### Breaking Changes

| Change | Details | Action Required |
|--------|---------|-----------------|
| `environment_check.sh` removed | Deprecated in v1.7.0, fully removed in v1.9.0 | Use `longhornctl` instead |
| `orphan-auto-deletion` renamed | Replaced by `orphan-resource-auto-deletion` | Automatic migration during upgrade |
| Deprecated v1beta2 fields removed | Fields removed from CRDs (see details below) | No action needed |
| v1beta1 API marked unserved | Still present but unserved | No action yet (removed in v1.10) |

#### CRD Impact Details — Deprecated Fields Removed (Issue #6684)

**What was removed**: Deprecated fields from v1beta2 CRDs that were already unused/non-functional in v1.8.x. These fields were marked deprecated in earlier versions and are now fully removed from the CRD schemas.

**Affected CRDs and fields**:

| CRD | Deprecated Field Removed | Was It Used? | Impact |
|-----|------------------------|-------------|--------|
| **Settings** | `orphan-auto-deletion` | Yes (renamed) | Auto-migrated to `orphan-resource-auto-deletion` |
| **Volume** | `spec.image` (old engine image field) | No (internal) | Internal reference, no user impact |
| **Replica** | Various internal status fields | No | Internal bookkeeping, no user impact |
| **Engine** | Deprecated status sub-fields | No | Internal reference fields |

**Who is affected**: Only users who have custom scripts/tools that directly read Longhorn CRDs and use the deprecated fields. Standard Kubernetes workloads using PVC/PV are NOT affected.

**How to check if you're affected**:

```bash
# Check if any of your volumes use the old orphan-auto-deletion setting
kubectl get settings.longhorn.io orphan-auto-deletion -n longhorn-system 2>/dev/null
# If it exists, it will be auto-migrated during upgrade

# Check for any custom tooling that reads Longhorn CRDs directly
# If you have scripts that parse Volume/Replica CRDs, review them
```

**Risk assessment**: **LOW** — These were already deprecated/unused fields. The auto-migration handles the setting rename. No data loss or operational impact expected.

#### New Features

| Feature | Description | Impact |
|---------|-------------|--------|
| **Offline Replica Rebuilding** | Degraded volumes auto-recover replicas while detached | Reduces manual recovery steps |
| **Orphaned Instance Deletion** | Track and remove leftover engine/replica instances | Reduces resource waste |
| **Recurring System Backup** | Create recurring jobs for system backup | Improved DR capabilities |
| **V2 Data Engine Improvements** | Significant core function improvements | Better V2 stability |
| **Improved Prometheus Metrics** | New metrics for Replica, Engine, and Rebuild status | Better observability |
| **Orphan Resource Auto-Deletion** | More granular control over orphan cleanup | Better resource management |

#### Bug Fixes (Highlights)

- Fixed snapshot prune and coalesce issues with backing images
- Fixed backing image backup creation failures
- Fixed `ReadyForDownload` state issues
- Fixed V2 Data Engine spdk_tgt crash issues
- Fixed `Device or resource busy` errors
- Fixed `longhorn-images.txt` issues
- Fixed `test_engine_crash_during_live_upgrade` scenarios

#### Regression in v1.9.0

> ⚠️ **WARNING**: `longhorn-manager:v1.9.0` has a regression causing recurring job failures.
> **Solution**: Use v1.9.1 or later, or apply hotfix image `longhorn-manager:v1.9.0-hotfix-1`

### Steps

```bash
# 1. Create pre-upgrade backup snapshot
# Use Longhorn UI to create backup for all volumes

# 2. Check current orphan-auto-deletion setting (will be auto-migrated)
kubectl get settings.longhorn.io orphan-auto-deletion -n longhorn-system

# 3. Upgrade via Helm
# If using Helm:
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.9.1 \
  --reuse-values

# OR if using kubectl apply:
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.9.1/deploy/longhorn.yaml

# 4. Monitor upgrade progress
kubectl get pods -n longhorn-system -w
# Wait for all pods to be Running

# 5. Verify upgrade
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: longhornio/longhorn-manager:v1.9.x

# 6. Check for old instance manager pods that may still be running
kubectl get pods -n longhorn-system | grep instance-manager
# Old version pods should terminate automatically

# 7. Verify orphan setting was migrated
kubectl get settings.longhorn.io orphan-resource-auto-deletion -n longhorn-system

# 8. Install longhornctl if not present
# https://longhorn.io/docs/1.9.0/advanced-resources/longhornctl/
```

### Phase 1 Verification

```bash
# Verify all volumes still healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide | grep -v NAME

# Verify recurring jobs working (if any exist)
kubectl get recurringjobs.longhorn.io -n longhorn-system

# Check logs for errors
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50 | grep -i error

# Test volume operations
kubectl get pv | grep longhorn
```

---

## Phase 2: v1.9.x → v1.10.x (CRITICAL STEP)

**Target**: v1.10.1 (or latest v1.10 patch)
**Risk**: **HIGH** (CRD migration required)
**Duration**: ~30-60 minutes

### What Changed in v1.10.0

#### Breaking Changes

| Change | Details | Action Required |
|--------|---------|-----------------|
| **v1beta1 API REMOVED** | `longhorn.io/v1beta1` fully removed | **CRD migration MANDATORY before upgrade** |
| `replica.status.evictionRequested` removed | Deprecated field removed (see details below) | Check custom tooling |

#### CRD Impact Details — v1beta1 API Removal (Issue #10249)

**What was removed**: The entire `longhorn.io/v1beta1` API version is removed from all Longhorn CRDs. Only `v1beta2` remains.

**Affected CRDs** (all Longhorn CRDs):

| CRD | v1beta1 | v1beta2 | Impact |
|-----|---------|---------|--------|
| `volumes.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Volume CRs |
| `replicas.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Replica CRs |
| `engines.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Engine CRs |
| `instancemanagers.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all InstanceManager CRs |
| `settings.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Setting CRs |
| `backingimages.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all BackingImage CRs |
| `backupvolumes.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all BackupVolume CRs |
| `backuptargets.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all BackupTarget CRs |
| `recurringjobs.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all RecurringJob CRs |
| `nodes.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Node CRs |
| `orphans.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Orphan CRs |
| `snapshots.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all Snapshot CRs |
| `supportbundles.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all SupportBundle CRs |
| `systembackups.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all SystemBackup CRs |
| `systemrestores.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all SystemRestore CRs |
| `volumeattachments.longhorn.io` | ❌ Removed | ✓ Only | Must migrate all VolumeAttachment CRs |

**Who is affected**: Anyone with existing Longhorn installations that were deployed with versions before v1.3.0 (which used v1beta1 APIs). Even if you upgraded from v1.3.0+, some CRs may still be in v1beta1 format.

**How to check**:

```bash
# Check ALL Longhorn CRDs for v1beta1 in storedVersions
kubectl get crd -o json | \
  python3 -c "
import sys, json
crds = json.load(sys.stdin)['items']
for c in crds:
    if 'longhorn.io' in c['metadata']['name']:
        sv = c.get('status', {}).get('storedVersions', [])
        if 'v1beta1' in sv:
            print(f\"NEEDS MIGRATION: {c['metadata']['name']}: {sv}\")
        else:
            print(f\"OK: {c['metadata']['name']}: {sv}\")
"
```

**Risk assessment**: **HIGH** — If v1beta1 CRs remain, the v1.10 upgrade will FAIL and longhorn-manager will crash-loop. You MUST run the CRD migration script before upgrading.

#### CRD Impact Details — `replica.status.evictionRequested` Removed (Issue #7022)

**What was removed**: The `evictionRequested` field in Replica status was deprecated and is now removed.

**Who is affected**: Only users with custom scripts/tools that read `replica.status.evictionRequested`. Standard Longhorn operations are NOT affected.

**How to check**:

```bash
# Check if any replicas have this field set
kubectl get replicas.longhorn.io -n longhorn-system -o json | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('items', []):
    ev = r.get('status', {}).get('evictionRequested')
    if ev is not None:
        print(f\"WARNING: {r['metadata']['name']} has evictionRequested={ev}\")
print('Check complete')
"
```

**Risk assessment**: **LOW** — This field was already deprecated and not used by standard Longhorn operations. Only affects custom tooling.

#### CRD Impact Details — New Fields Added in v1.10.0 (Bug #12812)

> ⚠️ **KNOWN ISSUE**: When upgrading from v1.9.x to v1.10.x, the v1.10 upgrade code adds new fields to Volume CRs (`backupBlockSize`, `replicaRebuildingBandwidthLimit`). The strict decoder may reject volumes created under v1.9.x that lack these fields.

**Affected CRDs**:

| CRD | New Field | Issue |
|-----|-----------|-------|
| `volumes.longhorn.io` | `spec.backupBlockSize` | Added in v1.10.0, not present in v1.9.x volumes |
| `volumes.longhorn.io` | `spec.replicaRebuildingBandwidthLimit` | Added in v1.10.0, not present in v1.9.x volumes |

**Mitigation**: Use v1.10.1 or later (which includes the fix for this issue). If you hit this error, you may need to:

1. Downgrade back to v1.9.x
2. Re-run CRD migration
3. Upgrade to v1.10.1 (not v1.10.0)

#### New Features

| Feature | Description | Impact |
|---------|-------------|--------|
| **V2 Interrupt Mode** | Reduce CPU usage on idle/low I/O clusters | Better resource efficiency |
| **V2 Volume Cloning** | Two types: full clone and linked clone | Improved VM workflows |
| **V2 Replica Rebuild QoS** | Bandwidth limits for rebuilds | Prevents storage overload |
| **V2 Volume Expansion** | Expand V2 volumes via UI or PVC | Better V2 usability |
| **V2 Run Without Hugepages** | Reduced memory pressure on low-spec nodes | More deployment flexibility |
| **V1 IPv6 Support** | Single-stack IPv6 clusters | Better network flexibility |
| **Consolidated Settings** | Unified JSON format for V1/V2 settings | Simpler management |
| **CSIStorageCapacity** | Verify node storage before scheduling | Fewer scheduling errors |
| **Configurable Backup Block Size** | Optimize backup performance | Better backup efficiency |
| **Volume Attachment Summary** | Improved visibility | Better debugging |

#### Bug Fixes (Highlights)

- Fixed nil pointer dereference in longhorn-manager (share-manager pod backoff)
- Fixed various V2 Data Engine stability issues
- Fixed backup listing issues with >1000 backups
- Fixed volume expansion stuck issues
- Fixed recurring trim job deadlock

#### Regression in v1.10.0

> ⚠️ **WARNING**: `longhorn-manager:v1.10.0` has a regression causing nil pointer panic.
> **Solution**: Use v1.10.1 or later, or apply hotfix image `longhorn-manager:v1.10.0-hotfix-1`

### Pre-Migration Check (CRITICAL)

```bash
# Check current stored versions in ALL Longhorn CRDs
kubectl get crd -o json | \
  python3 -c "
import sys, json
crds = json.load(sys.stdin)['items']
for c in crds:
    if 'longhorn.io' in c['metadata']['name']:
        versions = c.get('status', {}).get('storedVersions', [])
        if 'v1beta1' in versions:
            print(f\"NEEDS MIGRATION: {c['metadata']['name']}: {versions}\")
        else:
            print(f\"OK: {c['metadata']['name']}: {versions}\")
"

# If ANY CRD shows v1beta1 in storedVersions, you MUST run migration
```

### CRD Migration Script (Official from v1.10.0 Release Notes)

> Source: https://github.com/longhorn/longhorn/releases/tag/v1.10.0

```bash
# Temporarily disable the CR validation webhook to allow updating read-only settings CRs.
kubectl patch validatingwebhookconfiguration longhorn-webhook-validator \
  --type=merge \
  -p "$(kubectl get validatingwebhookconfiguration longhorn-webhook-validator -o json | \
  jq '.webhooks[0].rules |= map(if .apiGroups == ["longhorn.io"] and .resources == ["settings"] then
    .operations |= map(select(. != "UPDATE")) else . end)')"

# Migrate CRDs that ever stored v1beta1 resources
migration_time="$(date +%Y-%m-%dT%H:%M:%S)"
crds=($(kubectl get crd -l app.kubernetes.io/name=longhorn -o json | jq -r '.items[] | select(.status.storedVersions | index("v1beta1")) | .metadata.name'))
for crd in "${crds[@]}"; do
  echo "Migrating ${crd} ..."
  for name in $(kubectl -n longhorn-system get "$crd" -o jsonpath='{.items[*].metadata.name}'); do
    # Attach additional annotations to trigger v1beta1 resource updating in the latest storage version.
    kubectl patch "${crd}" "${name}" -n longhorn-system --type=merge -p='{"metadata":{"annotations":{"migration-time":"'"${migration_time}"'"}}}'
  done
  # Clean up the stored version in CRD status
  kubectl patch crd "${crd}" --type=merge -p '{"status":{"storedVersions":["v1beta2"]}}' --subresource=status
done

# Re-enable the CR validation webhook.
kubectl patch validatingwebhookconfiguration longhorn-webhook-validator \
  --type=merge \
  -p "$(kubectl get validatingwebhookconfiguration longhorn-webhook-validator -o json | \
  jq '.webhooks[0].rules |= map(if .apiGroups == ["longhorn.io"] and .resources == ["settings"] then
    .operations |= (. + ["UPDATE"] | unique) else . end)')"
```

**What this script does:**
1. Disables the webhook temporarily (so settings CRs can be updated)
2. Finds all CRDs that still have `v1beta1` in `storedVersions`
3. Re-applies each CR with a `migration-time` annotation (forces Kubernetes to re-store in v1beta2)
4. Patches each CRD's `storedVersions` to `["v1beta2"]` only
5. Re-enables the webhook

**If no CRDs have v1beta1**: The script will find no CRDs to migrate and exit cleanly — no harm done.

### Migration Verification

```bash
# Verify all CRDs now show only v1beta2
kubectl get crd -l app.kubernetes.io/name=longhorn -o=jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.storedVersions}{"\n"}{end}'
```

Expected output (all must show only `["v1beta2"]`):
```
backingimagedatasources.longhorn.io: ["v1beta2"]
backingimagemanagers.longhorn.io: ["v1beta2"]
backingimages.longhorn.io: ["v1beta2"]
backupbackingimages.longhorn.io: ["v1beta2"]
backups.longhorn.io: ["v1beta2"]
backuptargets.longhorn.io: ["v1beta2"]
backupvolumes.longhorn.io: ["v1beta2"]
engineimages.longhorn.io: ["v1beta2"]
engines.longhorn.io: ["v1beta2"]
instancemanagers.longhorn.io: ["v1beta2"]
nodes.longhorn.io: ["v1beta2"]
orphans.longhorn.io: ["v1beta2"]
recurringjobs.longhorn.io: ["v1beta2"]
replicas.longhorn.io: ["v1beta2"]
settings.longhorn.io: ["v1beta2"]
sharemanagers.longhorn.io: ["v1beta2"]
snapshots.longhorn.io: ["v1beta2"]
supportbundles.longhorn.io: ["v1beta2"]
systembackups.longhorn.io: ["v1beta2"]
systemrestores.longhorn.io: ["v1beta2"]
volumeattachments.longhorn.io: ["v1beta2"]
volumes.longhorn.io: ["v1beta2"]
```

If ALL CRDs show `["v1beta2"]` only → **safe to proceed with v1.10 upgrade**.

### If Migration Fails — Force Downgrade

If the v1.10 upgrade crashes due to unmigrated CRDs:

```bash
# Downgrade via Helm
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.9.x \
  --reuse-values \
  --set preUpgradeChecker.upgradeVersionCheck=false

# OR via kubectl: patch current-longhorn-version
kubectl patch settings.longhorn.io current-longhorn-version \
  -n longhorn-system \
  --type merge \
  -p '{"value":"v1.9.x"}'

# Then re-run CRD migration, verify, and retry upgrade
```

### Upgrade to v1.10.x

```bash
# After migration is confirmed clean:

# 1. Upgrade via Helm
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.10.1 \
  --reuse-values

# 2. Monitor upgrade
kubectl get pods -n longhorn-system -w
# Wait for all pods to stabilize

# 3. Verify upgrade
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: longhornio/longhorn-manager:v1.10.x
```

### Phase 2 Verification

```bash
# Verify no v1beta1 references remain
kubectl get crd -o json | \
  python3 -c "
import sys, json
for c in json.load(sys.stdin)['items']:
    if 'longhorn.io' in c['metadata']['name']:
        sv = c.get('status',{}).get('storedVersions',[])
        if 'v1beta1' in sv: print(f\"FAIL: {c['metadata']['name']}\")
print('✅ CRD check complete')
"

# Verify volumes still healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide

# Check for errors in longhorn-manager
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50 | grep -i error

# Verify new V2 features available
kubectl get settings.longhorn.io v2-data-engine -n longhorn-system
```

---

## Phase 3: v1.10.x → v1.11.x

**Target**: v1.11.3 (latest stable — v1.11.0 had two regressions)
**Risk**: Medium
**Duration**: ~15-30 minutes

### What Changed in v1.11.0

#### Breaking Changes

| Change | Details | Action Required |
|--------|---------|-----------------|
| V2 Backing Image deprecated | Scheduled for removal in v1.12 | Plan migration before Phase 4 |
| v1.11.3 requires K8s v1.34+ | Due to CSI external provisioner v6.3.0 | Verify K8s version |

#### New Features

| Feature | Description | Impact |
|---------|-------------|--------|
| **V2 Data Engine → Technical Preview** | Stability improvements, closer to GA | Better V2 reliability |
| **V2 UBLK Frontend** | Configure UBLK performance parameters | Improved I/O performance |
| **V1 Parallel Replica Rebuild** | Stream from multiple healthy replicas simultaneously | Faster rebuild times |
| **Balance-Aware Disk Selection** | Intelligent scheduling algorithm | Reduced uneven storage usage |
| **S.M.A.R.T. Disk Health Monitoring** | Active disk health monitoring | Preventive failure detection |
| **Share Manager Networking** | Extra network interface for Share Manager | Better network segmentation |
| **ReadWriteOncePod (RWOP)** | Full Kubernetes RWOP support | Improved pod scheduling |
| **StorageClass allowedTopologies** | Restrict provisioning to specific zones/regions | Better topology control |

#### Bug Fixes (Highlights)

- Fixed instance-manager proxy connection leaks (v1.11.0)
- Fixed longhorn-manager webhook deadlock (v1.11.0)
- Fixed various V2 Data Engine stability issues
- Fixed disk health information reporting
- Fixed `UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY` errors

#### Regressions in v1.11.0

> ⚠️ **WARNING**: Two regressions in v1.11.0:
> 1. `longhorn-instance-manager:v1.11.0` — proxy connection leaks causing memory issues
> 2. `longhorn-manager:v1.11.0` — webhook deadlock blocking CNI labels
>
> **Solution**: Use v1.11.1 or later, or apply hotfix images:
> - `longhorn-instance-manager:v1.11.0-hotfix-1`
> - `longhorn-manager:v1.11.0-hotfix-1`

### Prerequisites Check

```bash
# v1.11.3 requires Kubernetes v1.34+
kubectl version --short | grep Server
# Your K3s v1.34.1: ✓

# Check if V2 Backing Images are in use (deprecated, removed in v1.12)
kubectl get backingimages.longhorn.io -n longhorn-system -o wide
# If any use V2 engine, plan migration before Phase 4
```

### Steps

```bash
# 1. Ensure K8s v1.34+ is running
kubectl version --short | grep Server

# 2. Upgrade via Helm
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.11.3 \
  --reuse-values

# 3. Monitor upgrade
kubectl get pods -n longhorn-system -w
# Wait for all pods to stabilize

# 4. Verify upgrade
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: longhornio/longhorn-manager:v1.11.x

# 5. Check new features
# - Disk health monitoring
kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.diskStatus}{"\n"}{end}'

# - Enable offline replica rebuilding (optional, disabled by default)
kubectl patch settings.longhorn.io offline-replica-rebuilding \
  -n longhorn-system \
  --type merge \
  -p '{"value":"true"}'

# - Enable orphaned instance cleanup (optional)
kubectl patch settings.longhorn.io orphan-resource-auto-deletion \
  -n longhorn-system \
  --type merge \
  --subresource status \
  -p '{"status":{"value":"instance"}}'

# 6. Check V2 Data Engine status (now Technical Preview)
kubectl get settings.longhorn.io v2-data-engine -n longhorn-system
```

### Phase 3 Verification

```bash
# Verify all volumes still healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide

# Check instance manager pods (new version)
kubectl get pods -n longhorn-system | grep instance-manager

# Check longhorn-manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50 | grep -i error

# Check disk health (new feature)
kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.diskStatus}{"\n"}{end}'
```

---

## Phase 4: v1.11.x → v1.12.1

**Target**: v1.12.1 (latest)
**Risk**: Medium
**Duration**: ~15-30 minutes

### What Changed in v1.12.0 + v1.12.1

#### Breaking Changes

| Change | Details | Action Required |
|--------|---------|-----------------|
| **V2 Backing Images REMOVED** | Must migrate to CDI before upgrading | Backup/delete V2 backing image volumes |
| **Internal NetworkPolicies enabled** | Restricts access to Longhorn internal services | Verify CNI supports NetworkPolicy |
| **mTLS extended to ALL gRPC** | All instance-manager gRPC ports require client certs | Automatic if `longhorn-grpc-tls` configured |
| **Legacy V2 linked-clone deprecated** | Created in v1.12.0 or earlier | Recreate linked clones after upgrade |

#### New Features in v1.12.0

| Feature | Description | Impact |
|---------|-------------|--------|
| **V2 Data Engine GA** | Generally Available for production | Production-ready V2 |
| **Topology-Aware PV Provisioning** | `csi-allowed-topology-keys` and `strictTopology` | Better scheduling control |
| **IPv6 for V2** | Single-stack IPv6 clusters | Network flexibility |
| **Dual-Stack Support** | IPv4+IPv6 with consistent ordering | Enterprise networking |
| **Default CPU Allocation** | V2 default 2 CPU cores (was 1) | Better I/O + RPC separation |
| **On-Demand Snapshot Checksum** | Trigger via `longhornctl` | Better data integrity |
| **Metrics Server Toggle** | Disable metrics-server-dependent metrics | Reduced scrape warnings |
| **Memory Optimization** | Reduced longhorn-manager memory in large clusters | Better resource efficiency |
| **Configurable Liveness Probe** | Engine-image pod probe settings | Fewer unnecessary restarts |

#### New Features in v1.12.1

| Feature | Description | Impact |
|---------|-------------|--------|
| **Fast Volume Cloning (V2)** | Linked-clone with shared data blocks | Faster VM provisioning |
| **Storage Sharding (Experimental)** | Erasure coding across nodes | Larger volumes, less disk |
| **CPU Core Allocation** | Kubernetes CPU Manager integration | Dedicated CPU for SPDK |
| **Host CPU Isolation** | RPS steering away from SPDK cores | Better I/O under network load |
| **SPDK iobuf Pool Config** | Tune large/small buffer pools | Better high-QD performance |
| **Encrypted Volume Size Fix** | 16 MiB LUKS2 metadata correction | Correct volume sizes |

#### Critical Stability Fixes (v1.12.0)

- **Instance Manager Panic During Replica Rebuild Storms** — fixed cascading volume detachments
- **Replica Rebuild Progress Reporting** — fixed >100% display bug
- **Replica Auto-Balance Scheduling Loop** — fixed repeated create/delete cycle
- **Replica CR Leak** — fixed stopped Replica CR accumulation
- **CSI Storage Capacity Tracking** — fixed zero-capacity on compute nodes
- **Encrypted Volume Size Correction** — 16 MiB LUKS2 header pre-allocated

#### Bug Fixes in v1.12.1

- Fixed `nvmf-autoconnect` stalling volume attach/detach
- Fixed RKE2 `rke2-traefik` NetworkPolicy compatibility
- Fixed V2 encrypted volume size 16MB short
- Fixed GCS backup target large volume failures
- Fixed V2 backup/snapshot stale NVMe/TCP frontend
- Fixed volume expansion stuck issues
- Fixed ArgoCD OutOfSync with Gateway API
- Fixed V2 volume repeated replica reuse failure
- Fixed `UBLK fails with EINVAL on kernel 6.17.0`
- Fixed `filesystemReadOnly` detection on kernel >= 6.12

### Pre-Migration: V2 Backing Images

**If you have V2 backing images, you MUST migrate before upgrading:**

```bash
# Check for V2 backing images
kubectl get backingimages.longhorn.io -n longhorn-system -o wide

# For each V2 backing image with volumes:
# 1. Create backup of the volume
# 2. Delete the volume
# 3. Restore from backup (restored volume has no backing image dependency)

# If no V2 backing images exist, skip this step
```

### Check NetworkPolicy Provider

v1.12 enables internal NetworkPolicies by default. A CNI that supports NetworkPolicy is required:

```bash
# Check if your CNI supports NetworkPolicy
# Common options: Calico, Cilium, Canal
kubectl get pods -n kube-system | grep -E 'calico|cilium|canal|flannel'

# If using flannel (no NetworkPolicy support), Longhorn will still work
# but policies won't be enforced

# For RKE2 with Canal (default), NetworkPolicy is supported ✓
```

### Steps

```bash
# 1. Final volume health check
kubectl get volumes.longhorn.io -n longhorn-system -o wide
# ALL volumes must be Healthy

# 2. If V2 volumes are in use, detach them before upgrade
# (V2 volumes don't support live upgrades between v1.12 patches)

# 3. Upgrade via Helm
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.1 \
  --reuse-values

# 4. Monitor upgrade (may take longer due to CRD updates)
kubectl get pods -n longhorn-system -w
# Watch for longhorn-manager, longhorn-driver, instance-manager, etc.
# Wait for all pods to stabilize

# 5. Verify upgrade
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: longhornio/longhorn-manager:v1.12.1

# 6. Check V2 Data Engine is now GA
kubectl get settings.longhorn.io v2-data-engine -n longhorn-system

# 7. Check for new NetworkPolicy resources
kubectl get networkpolicies -n longhorn-system

# 8. Upgrade engine images for all volumes
# Go to Longhorn UI → Volume → select volume → Upgrade Engine
# Or use longhornctl:
# longhornctl upgrade engine
```

### Phase 4 Verification

```bash
# Verify all volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide

# Verify engine images updated
kubectl get volumes.longhorn.io -n longhorn-system \
  -o json | \
  python3 -c "
import sys, json
vols = json.load(sys.stdin)['items']
for v in vols:
    name = v['metadata']['name']
    spec_img = v['spec'].get('image', 'N/A')
    curr_img = v['status'].get('currentImage', 'N/A')
    if spec_img != curr_img:
        print(f'NEEDS UPGRADE: {name} (spec: {spec_img}, current: {curr_img})')
    else:
        print(f'OK: {name} (image: {curr_img})')
"

# Check longhorn-manager logs for errors
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50 | grep -i error

# Test volume operations
# Create a test PVC to verify storage is working
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: post-upgrade-test
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc post-upgrade-test
# Wait for Bound status

# Clean up test PVC
kubectl delete pvc post-upgrade-test
```

---

## Post-Upgrade Verification

After completing all 4 phases:

```bash
# 1. Final version check
kubectl get deploy -n longhorn-system longhorn-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Expected: longhornio/longhorn-manager:v1.12.1

# 2. All volumes healthy
kubectl get volumes.longhorn.io -n longhorn-system -o wide

# 3. All replicas healthy
kubectl get replicas.longhorn.io -n longhorn-system -o wide

# 4. All pods running
kubectl get pods -n longhorn-system

# 5. CRDs all v1beta2
kubectl get crd -o json | \
  python3 -c "
import sys, json
for c in json.load(sys.stdin)['items']:
    if 'longhorn.io' in c['metadata']['name']:
        sv = c.get('status',{}).get('storedVersions',[])
        if sv != ['v1beta2']:
            print(f'WARNING: {c[\"metadata\"][\"name\"]}: {sv}')
print('✅ CRD check complete')
"

# 6. Check backup target still configured
kubectl get backuptargets.longhorn.io -n longhorn-system

# 7. Verify monitoring (if Prometheus/Grafana deployed)
kubectl get servicemonitors -n longhorn-system

# 8. Check for any longhorn-manager errors
kubectl logs -n longhorn-system -l app=longhorn-manager --since=1h | grep -i error

# 9. Verify NetworkPolicy (v1.12 feature)
kubectl get networkpolicies -n longhorn-system

# 10. Check V2 Data Engine GA status
kubectl get settings.longhorn.io v2-data-engine -n longhorn-system
```

---

## Rollback Plan

> ⚠️ **Longhorn does NOT support downgrades.** If you need to revert, you must uninstall and reinstall the previous version (data loss risk).

### Before Each Phase — Safety Net

```bash
# 1. Full backup via Longhorn UI (Backup tab)
# 2. Export Longhorn settings
kubectl get settings.longhorn.io -n longhorn-system -o yaml > longhorn-settings-backup.yaml

# 3. Export volume configs
kubectl get volumes.longhorn.io -n longhorn-system -o yaml > longhorn-volumes-backup.yaml

# 4. If upgrade fails mid-way, you may need to force downgrade:
# For Helm installations:
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version <PREVIOUS_VERSION> \
  --reuse-values \
  --set preUpgradeChecker.upgradeVersionCheck=false

# For kubectl installations:
kubectl patch settings.longhorn.io current-longhorn-version \
  -n longhorn-system \
  --type merge \
  -p '{"value":"<PREVIOUS_VERSION>"}'
```

---

## Troubleshooting

### Common Issues

| Issue | Phase | Solution |
|-------|-------|----------|
| Upgrade blocked by version check | Any | Disable: `--set preUpgradeChecker.upgradeVersionCheck=false` |
| CRD migration failed | Phase 2 | Downgrade to v1.9.x, re-migrate, retry |
| longhorn-manager crash-looping | Any | Check logs: `kubectl logs -n longhorn-system -l app=longhorn-manager` |
| Old instance-manager pods running | Any | They auto-terminate; if stuck, delete them manually |
| Volumes stuck in "Detaching" | Any | Wait 5 min; if persistent, restart longhorn-manager pod |
| Engine image mismatch | Phase 4 | Use UI to upgrade engine per volume, or `longhornctl upgrade engine` |
| NetworkPolicy blocking traffic | Phase 4 | Check CNI supports NetworkPolicy; add exceptions if needed |
| V2 volumes stuck attaching | Phase 4 | Detach V2 volumes before upgrade, re-attach after |
| Recurring jobs failing | Phase 1 | Use v1.9.1+ (v1.9.0 regression) |
| Share-manager nil pointer panic | Phase 2 | Use v1.10.1+ (v1.10.0 regression) |

### Useful Debug Commands

```bash
# Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager -f

# Instance manager logs
kubectl logs -n longhorn-system -l app=longhorn-instance-manager -f

# CSI plugin logs
kubectl logs -n longhorn-system -l app=longhorn-csi-plugin -f

# Generate support bundle (from UI or CLI)
kubectl get supportbundles.longhorn.io -n longhorn-system

# Check Longhorn engine images
kubectl get engineimages.longhorn.io -n longhorn-system

# Check all Longhorn resources
kubectl get all -n longhorn-system

# Check CRD versions
kubectl get crd -o json | python3 -c "
import sys, json
for c in json.load(sys.stdin)['items']:
    if 'longhorn.io' in c['metadata']['name']:
        sv = c.get('status',{}).get('storedVersions',[])
        print(f'{c[\"metadata\"][\"name\"]}: {sv}')
"
```

---

## Quick Reference: Version Matrix

| Component | v1.8.2 | v1.9.x | v1.10.x | v1.11.x | v1.12.1 |
|-----------|--------|--------|---------|---------|---------|
| Min K8s | v1.25 | v1.25 | v1.25 | v1.25 (v1.34 for .3+) | v1.25 (v1.34 for .1) |
| CRD API | v1beta1 + v1beta2 | v1beta1 + v1beta2 | v1beta2 only | v1beta2 only | v1beta2 only |
| V2 Engine | Experimental | Experimental | Experimental | Technical Preview | **GA** |
| environment_check.sh | ✓ | ❌ Removed | ❌ | ❌ | ❌ |
| orphan-auto-deletion | ✓ | Renamed | ❌ | ❌ | ❌ |
| V2 Backing Images | ✓ | ✓ | ✓ | Deprecated | **Removed** |
| NetworkPolicy | No | No | No | No | **Enabled** |
| mTLS coverage | Partial | Partial | Partial | Partial | **Full** |
| Offline rebuild | No | Optional | Optional | Optional | Optional |
| S.M.A.R.T. monitoring | No | No | No | ✓ | ✓ |
| RWOP support | No | No | No | ✓ | ✓ |
| Fast cloning (V2) | No | No | Basic | Basic | **Enhanced** |
| Storage sharding | No | No | No | No | Experimental |
| Dual-stack | No | No | No | No | ✓ |
| IPv6 (V2) | No | No | No | No | ✓ |

---

## RKE2 Upgrade Considerations

### Your Environment Summary

| Component | Current Version | Target Version |
|-----------|----------------|----------------|
| RKE2 | v1.32.7+rke2r1 | v1.34.2+rke2r1+ |
| Kubernetes | v1.32.7 | v1.34.2+ |
| Longhorn | v1.8.2 | v1.12.1 |
| Rancher | v2.14.3 | v2.14.3 (no change) |
| CNI | Canal | Canal (no change) |

### Recommended Upgrade Order

1. **Phase 1**: Longhorn v1.8.2 → v1.9.1 (RKE2 v1.32.7 OK)
2. **Phase 2**: Longhorn v1.9.1 → v1.10.1 (RKE2 v1.32.7 OK, CRD migration)
3. **Phase 2.5**: RKE2 v1.32.7 → v1.33.13 → v1.34.2+ (must do before Phase 3)
4. **Phase 3**: Longhorn v1.10.1 → v1.11.3 (needs K8s v1.34+)
5. **Phase 4**: Longhorn v1.11.3 → v1.12.1 (needs K8s v1.34+)

### RKE2 Version Recommendations

| RKE2 Version | Kubernetes | Notes |
|-------------|-----------|-------|
| v1.33.13+rke2r2 | v1.33.13 | Latest stable, recommended |
| v1.32.13+rke2r1 | v1.32.13 | Previous stable |
| v1.31.x | v1.31.x | Still supported |

### RKE2 + Longhorn Version Matrix

| RKE2 Version | K8s | Longhorn 1.8 | Longhorn 1.9 | Longhorn 1.10 | Longhorn 1.11 | Longhorn 1.12 |
|-------------|-----|-------------|-------------|--------------|--------------|--------------|
| v1.25.x | 1.25 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.26.x | 1.26 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.27.x | 1.27 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.28.x | 1.28 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.29.x | 1.29 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.30.x | 1.30 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.31.x | 1.31 | ✓ | ✓ | ✓ | ✓ | ✓ |
| **v1.32.x** | **1.32** | ✓ | ✓ | ✓ | ⚠️ ≤v1.11.2 | ⚠️ ≤v1.12.0 |
| v1.33.x | 1.33 | ✓ | ✓ | ✓ | ✓ (v1.11.3+) | ✓ (v1.12.1+) |
| v1.34.x | 1.34 | ✓ | ✓ | ✓ | ✓ (v1.11.3+) | ✓ (v1.12.1+) |
| v1.35.x | 1.35 | ✓ | ✓ | ✓ | ✓ | ✓ |
| v1.36.x | 1.36 | ✓ | ✓ | ✓ | ✓ | ✓ |

> **Your RKE2 v1.32.7**: Can use Longhorn up to v1.11.2 or v1.12.0, but NOT v1.11.3 or v1.12.1.
> Upgrade RKE2 to v1.34.2+ to use Longhorn v1.11.3 or v1.12.1.

### RKE2 CNI Notes for Longhorn 1.12.1

Longhorn 1.12.1 enables NetworkPolicies by default. Your CNI must support them:

| CNI | NetworkPolicy Support | Recommendation |
|-----|----------------------|----------------|
| Canal (RKE2 default) | ✓ Full | Recommended — default RKE2 CNI |
| Calico | ✓ Full | Recommended |
| Cilium | ✓ Full | Recommended |
| Flannel only | ✗ None | Not recommended for Longhorn 1.12.1 |

---

*Guide created: 2026-08-27 | Based on Longhorn release notes v1.8.2 through v1.12.1*
*RKE2 support matrix based on SUSE official support matrix (RKE2 v1.33.13, v1.32.13)*

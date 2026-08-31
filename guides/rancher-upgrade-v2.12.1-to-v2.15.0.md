# Rancher Upgrade Guide: v2.12.1 → v2.15.0

| Field       | Value          |
|-------------|----------------|
| **Date**    | 2026-08-26     |
| **Author**  | Paul           |
| **Status**  | IN PROGRESS    |
| **Updated** | 2026-08-26     |
| **Target**  | Rancher v2.15.0|

---

## Table of Contents

- [1. Current State Assessment](#1-current-state-assessment)
  - [1.1 System Information](#11-system-information)
  - [1.2 Installed Rancher Apps/Charts](#12-installed-rancher-appscharts)
  - [1.3 Backups](#13-backups)
- [2. Supported Upgrade Path](#2-supported-upgrade-path)
- [3. Upgrade Steps](#3-upgrade-steps)
  - [3.1 Upgrade Helm: v3.14.4 → v3.21.4](#31-upgrade-helm-v3144--v3214)
  - [3.2 Upgrade cert-manager: v1.14.5 → v1.21.1](#32-upgrade-cert-manager-v1145--v1211)
  - [3.3 Create Backup](#33-create-backup)
  - [3.4 Step 1: Rancher v2.12.1 → v2.12.3](#34-step-1-rancher-v2121--v2123)
  - [3.5 Step 2: Rancher v2.12.3 → v2.13.3](#35-step-2-rancher-v2123--v2133)
  - [3.6 Step 3: K3s v1.33 → v1.34 + Rancher v2.13.3 → v2.14.3 (paired)](#36-step-3-k3s-v133--v134--rancher-v2133--v2143-paired)
  - [3.7 Step 4: K3s v1.34 → v1.35 + Rancher v2.14.3 → v2.15.0 (paired)](#37-step-4-k3s-v134--v135--rancher-v2143--v2150-paired)
- [4. Post-Upgrade Verification](#4-post-upgrade-verification)
  - [4.1 Verify Rancher Components](#41-verify-rancher-components)
  - [4.2 Verify Certificates](#42-verify-certificates)
  - [4.3 Verify Rancher UI](#43-verify-rancher-ui)
  - [4.4 Verify Downstream Cluster](#44-verify-downstream-cluster)
  - [4.5 Verify Installed Apps](#45-verify-installed-apps)
  - [4.6 Verify K3s Version](#46-verify-k3s-version)
- [5. Post-Upgrade Cleanup](#5-post-upgrade-cleanup)
  - [5.1 Update Feature Charts](#51-update-feature-charts)
  - [5.2 Monitoring Migration (Optional)](#52-monitoring-migration-optional)
- [6. Rollback Procedure](#6-rollback-procedure)
  - [6.1 Rollback Rancher (Helm rollback)](#61-rollback-rancher-helm-rollback)
  - [6.2 Restore from Backup](#62-restore-from-backup)
  - [6.3 Rollback K3s (if needed)](#63-rollback-k3s-if-needed)
- [7. Troubleshooting](#7-troubleshooting)
  - [7.1 Common Issues](#71-common-issues)
  - [7.2 Log Collection](#72-log-collection)
- [8. Execution Checklist](#8-execution-checklist)
- [9. Estimated Timeline](#9-estimated-timeline)
- [10. References](#10-references)

---

## 1. Current State Assessment

### 1.1 System Information

| Component           | Current Value            |
|---------------------|--------------------------|
| Rancher             | v2.12.1                  |
| K3s                 | v1.33.0+k3s1             |
| Helm                | v3.14.4                  |
| OS                  | Ubuntu 24.04.4 LTS       |
| Kernel              | 6.8.0-48-generic         |
| Container Runtime   | containerd://2.0.4-k3s4  |
| CPU                 | 8 cores                  |
| RAM                 | 31GB (15GB available)    |
| Swap                | 2GB (1.4GB available)    |
| Disk (root)         | /dev/sda3 219G (127G free)|
| Disk (ext SSD)      | /dev/sdb1 234G (129G free)|
| Hostname            | rancher.paulhome.local   |
| Nodes               | 1 (control-plane, master)|
| Certificates        | tls-rancher-ingress (True)|

**Downstream Cluster:**

| Name    | Age    |
|---------|--------|
| c-8x2rg | 23 days|

### 1.2 Installed Rancher Apps/Charts

| App                      | Chart Version                | App Version |
|--------------------------|------------------------------|-------------|
| cert-manager             | v1.14.5                      | v1.14.5     |
| rancher-backup           | 107.1.7+up8.1.7              | v8.1.7      |
| rancher-monitoring       | 107.2.4+up69.8.2-rancher.32  | v0.80.1     |
| rancher-compliance       | 107.11.0+up1.2.11            | v1.2.11     |
| rancher-cis-benchmark    | 5.7.0                        | v5.7.0      |
| rancher-istio            | 103.3.1+up1.21.1             | 1.21.1      |
| fleet                    | 107.0.1+up0.13.1             | 0.13.1      |
| elemental-operator       | 107.1.2+up1.7.5              | 1.7.5       |
| ui-plugin-operator       | 103.0.3+up0.2.2              | 0.1.3       |
| rancher-provisioning-capi| 107.0.0+up0.8.0              | 1.10.2      |
| system-upgrade-controller| 107.0.0                      | v0.16.0     |
| harbor                   | 1.18.0                       | 2.14.0      |
| jupyterhub               | 4.2.0                        | 5.3.0       |
| litellm                  | 1.1.0                        | v1.85.1     |
| eck-operator             | 3.5.0                        | 3.5.0       |
| envoy-gateway            | v1.6.2                       | v1.6.2      |
| csi-driver-nfs           | v4.7.0                       | v4.7.0      |
| kubernetes-replicator    | 2.12.3                       | v2.12.3     |

### 1.3 Backups

| Name      | Location | Type      | Latest Backup                            | Status    |
|-----------|----------|-----------|------------------------------------------|-----------|
| daily     | PV       | Recurring | daily-...2026-08-25T13-00-00Z.tar.gz     | Completed |
| daily-s3  | S3       | Recurring | daily-s3-...2026-08-26T00-01-00Z.tar.gz  | Completed |

---

## 2. Supported Upgrade Path

The **only** supported upgrade path between minor versions is:

> **Latest patch of current minor → Latest patch of next minor**

### Rancher + K3s Paired Upgrade Path

> ⚠️ **CRITICAL: Rancher must be upgraded BEFORE K3s.** Each Rancher version has a max supported K8s version.

```
v2.12.1 → v2.12.3 → v2.13.3 → v2.14.3 → v2.15.0
          ✅        ✅     ┌──✅──┐   ┌──⏳──┐
                           │      │   │      │
v1.33.0 ──────────────── v1.33 → v1.34 → v1.35
                                     │      │
                                     └──✅──┘└──⏳──┘
```

| Rancher Version | Max K8s Version |
|-----------------|-----------------|
| v2.12.x | v1.33.x |
| v2.13.x | v1.34.x |
| v2.14.x | v1.35.x |
| v2.15.x | v1.36.x |

**K3s follows the Kubernetes version-skew policy — you CANNOT skip minor versions.**

---

## 3. Upgrade Steps

### Progress Log

| Step | Description | Status | Date | Notes |
|------|-------------|--------|------|-------|
| 3.1 | Upgrade Helm v3.14.4 → v3.21.4 | ✅ Complete | 2026-08-26 | Prerequisite |
| 3.2 | Upgrade cert-manager v1.14.5 → v1.21.1 | ✅ Complete | 2026-08-26 | Fixed deprecated values |
| 3.3 | Create pre-upgrade backup | ✅ Complete | 2026-08-26 | |
| 3.4 | Rancher v2.12.1 → v2.12.3 | ✅ Complete | 2026-08-26 | K3s stays v1.33 |
| 3.5 | Rancher v2.12.3 → v2.13.3 | ✅ Complete | 2026-08-26 | K3s stays v1.33 |
| 3.6 | K3s v1.33 → v1.34 + Rancher v2.13.3 → v2.14.3 | ✅ Complete | 2026-08-26 | Paired upgrade |
| 3.7 | K3s v1.34 → v1.35 + Rancher v2.14.3 → v2.15.0 | ⏳ Pending | - | Paired upgrade |

---

### 3.1 Upgrade Helm: v3.14.4 → v3.21.4

> **WHY:** Rancher v2.12.x+ requires Helm 3.18+ for K8s 1.33 support. Your current v3.14.4 is too old.

```bash
# Download and install latest Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version --short
# EXPECTED: v3.18.x+
```

---

### 3.2 Upgrade cert-manager: v1.14.5 → v1.21.1

> **WHY:** cert-manager v1.14.5 is old. Let's Encrypt blocks old versions.

> ⚠️ **Important:** Do NOT use `--reuse-values` when upgrading from v1.14.5. The old default values contain deprecated properties that will cause schema validation errors. Use a clean values file instead.

```bash
# Update Helm repo
helm repo update

# Create clean values file (without deprecated properties)
cat <<'EOF' > /tmp/cert-manager-values.yaml
global:
  cattle:
    clusterId: local
    clusterName: local
    rkePathPrefix: ""
    rkeWindowsPathPrefix: ""
    systemProjectId: p-5bp9f
    url: https://rancher.paulhome.local
installCRDs: true
prometheus:
  enabled: true
  podmonitor:
    enabled: false
  servicemonitor:
    enabled: false
EOF

# Upgrade cert-manager
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.21.1 \
  -f /tmp/cert-manager-values.yaml \
  --wait \
  --timeout 5m

# Wait for rollout
kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager

# Verify
kubectl get pods -n cert-manager
# EXPECTED: All pods Running, image v1.21.1
```

---

### 3.3 Create Backup

Your daily backups are good, but create a **manual one** specifically for this upgrade.

```bash
# Create backup via kubectl
cat <<'EOF' | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: pre-upgrade-to-v2.15.0
spec:
  resourceSetName: rancher-resource-set-full
EOF

# Monitor backup progress
kubectl get backups -n cattle-resources-system -w

# Verify backup completed
kubectl describe backup pre-upgrade-to-v2.15.0 -n cattle-resources-system

# Note the backup filename for rollback
kubectl get backup pre-upgrade-to-v2.15.0 -n cattle-resources-system \
  -o jsonpath='{.status.backupFilename}'
```

---

### 3.4 Step 1: Rancher v2.12.1 → v2.12.3

> K3s stays at v1.33 — Rancher v2.12.x supports K8s v1.33

```bash
# Get current values
helm get values rancher -n cattle-system

# Save current values to file (for reference)
helm get values rancher -n cattle-system -o yaml > /tmp/rancher-values.yaml

# Upgrade to latest patch of current minor
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.12.3 \
  --set hostname=rancher.paulhome.local \
  --wait \
  --timeout 10m

# Wait for rollout
kubectl rollout status deployment/rancher -n cattle-system --timeout=300s

# Verify version
kubectl get deployment rancher -n cattle-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# EXPECTED: rancher/rancher:v2.12.3

# Check all pods are healthy
kubectl get pods -n cattle-system
```

**Verify in Rancher UI:** https://rancher.paulhome.local

- [ ] Dashboard loads
- [ ] Clusters visible
- [ ] No errors

> ⏸️ **PAUSE AND VERIFY BEFORE CONTINUING**

---

### 3.5 Step 2: Rancher v2.12.3 → v2.13.3

> K3s stays at v1.33 — Rancher v2.13.x supports K8s v1.33

> Review release notes: https://github.com/rancher/rancher/releases/tag/v2.13.3

```bash
# Upgrade to latest patch of next minor
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.13.3 \
  --set hostname=rancher.paulhome.local \
  --wait \
  --timeout 10m

# Wait for rollout
kubectl rollout status deployment/rancher -n cattle-system --timeout=300s

# Verify version
kubectl get deployment rancher -n cattle-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# EXPECTED: rancher/rancher:v2.13.3

# Check all pods are healthy
kubectl get pods -n cattle-system
```

**Verify in Rancher UI:**

- [ ] Review for new warnings or deprecations
- [ ] Dashboard loads
- [ ] Clusters visible

> ⏸️ **PAUSE AND VERIFY BEFORE CONTINUING**

---

### 3.6 Step 3: K3s v1.33 → v1.34 + Rancher v2.13.3 → v2.14.3 (paired)

> ⚠️ **Paired upgrade:** K3s and Rancher upgraded together. K3s first, then Rancher.

#### 3.6.1 Upgrade K3s v1.33.0 → v1.34.10

> ⚠️ **Single-node clusters:** Use manual method (not system-upgrade-controller)

```bash
# Download new binary
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.34.10+k3s1 INSTALL_K3S_SKIP_START=true sh -

# Restart K3s
sudo systemctl restart k3s

# Wait and verify
sleep 15
kubectl get nodes
# EXPECTED: v1.34.10+k3s1
```

#### 3.6.2 Upgrade Rancher v2.13.3 → v2.14.3

> Review release notes: https://github.com/rancher/rancher/releases/tag/v2.14.3

```bash
# Upgrade Rancher
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.14.3 \
  --set hostname=rancher.paulhome.local \
  --wait \
  --timeout 10m

# Wait for rollout
kubectl rollout status deployment/rancher -n cattle-system --timeout=300s

# Verify version
kubectl get deployment rancher -n cattle-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# EXPECTED: rancher/rancher:v2.14.3

# Check all pods are healthy
kubectl get pods -n cattle-system
```

**Verify in Rancher UI:**

- [ ] Review for new warnings or deprecations
- [ ] Dashboard loads
- [ ] Clusters visible

> ⏸️ **PAUSE AND VERIFY BEFORE CONTINUING**

---

### 3.7 Step 4: K3s v1.34 → v1.35 + Rancher v2.14.3 → v2.15.0 (paired)

> ⚠️ **Paired upgrade:** K3s and Rancher upgraded together. K3s first, then Rancher.

> Review release notes: https://github.com/rancher/rancher/releases/tag/v2.15.0

#### ⚠️ Important Changes in v2.15.0

| Change | Impact |
|--------|--------|
| **Chart retention policy** | v2.15.0 enforces 7-version retention. Old chart versions will age out. **Upgrade your apps BEFORE this upgrade.** |
| **Monitoring decoupled** | New installs use `rancher-monitoring-dashboards`. Legacy `rancher-monitoring` chart no longer updated. |
| **Ember UI plugins removed** | Migrate to UI Extensions Framework if using any. |
| **ui-sql-cache** | Can no longer be disabled. Prep for v2.16 where always-on. |

#### 3.7.1 Upgrade K3s v1.34.10 → v1.35.7

```bash
# Download new binary
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.7+k3s1 INSTALL_K3S_SKIP_START=true sh -

# Restart K3s
sudo systemctl restart k3s

# Wait and verify
sleep 15
kubectl get nodes
# EXPECTED: v1.35.7+k3s1
```

#### 3.7.2 Upgrade Rancher v2.14.3 → v2.15.0

```bash
# Upgrade to v2.15.0
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version 2.15.0 \
  --set hostname=rancher.paulhome.local \
  --wait \
  --timeout 10m

# Wait for rollout
kubectl rollout status deployment/rancher -n cattle-system --timeout=300s

# Verify version
kubectl get deployment rancher -n cattle-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# EXPECTED: rancher/rancher:v2.15.0

# Check all pods are healthy
kubectl get pods -n cattle-system
```

```
✅ UPGRADE COMPLETE: v2.12.1 → v2.15.0 (TARGET REACHED)
```

---

## 4. Post-Upgrade Verification

### 4.1 Verify Rancher Components

```bash
# Check all cattle-system pods
kubectl get pods -n cattle-system -o wide

# Check fleet (continuous delivery)
kubectl get pods -n cattle-fleet-system
kubectl get pods -n cattle-fleet-local-system

# Check monitoring
kubectl get pods -n cattle-monitoring-system

# Check cert-manager
kubectl get pods -n cert-manager

# Check all namespaces for unhealthy pods
kubectl get pods -A | grep -v Running | grep -v Completed
```

### 4.2 Verify Certificates

```bash
kubectl get certificates -A
# All should be "True" for READY

kubectl get certificate tls-rancher-ingress -n cattle-system
# Should be True
```

### 4.3 Verify Rancher UI

Open browser and navigate to: **https://rancher.paulhome.local**

- [ ] Login works
- [ ] Dashboard loads without errors
- [ ] Global menu items are present
- [ ] Local cluster (management) is visible
- [ ] Downstream cluster (c-8x2rg) is visible
- [ ] No red error banners

### 4.4 Verify Downstream Cluster

```bash
kubectl get clusters.cluster -o wide
kubectl get clusters.management.cattle.io -o wide
```

In Rancher UI:

- [ ] Click on downstream cluster
- [ ] Verify it's "Active"
- [ ] Check nodes are "Ready"
- [ ] Verify workloads are running

### 4.5 Verify Installed Apps

```bash
# List all installed Helm releases
helm list -A

# Check for any failed releases
helm list -A --filter 'failed'

# Verify key apps are still running
kubectl get pods -n cattle-monitoring-system
kubectl get pods -n istio-system
kubectl get pods -n harbor
kubectl get pods -n jupyterhub
kubectl get pods -n litellm
```

### 4.6 Verify K3s Version

```bash
kubectl get nodes -o wide
# Should show v1.35.7+k3s1
```

---

## 5. Post-Upgrade Cleanup

### 5.1 Update Feature Charts

In Rancher UI:

1. Go to **Apps & Marketplace** → **Installed Apps**
2. Review chart versions
3. Upgrade any charts to latest patch within their current major version

**Key charts to check:**

- `rancher-monitoring` (consider migrating to `rancher-monitoring-dashboards`)
- `rancher-backup`
- `fleet`
- `rancher-webhook`

### 5.2 Monitoring Migration (Optional)

> v2.15.0 introduces `rancher-monitoring-dashboards`. Legacy `rancher-monitoring` chart no longer updated.

To migrate (after verifying upgrade is stable):

1. Install `rancher-monitoring-dashboards` chart
2. Verify dashboards work
3. Uninstall legacy `rancher-monitoring` (if desired)

> **Note:** This is optional — legacy chart still works.

---

## 6. Rollback Procedure

If anything goes wrong, follow these steps.

### 6.1 Rollback Rancher (Helm rollback)

```bash
# List Helm revisions
helm history rancher -n cattle-system

# Rollback to previous revision
helm rollback rancher <revision-number> -n cattle-system

# Wait for rollout
kubectl rollout status deployment/rancher -n cattle-system

# Verify
kubectl get deployment rancher -n cattle-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 6.2 Restore from Backup

> Use this if Helm rollback is not enough.

```bash
# List available backups
kubectl get backups -n cattle-resources-system

# Create restore from pre-upgrade backup
cat <<EOF | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: rollback-to-v2.12.1
spec:
  backupFilename: <backup-filename-from-section-3.3>
  resourceSetName: rancher-resource-set-full
EOF

# Monitor restore
kubectl get restores -n cattle-resources-system -w
```

> After restore, you may need to reinstall Rancher at the version that was backed up.

### 6.3 Rollback K3s (if needed)

```bash
# Stop k3s
sudo systemctl stop k3s

# Reinstall previous version
sudo curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.0+k3s1 sh -

# Start k3s
sudo systemctl start k3s

# Verify
kubectl get nodes
```

---

## 7. Troubleshooting

### 7.1 Common Issues

| Issue | Solution |
|-------|----------|
| Rancher pods stuck in `CrashLoopBackOff` | Check logs: `kubectl logs -n cattle-system <pod-name>`. Common cause: image pull failures, cert-manager issues. |
| Helm upgrade fails with `context deadline exceeded` | Increase timeout: `--timeout 15m`. Check pod status: `kubectl get pods -n cattle-system -w`. |
| Rancher UI shows `502 Bad Gateway` | Wait 2-3 minutes for pods to stabilize. Check ingress: `kubectl get ingress -n cattle-system`. |
| Downstream cluster shows "Unavailable" | Normal during Rancher upgrade. Wait for Rancher to fully stabilize. Check: `kubectl get clusters.cluster`. |
| cert-manager certificates not renewing | Check logs: `kubectl logs -n cert-manager deployment/cert-manager`. Verify issuer: `kubectl get clusterissuers`. |
| ingress-nginx webhook blocking Ingress creation | Delete webhook: `kubectl delete validatingwebhookconfigurations ingress-nginx-admission` |
| cert-manager schema validation error | Do NOT use `--reuse-values`. Use clean values file (see section 3.2). |
| K3s upgrade stuck (single-node) | Use manual method, not system-upgrade-controller (see section 3.6.1). |

### 7.2 Log Collection

If you need to collect logs for support:

```bash
# Rancher logs
kubectl logs -n cattle-system deployment/rancher --tail=1000 > /tmp/rancher.log

# Webhook logs
kubectl logs -n cattle-system deployment/rancher-webhook --tail=1000 > /tmp/webhook.log

# cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager --tail=1000 > /tmp/certmanager.log

# System events
kubectl get events -A --sort-by='.lastTimestamp' > /tmp/events.log
```

---

## 8. Execution Checklist

### Pre-Upgrade

- [ ] Disk space verified (>50GB available)
- [ ] RAM verified (>15GB available)
- [ ] Current Rancher values exported
- [ ] Downstream cluster status noted (c-8x2rg: Active)

### Prerequisites

- [x] Helm upgraded to v3.21.4 ✅ 2026-08-26
- [x] cert-manager upgraded to v1.21.1 ✅ 2026-08-26

### Upgrade Steps (K3s + Rancher paired)

- [x] Rancher v2.12.1 → v2.12.3 (K3s stays v1.33) ✅ 2026-08-26
- [x] Rancher v2.12.3 → v2.13.3 (K3s stays v1.33) ✅ 2026-08-26
- [x] K3s v1.33 → v1.34 + Rancher v2.13.3 → v2.14.3 (paired) ✅ 2026-08-26
- [ ] K3s v1.34 → v1.35 + Rancher v2.14.3 → v2.15.0 (paired) ← NEXT

### Post-Upgrade

- [ ] Rancher UI loads and login works
- [ ] All cattle-system pods Running
- [ ] Certificates all True
- [ ] Downstream cluster Active
- [ ] Monitoring pods Running
- [ ] Other apps (harbor, jupyterhub, litellm) Running
- [ ] K3s version correct (v1.35.7+k3s1)
- [ ] No error banners in Rancher UI

### Cleanup

- [ ] Feature charts reviewed and updated
- [ ] Monitoring migration considered (optional)

---

## 9. Estimated Timeline

| Phase                                        | Estimated Time |
|----------------------------------------------|----------------|
| Prerequisites (Helm + cert-manager)          | 15-20 minutes  |
| Backup                                       | 5-10 minutes   |
| Rancher v2.12.1 → v2.12.3                   | 10-15 minutes  |
| Rancher v2.12.3 → v2.13.3                   | 10-15 minutes  |
| K3s v1.33 → v1.34 + Rancher → v2.14.3      | 15-25 minutes  |
| K3s v1.34 → v1.35 + Rancher → v2.15.0      | 15-25 minutes  |
| Post-upgrade verification                    | 15-20 minutes  |
| Cleanup                                      | 10-15 minutes  |
| **TOTAL**                                    | **1.5 - 2.5 hours** |

> Times may vary based on image pull speed, cluster performance, and verification depth.

---

## 10. References

- [Rancher Upgrade Guide](https://ranchermanager.docs.rancher.com/v2.15/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster/upgrades)
- [v2.15.0 Release Notes](https://github.com/rancher/rancher/releases/tag/v2.15.0)
- [Support Matrix (v2.14.4)](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/rancher-v2-14-4/)
- [K3s Upgrade Docs](https://docs.k3s.io/upgrades/upgrades)
- [Helm Upgrade Docs](https://helm.sh/docs/helm/helm_upgrade/)
- [cert-manager Upgrade Docs](https://cert-manager.io/docs/installation/upgrading/)

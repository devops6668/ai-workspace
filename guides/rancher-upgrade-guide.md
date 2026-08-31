# Rancher Upgrade Guide: v2.8.5 -> v2.14.4

> Last updated: 2026-07-30
> Current environment: k3s v1.28.11-rc2+k3s1

---

## Current State

| Component | Version | Status |
|-----------|---------|--------|
| Rancher | v2.8.5 | Outdated (2.8.x branch, last patch: 2.8.15) |
| k3s | v1.28.11-rc2+k3s1 | EOL (Feb 2025) + RC build |
| k3s branch | 1.28 | Below recommended minimum for latest Rancher |

---

## Latest Stable Versions (as of July 2026)

| Product | Latest Stable | Notes |
|---------|--------------|-------|
| Rancher | **v2.14.4** | GA release |
| Rancher (pre-release) | v2.15.0-rc3 | Not GA yet, do NOT use in production |
| k3s (recommended) | v1.32.x or v1.31.x | Actively maintained |
| k3s (latest) | v1.36.x | Newest, may be less battle-tested |

**Source URLs:**
- Rancher releases: https://github.com/rancher/rancher/releases
- Support matrix: https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/rancher-v2-14-3/
- k3s releases: https://github.com/k3s-io/k3s/releases

---

## Support Matrix: k3s Compatibility

### Rancher v2.8.5
| k3s Version | Provisioned | Imported |
|-------------|:-----------:|:--------:|
| 1.25 | ✅ | ✅ |
| 1.26 | ✅ | ✅ |
| 1.27 | ✅ | ✅ |
| 1.28 | ✅ | ✅ |

**Lowest certified:** 1.25 | **Highest certified:** 1.28

### Rancher v2.14.3 (latest matrix page)
| k3s Version | Provisioned | Imported |
|-------------|:-----------:|:--------:|
| 1.28 | ✅ | ✅ |
| 1.29 | ✅ | ✅ |
| 1.30 | ✅ | ✅ |
| 1.31 | ✅ | ✅ |
| 1.32 | ✅ | ✅ |
| 1.33 | ✅ | ✅ |
| 1.34 | ✅ | ✅ |
| 1.35 | ✅ | ✅ |

**Lowest certified:** 1.28 | **Highest certified:** 1.35

### Verdict

- k3s 1.28 IS supported in both v2.8.5 and v2.14.3
- **BUT** k3s 1.28 hit EOL in Feb 2025 (18+ months ago)
- Your version (v1.28.11-rc2) is an RC build — even less ideal for production
- **Recommendation:** Upgrade k3s FIRST to v1.31+ or v1.32+, then upgrade Rancher

---

## Upgrade Path (Sequential — NO Skipping)

Rancher does NOT support skipping minor versions. You MUST upgrade through each minor version's latest patch.

```
2.8.5 -> 2.8.15 -> 2.9.12 -> 2.10.12 -> 2.11.15 -> 2.12.11 -> 2.13.7 -> 2.14.4
       (patch)   (minor)   (minor)    (minor)    (minor)    (minor)   (minor)
```

**Total steps:** 7 minor version hops (each is a Helm upgrade)

**Time estimate:** ~30-60 min per hop depending on cluster size and workloads.

---

## Recommended Strategy

### Phase 1: Upgrade k3s (DO THIS FIRST)

Upgrade k3s while Rancher is still v2.8.5. This ensures Rancher manages a supported k3s version throughout the upgrade process.

#### Single-node k3s

```bash
# Check current version
k3s --version

# Stop k3s
sudo systemctl stop k3s

# Install new version (replace with desired version)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.6+k3s1" sh -

# Start k3s
sudo systemctl start k3s

# Verify
k3s --version
kubectl get nodes
```

#### Multi-server k3s (upgrade one at a time)

```bash
# On each server node, one at a time:
# 1. Drain the node from the control plane perspective
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Stop k3s on that node
sudo systemctl stop k3s

# 3. Install new version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.6+k3s1" sh -

# 4. Start k3s
sudo systemctl start k3s

# 5. Verify node is Ready
kubectl get nodes

# 6. Uncordon
kubectl uncordon <node-name>

# 7. Wait for all pods to be healthy before moving to next node
kubectl get pods -A | grep -v Running
```

### Phase 2: Upgrade Rancher (Sequential Minor Hops)

For EACH minor version hop (e.g., 2.8.x -> 2.9.x):

```bash
# --- Prerequisites ---
# Backup Rancher resources
kubectl get -A settings.management.cattle.io -o yaml > rancher-settings-backup.yaml
kubectl get -A project.apps.cattle.io -o yaml > rancher-projects-backup.yaml

# Check current Helm state
helm list -n cattle-system
helm get metadata rancher -n cattle-system

# --- Update Helm repo ---
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# --- Get current values ---
helm get values rancher -n cattle-system -o yaml > rancher-values.yaml

# --- Upgrade ---
# Replace CHART_VERSION with the latest patch for the TARGET minor version
helm upgrade rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version <CHART_VERSION> \
  --reuse-values

# --- Wait for rollout ---
kubectl -n cattle-system rollout status deployment/rancher

# --- Verify ---
# 1. Check Rancher UI loads correctly
# 2. Verify all downstream clusters are green
# 3. Check no errors in rancher pods
kubectl -n cattle-system logs -l app=rancher --tail=50

# --- Move to next minor version ---
```

### Phase 3: Post-Upgrade Verification

After reaching v2.14.4:

```bash
# Verify Rancher version
kubectl get settings.management.cattle.io server-version -o jsonpath='{.value}'

# Verify all clusters
kubectl get clusters.management.cattle.io -A

# Check for any deprecated APIs
kubectl get events -A --field-selector reason=DeprecatedAPI -o wide

# Verify Helm releases are healthy
helm list -n cattle-system
helm list -n fleet-system
```

---

## Chart Version Reference

Below are the latest Helm chart versions for each Rancher minor version.
Check https://github.com/rancher/rancher/releases for the exact latest.

| Rancher Version | Helm Chart Version | Notes |
|-----------------|-------------------|-------|
| 2.8.15 | ~2.8.15 | Latest 2.8.x patch |
| 2.9.12 | ~2.9.12 | Latest 2.9.x patch |
| 2.10.12 | ~2.10.12 | Latest 2.10.x patch |
| 2.11.15 | ~2.11.15 | Latest 2.11.x patch |
| 2.12.11 | ~2.12.11 | Latest 2.12.x patch |
| 2.13.7 | ~2.13.7 | Latest 2.13.x patch |
| 2.14.4 | ~2.14.4 | Latest stable |

**Note:** Helm chart versions may differ from Rancher versions. Always check `helm search repo rancher-stable/rancher --versions` for exact versions.

---

## Troubleshooting

### Rancher pods CrashLooping after upgrade

```bash
# Check logs
kubectl -n cattle-system logs -l app=rancher --tail=100

# Common fix: re-apply certificates if using self-signed
kubectl -n cattle-system delete secret tls-ca
kubectl -n cattle-system delete secret cattle-keys-serving
```

### Downstream clusters stuck in "Updating"

```bash
# Check fleet-agent
kubectl -n cattle-fleet-system get pods
kubectl -n cattle-fleet-system logs -l app=fleet-agent --tail=50

# Force reconcile if needed
kubectl -n fleet-default delete clusters.cluster.x-k8s.io <cluster-name>
```

### Helm upgrade fails with "cannot reuse a name that is still in use"

```bash
# Check existing release
helm list -n cattle-system | grep rancher

# If stuck, uninstall and reinstall (LAST RESORT)
helm uninstall rancher -n cattle-system
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version <CHART_VERSION> \
  --values rancher-values.yaml
```

---

## Key References

- Rancher Upgrade Docs: https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/upgrade-rancher
- Support Matrix: https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/
- Rancher GitHub Releases: https://github.com/rancher/rancher/releases
- k3s Install/Upgrade: https://docs.k3s.io/installation/upgrades
- Helm Chart Versions: https://github.com/rancher/rancher/blob/main/chart/Chart.yaml

---

## Quick Decision Matrix

| Scenario | Recommendation |
|----------|---------------|
| Just want Rancher latest, k3s 1.28 is fine | Upgrade Rancher through path, k3s 1.28 is supported |
| Want everything supported and maintained | Upgrade k3s to 1.32+ FIRST, then Rancher to 2.14.4 |
| Production, risk-averse | Upgrade k3s to 1.31.x LTS-like, Rancher to 2.14.4 |
| Testing/dev environment | Upgrade k3s to 1.32+, Rancher to 2.14.4, faster pace |

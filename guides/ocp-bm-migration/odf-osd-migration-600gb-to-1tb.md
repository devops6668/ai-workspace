# ODF OSD Migration Guide: 3×600GB → 3×1TB NVMe (New Nodes + Same StorageClass)

> Red Hat Knowledgebase Solution #7134635 — Migrating Ceph OSDs Using the Same StorageClass
> Adapted for Paul's environment: infra01-03 (600GB) → 3 new BM nodes (1TB NVMe)
> StorageClass: `lab` (same for all PVs)

---

## Table of Contents

- [Scenario](#scenario)
- [Prerequisites](#prerequisites)
- [Phase 1: Prepare New Nodes (OCP + ODF Label)](#phase-1-prepare-new-nodes-ocp--odf-label)
- [Phase 2: Update LocalVolumeSet (nodeSelector + minSize/maxSize)](#phase-2-update-localvolumeset-nodeselector--minsizemaxsize)
- [Phase 3: Update LocalVolumeDiscovery (nodeSelector)](#phase-3-update-localvolumediscovery-nodeselector)
- [Phase 4: Verify New 1TB PVs Discovered (Same SC)](#phase-4-verify-new-1tb-pvs-discovered-same-sc)
- [Phase 5: Backup StorageCluster](#phase-5-backup-storagecluster)
- [Phase 6: Scale Up StorageCluster (Add New 1TB OSDs)](#phase-6-scale-up-storagecluster-add-new-1tb-ossds)
- [Phase 7: Wait for Rebalance — HEALTH_OK](#phase-7-wait-for-rebalance--health_ok)
- [Phase 8: Scale Down Rook-Ceph-Operator](#phase-8-scale-down-rook-ceph-operator)
- [Phase 9: Remove Old 600GB OSDs (One at a Time!)](#phase-9-remove-old-600gb-ossds-one-at-a-time)
- [Phase 10: Adjust StorageCluster Count Back](#phase-10-adjust-storagecluster-count-back)
- [Phase 11: Scale Up Rook-Ceph-Operator & Verify](#phase-11-scale-up-rook-ceph-operator--verify)
- [Verification Checklist](#verification-checklist)
- [Rollback Plan](#rollback-plan)
- [Critical Warnings](#critical-warnings)
- [Reference](#reference)

---

## Scenario

| Item | Before | After |
|------|--------|-------|
| Storage Nodes | infra01-03 (VMware) | new-node1-3 (BM) |
| OSD Count | 3 (600GB each) | 3 (1TB NVMe each) |
| Old OSD Count | 3 (600GB — will be removed) | 0 |
| New OSD Count | 0 | 3 (1TB — will be added) |
| Raw Capacity | 1,800 GB | 3,000 GB |
| Usable Capacity (3x replica) | 600 GB | 1,000 GB |
| StorageClass | lab | lab (SAME) |
| LocalVolumeSet name | lab | lab |
| Platform | Bare Metal + LSO | Bare Metal + LSO |
| failureDomain | host or rack | host or rack |
| ODF version | >= 4.16 required | — |

**Key constraint:** ODF does NOT support heterogeneous disk sizes within the same StorageDeviceSet. This migration adds new 1TB OSDs on new nodes, then removes old 600GB OSDs from old nodes, keeping the same StorageClass.

---

## Prerequisites

- [ ] Administrative access to OCP console and `oc` CLI
- [ ] Running ODF StorageCluster in `Ready` state
- [ ] 3 new BM servers ready (each with 1TB NVMe)
- [ ] CPU/Memory headroom on new nodes: each OSD uses 2 CPU + 5GiB memory
- [ ] Backup of critical data (recommended before any OSD operation)
- [ ] ODF version >= 4.16 (this process is GA since 4.16)
- [ ] Current LocalVolumeSet: `lab`, nodes: infra01-03, storageClassName: lab

---

## Phase 1: Prepare New Nodes (OCP + ODF Label)

### Step 1.1: Boot 3 New BM Nodes into OCP

Provision 3 new bare metal worker nodes via your normal process (e.g., Cisco UCS BMC + IPI).

```bash
# Check new nodes are Ready
oc get nodes
```

Expected: all nodes (existing + new) show `Ready`.

### Step 1.2: Approve CSRs for New Nodes

```bash
# Check pending CSRs
oc get csr

# Approve all pending CSRs
oc adm certificate approve <csr-name>

# Repeat until all CSRs approved
```

### Step 1.3: Apply ODF Label to New Nodes

**For each new node:**

```bash
oc label node new-node1 cluster.ocs.openshift.io/openshift-storage=""
oc label node new-node2 cluster.ocs.openshift.io/openshift-storage=""
oc label node new-node3 cluster.ocs.openshift.io/openshift-storage=""
```

> **Note:** Replace `new-node1`, `new-node2`, `new-node3` with actual hostnames once assigned.

Verify:
```bash
oc get nodes --show-labels | grep cluster.ocs.openshift.io/openshift-storage= | cut -d' ' -f1
```

Expected: all storage nodes (old + new) listed.

### Step 1.4: Verify CSI Pods Run on New Nodes

```bash
oc get pods -n openshift-storage -o wide | grep -E "cephfs|rbd" | grep -E "new-node1|new-node2|new-node3"
```

Expected: `openshift-storage.cephfs.csi.ceph.com-*` and `openshift-storage.rbd.csi.ceph.com-*` pods in Running state on each new node.

---

## Phase 2: Update LocalVolumeSet (nodeSelector + minSize/maxSize)

**Purpose:** Add new nodes to LSO discovery AND filter to only discover 1TB disks (exclude old 600GB).

### Step 2.1: Check Current LocalVolumeSet

```bash
oc get localvolumeset -n openshift-local-storage lab -o yaml
```

Current config:
```yaml
spec:
  deviceInclusionSpec:
    deviceTypes:
    - disk
    - part
    minSize: 1Gi              # Too low — won't filter old disks
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
        - infra01
        - infra02
        - infra03
  storageClassName: lab
```

### Step 2.2: Confirm Same StorageClass

```bash
# StorageCluster's storageClassName
oc get storagecluster -n openshift-storage ocs-storagecluster \
  -o jsonpath='{.spec.storageDeviceSets[0].template.spec.storageClassName}'
# Expected: lab

# LocalVolumeSet's storageClassName
oc get localvolumeset -n openshift-local-storage lab \
  -o jsonpath='{.spec.storageClassName}'
# Expected: lab (MUST match)
```

### Step 2.3: Update LocalVolumeSet

```bash
oc patch localvolumeset -n openshift-local-storage lab \
  --type merge \
  -p '{
    "spec": {
      "nodeSelector": {
        "nodeSelectorTerms": [
          {
            "matchExpressions": [
              {
                "key": "kubernetes.io/hostname",
                "operator": "In",
                "values": [
                  "infra01",
                  "infra02",
                  "infra03",
                  "new-node1",
                  "new-node2",
                  "new-node3"
                ]
              }
            ]
          }
        ]
      },
      "deviceInclusionSpec": {
        "deviceTypes": ["disk", "part"],
        "minSize": "900Gi",
        "maxSize": "1.1Ti"
      }
    }
  }'
```

> **Note:** Replace `new-node1`, `new-node2`, `new-node3` with actual hostnames once assigned.

**Effect:**
- Old 600GB disks on infra01-03 → below minSize → NO new PVs from these disks
- New 1TB NVMe on new-node1-3 → within range → auto-discovered and PVs created

### Step 2.4: Verify

```bash
oc get localvolumeset -n openshift-local-storage lab -o yaml | grep -A 25 "spec"
```

Expected:
```yaml
spec:
  deviceInclusionSpec:
    deviceTypes:
    - disk
    - part
    maxSize: 1.1Ti
    minSize: 900Gi
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
        - infra01
        - infra02
        - infra03
        - new-node1
        - new-node2
        - new-node3
  storageClassName: lab
  tolerations:
  - effect: NoSchedule
    key: node.ocs.openshift.io/storage
    operator: Equal
    value: "true"
  volumeMode: Block
```

---

## Phase 3: Update LocalVolumeDiscovery (nodeSelector)

**Purpose:** Ensure LocalVolumeDiscovery also scans new nodes for disks.

### Step 3.1: Check Current LocalVolumeDiscovery

```bash
oc get localvolumediscovery -n openshift-local-storage -o yaml | grep -A 25 "spec"
```

Check if it has a `nodeSelector`. If yes, update it.

### Step 3.2: Update LocalVolumeDiscovery (if nodeSelector exists)

```bash
# Find the discovery name
oc get localvolumediscovery -n openshift-local-storage

# Update it (replace <discovery-name> with actual name)
oc patch localvolumediscovery -n openshift-local-storage <discovery-name> \
  --type merge \
  -p '{
    "spec": {
      "nodeSelector": {
        "nodeSelectorTerms": [
          {
            "matchExpressions": [
              {
                "key": "kubernetes.io/hostname",
                "operator": "In",
                "values": [
                  "infra01",
                  "infra02",
                  "infra03",
                  "new-node1",
                  "new-node2",
                  "new-node3"
                ]
              }
            ]
          }
        ]
      }
    }
  }'
```

> **Note:** If LocalVolumeDiscovery has NO nodeSelector (discovers all nodes), skip this step.

### Step 3.3: Verify

```bash
oc get localvolumediscovery -n openshift-local-storage -o yaml | grep -A 15 "nodeSelector"
```

---

## Phase 4: Verify New 1TB PVs Discovered (Same SC)

Wait 5-10 minutes for LSO to discover new NVMe disks and create PVs.

### Step 4.1: Check New PVs

```bash
oc get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,CAP:.spec.capacity.storage,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0] | sort -k3,3
```

Expected output:
```
NAME                                       SC     CAP     NODE
pvc-xxxx-old1                              lab    600Gi   infra01    # OLD
pvc-xxxx-old2                              lab    600Gi   infra02    # OLD
pvc-xxxx-old3                              lab    600Gi   infra03    # OLD
pvc-xxxx-new1                              lab    1Ti     new-node1  # NEW ✓
pvc-xxxx-new2                              lab    1Ti     new-node2  # NEW ✓
pvc-xxxx-new3                              lab    1Ti     new-node3  # NEW ✓
```

### Step 4.2: Critical — Confirm Same StorageClass

```bash
# ALL PVs must have storageClassName = lab
oc get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.spec.capacity.storage}{"\t"}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{"\n"}{end}' | sort -k2,2 -k3,3
```

**ALL lines must show `lab` as the storageClassName.** If any PV has a different SC, the migration cannot proceed with "Same SC" method.

---

## Phase 5: Backup StorageCluster

```bash
oc get storagecluster -n openshift-storage ocs-storagecluster -o yaml > storagecluster.yaml
```

Keep this backup safe — you'll need it for rollback.

---

## Phase 6: Scale Up StorageCluster (Add New 1TB OSDs)

### Step 6.1: Check failureDomain

```bash
oc get storagecluster -n openshift-storage ocs-storagecluster \
  -o jsonpath='{.status.storageDeviceSets[0].failureDomain}'
```

### Step 6.2: Determine Count Change

**If failureDomain is `rack` or `zone` (replica=3):**

| Step | Count | OSDs | Description |
|------|-------|------|-------------|
| Before | 1 | 3 (3×600GB) | Original |
| Scale up | 2 | 6 (3×600GB + 3×1TB) | Add 3 new OSDs |
| After removal | 1 | 3 (3×1TB) | Back to original |

```yaml
storageDeviceSets:
  - count: 2          # Was 1, now 2
    replica: 3        # DO NOT CHANGE
```

**If failureDomain is `host` (replica=1):**

| Step | Count | OSDs | Description |
|------|-------|------|-------------|
| Before | 3 | 3 (3×600GB) | Original |
| Scale up | 6 | 6 (3×600GB + 3×1TB) | Add 3 new OSDs |
| After removal | 3 | 3 (3×1TB) | Back to original |

```yaml
storageDeviceSets:
  - count: 6          # Was 3, now 6
    replica: 1        # DO NOT CHANGE
```

### Step 6.3: Edit StorageCluster

```bash
oc edit storagecluster -n openshift-storage ocs-storagecluster
```

Change `count` value as determined above.

### Step 6.4: Wait for New OSDs

```bash
# Monitor new OSD pods
oc get pods -n openshift-storage | grep osd -w
```

Expected: 6 pods (3 old 600GB + 3 new 1TB)

### Step 6.5: Verify New OSDs on New Nodes

```bash
oc get pods -n openshift-storage -o wide | grep rook-ceph-osd
```

New OSDs should appear on new-node1-3.

---

## Phase 7: Wait for Rebalance — HEALTH_OK

This is the most critical waiting step.

```bash
oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph status \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

### DO NOT PROCEED if you see:
```
health: HEALTH_WARN
pgs:  active+undersized+degraded+remapped+backfill_wait    ← DO NOT PROCEED
     active+remapped+backfill_wait                          ← DO NOT PROCEED
     active+undersized+degraded+remapped+backfilling        ← DO NOT PROCEED
```

### PROCEED ONLY when you see:
```
health: HEALTH_OK
pgs:  xxx  active+clean     ← ALL PGs must be active+clean
osd:  6 osds: 6 up, 6 in
```

**This can take minutes to hours depending on data volume. BE PATIENT.**

---

## Phase 8: Scale Down Rook-Ceph-Operator

```bash
oc scale deployment -n openshift-storage rook-ceph-operator --replicas=0
```

Verify:
```bash
oc get deployment -n openshift-storage rook-ceph-operator
```

Expected: `0/1` ready.

---

## Phase 9: Remove Old 600GB OSDs (One at a Time!)

> ⚠️ CRITICAL: Remove ONE OSD at a time. Wait for full rebalance (HEALTH_OK + all active+clean) before removing the next.

### Step 9.1: Determine OSD IDs to Remove

```bash
# List current OSDs and their device sizes
oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph osd tree \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

Identify which OSD IDs are on 600GB disks (check device path/size in the tree output).

### Step 9.2: Remove First Old OSD

```bash
# Delete any pending jobs first
oc delete jobs -n openshift-storage --all

# Set the OSD ID to remove (e.g., osd-0 on infra01 with 600GB)
osd_id_to_remove=0

# Scale down the specific OSD deployment
oc scale -n openshift-storage deployment rook-ceph-osd-${osd_id_to_remove} --replicas=0

# Create and run the removal job
oc process -n openshift-storage ocs-osd-removal \
  -p FAILED_OSD_IDS=${osd_id_to_remove} FORCE_OSD_REMOVAL=false \
  | oc create -n openshift-storage -f -
```

### Step 9.3: Track Removal Progress

```bash
oc get jobs -n openshift-storage -w
```

Wait for `1/1` completion.

### Step 9.4: Verify OSD Removed

```bash
oc get deployment -n openshift-storage | grep osd

oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph osd tree \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

### Step 9.5: Wait for HEALTH_OK Before Next Removal

```bash
oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph status \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

**MUST see:**
```
health: HEALTH_OK
pgs:  xxx  active+clean     ← ALL PGs active+clean
osd:  5 osds: 5 up, 5 in
```

### Step 9.6: Repeat for Second Old OSD (infra02, 600GB)

```bash
oc delete jobs -n openshift-storage --all

osd_id_to_remove=1    # OSD on infra02

oc scale -n openshift-storage deployment rook-ceph-osd-${osd_id_to_remove} --replicas=0

oc process -n openshift-storage ocs-osd-removal \
  -p FAILED_OSD_IDS=${osd_id_to_remove} FORCE_OSD_REMOVAL=false \
  | oc create -n openshift-storage -f -
```

Wait for HEALTH_OK + all active+clean.

### Step 9.7: Repeat for Third Old OSD (infra03, 600GB)

```bash
oc delete jobs -n openshift-storage --all

osd_id_to_remove=2    # OSD on infra03

oc scale -n openshift-storage deployment rook-ceph-osd-${osd_id_to_remove} --replicas=0

oc process -n openshift-storage ocs-osd-removal \
  -p FAILED_OSD_IDS=${osd_id_to_remove} FORCE_OSD_REMOVAL=false \
  | oc create -n openshift-storage -f -
```

Wait for HEALTH_OK + all active+clean.

### Step 9.8: Final Verification After All Removals

```bash
oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph status \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

**Expected:**
```
health: HEALTH_OK
osd:  3 osds: 3 up, 3 in    ← Only 3 OSDs remain (all 1TB on new nodes)
pgs:  xxx  active+clean
```

---

## Phase 10: Adjust StorageCluster Count Back

Edit storagecluster back to original count:

```bash
oc edit storagecluster -n openshift-storage ocs-storagecluster
```

**If failureDomain is `rack`:**
```yaml
storageDeviceSets:
  - count: 1          # Back to original
    replica: 3        # Unchanged
```

**If failureDomain is `host`:**
```yaml
storageDeviceSets:
  - count: 3          # Back to original
    replica: 1        # Unchanged
```

---

## Phase 11: Scale Up Rook-Ceph-Operator & Verify

```bash
oc scale deployment -n openshift-storage rook-ceph-operator --replicas=1
```

Verify no OSD prepare pods appear (confirms count is correct):

```bash
oc get pods -n openshift-storage | grep osd-prepare
# Expected: no output (no new OSDs being prepared)
```

---

## Verification Checklist

- [ ] `ceph status` shows HEALTH_OK
- [ ] All PGs active+clean
- [ ] 3 OSDs, all up and in
- [ ] All OSDs are 1TB (check `ceph osd tree` — devices on new-node1-3)
- [ ] StorageCluster status: Ready
- [ ] No CrashLoopBackOff pods
- [ ] PVCs all in Bound state
- [ ] StorageClass is same for all PVs (`lab`)
- [ ] Raw capacity shows ~3,000 GB
- [ ] Old infra01-03 nodes no longer have OSD pods
- [ ] New new-node1-3 nodes have OSD pods Running
- [ ] I/O test passes (create/read/delete test PVC)

```bash
# Quick capacity check
oc exec -it $(oc get pod -n openshift-storage -l app=rook-ceph-operator -o name) \
  -n openshift-storage -- ceph df \
  -c /var/lib/rook/openshift-storage/openshift-storage.config
```

---

## Rollback Plan

If anything goes wrong during migration:

1. **Before removing old OSDs:** Simply revert StorageCluster count to original. Old 600GB OSDs are still running on infra01-03.

2. **After removing some old OSDs but not all:**
   - Stop further removals
   - Wait for HEALTH_OK
   - The remaining old OSDs can continue serving data
   - Contact Red Hat Support for guidance

3. **Emergency:** Restore from backup taken in Phase 5.

---

## Critical Warnings

> ⚠️ **OSD removal is IRREVERSIBLE** — once an OSD is removed, its data must be rebuilt from replicas on other OSDs.

> ⚠️ **NEVER remove multiple OSDs simultaneously** — this can cause COMPLETE DATA LOSS.

> ⚠️ **NEVER proceed if Ceph is not HEALTH_OK or PGs are not all active+clean.**

> ⚠️ **Each OSD uses 2 CPU + 5GiB memory** — ensure new nodes have sufficient resources before scaling up.

> ⚠️ **This process was introduced in ODF v4.16 GA** — verify your ODF version >= 4.16 before proceeding.

> ⚠️ **New node hostnames must be updated in both LocalVolumeSet AND LocalVolumeDiscovery nodeSelector.**

---

## Reference

- Red Hat KB #7134635: Migrating Ceph OSDs Using the Same StorageClass (April 2026)
- ODF Product Doc: Replacing devices
- ODF Product Doc: 7.3 Resource requirements
- ODF 4.20 Scaling Storage: https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/scaling_storage/scaling_storage_of_bare_metal_openshift_data_foundation_cluster

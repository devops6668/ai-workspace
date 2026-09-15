# OCP VMware to Bare Metal Migration Plan — Part 1: Solution Analysis

> **Companion:** [Part 2: Execution, Rollback & ODF Migration](ocp-bm-plan-part2-execution.md)
> **Author:** Hermes Agent
> **Date:** 2026-08-10 (updated 2026-09-15 v6)
> **Cluster:** lab.devops.local (OCP 4.20.27)
> **Platform:** BareMetal (platform: none)
> **Status:** Part 1 reviewed, Part 2 ready to execute (4-phase plan, corrected order)
> **Red Hat Articles:**
> - https://access.redhat.com/solutions/5020331 (mixed virtual/bare metal support)
> - https://access.redhat.com/solutions/7061543 (Hyper-V support)
> - https://access.redhat.com/articles/4207611 (non-tested platforms)
> - https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/replacing_nodes/index (ODF node replacement)
> - Red Hat KB: Guidance for OCP Clusters - Deployments Spanning Multiple Sites

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Final Architecture](#final-architecture)
- [Phase Overview](#phase-overview)
- [Current Cluster Inventory](#current-cluster-inventory)
- [Option Analysis](#option-analysis)
- [Comprehensive Comparison Table](#comprehensive-comparison-table)
- [Platform Comparison](#platform-comparison)
- [Why Option 4 Wins (Phase 1) + Phase 2 Extension](#why-option-4-wins-phase-1--phase-2-extension)
- [Summary Table](#summary-table)
- [Critical Point: Control Plane Migration](#critical-point-control-plane-migration)
- [OCP 4.21 Technology Preview Clarification](#ocp-421-technology-preview-clarification)
- [Technical Reference: Multi-site Deployment Requirements](#technical-reference-multi-site-deployment-requirements)
- [Future Considerations](#future-considerations)

---

## Executive Summary

This plan migrates an existing OCP 4.20.27 cluster from VMware VMs to bare metal, preserving all existing configurations, data, and operators.

> **Updated 2026-09-14 (v4)**: Restructured into 4 phases (1a/1b/1c/2). Phase 1 now covers ALL non-control-plane nodes (workers + ODF + monitoring). Phase 2 covers control plane replacement.

**Key Points:**
- **No data migration needed** — ODF/Ceph stays intact (rolling OSD replacement)
- **No rebuild needed** — 65 operators, 66 routes, 108 network policies all preserved
- **Cluster stays running** throughout the entire migration
- **Supported:** Red Hat SLA applies (platform: none, mixed VM/BM)
- **Phase 2 only uses 3 BM nodes** — All infra components run on 3 dedicated BM infra nodes


## Final Architecture

### Final State (after all phases)

```
Master Nodes x 3 (bare metal)
  master01 (12CPU/64GB + NVMe):
    etcd, API server, control plane
    ODF/Ceph OSD (NVMe dedicated disk)
    Monitoring stack (Prometheus, Alertmanager, Thanos)
    Loki, Tempo, Jaeger
  master02 (12CPU/64GB + NVMe):
    etcd, API server, control plane
    ODF/Ceph OSD (NVMe dedicated disk)
    GitOps (ArgoCD), Pipelines (Tekton)
    Quay registry
  master03 (12CPU/64GB + NVMe):
    etcd, API server, control plane
    ODF/Ceph OSD (NVMe dedicated disk)
    Service Mesh, Elasticsearch ECK
    ACM, Multicluster Engine
    NeuVector/Aqua/RHACS, Cert Manager
    Confluent (Kafka), CloudNativePG
    DevWorkspace, Web Terminal
    Kasten K10, OpenTelemetry, KEDA

Worker Nodes x 6 (bare metal)
  worker01-06: Apps + TopoLVM (user workload only)
```

**Note:** Each master node has a dedicated NVMe disk for ODF/Ceph OSD, separate from etcd storage. This eliminates I/O contention between etcd and Ceph.

### Architecture After Each Phase

```
After Phase 1 (Worker VM -> BM):
  master x 3 (VMware)        -- control plane
  worker x 3 (bare metal)    -- user workload only

After Phase 2 (Master VM -> BM):
  master x 3 (bare metal)    -- control plane + etcd
  worker x 3 (bare metal)    -- user workload only
  infra x 6 (VMware)         -- ODF, Monitoring, GitOps, etc.

After Phase 3 (Infra -> Master BM):
  master x 3 (bare metal)    -- control plane + etcd + infra components
  worker x 3 (bare metal)    -- user workload only
  (infra VMs decommissioned)

After Phase 4 (Add 3 more workers):
  master x 3 (bare metal)    -- control plane + etcd + infra components
  worker x 6 (bare metal)    -- user workload only
```

## Phase Overview

```
Phase 1: Worker VM -> BM (3 BM nodes)
  Risk: LOW | Time: 1-2 weeks | Method: cordon/drain/replace
  Result: 3 BM workers (apps only) + 3 VMware masters + 6 VMware infra

Phase 2: Master VM -> BM (3 BM nodes, etcd replacement)
  Risk: MEDIUM-HIGH | Time: 2-3 weeks | Method: delete Machine triggers etcd auto-remove
  Result: 3 BM masters + 3 BM workers + 6 VMware infra

Phase 3: Infra -> Master BM (move all infra components to 3 master BM nodes)
  Risk: LOW-MEDIUM | Time: 1-2 weeks | Method: update nodeSelector/affinity
  Components: ODF, Monitoring, GitOps, Pipelines, Quay, Service Mesh,
              ECK, Loki/Tempo/Jaeger, ACM, Multicluster Engine,
              NeuVector/Aqua/RHACS, Cert Manager, Confluent, CloudNativePG,
              DevWorkspace, Web Terminal, Kasten K10, OpenTelemetry, KEDA
  Result: 3 BM masters (control plane + infra) + 3 BM workers + 6 VMware infra (decommissioned)

Phase 4: Add 3 More Workers (optional, scale to 6 workers)
  Risk: LOW | Time: 3-5 days | Method: cordon/drain/replace
  Result: 3 BM masters + 6 BM workers

Total estimated time: 5-8 weeks
```

## Critical Point: Control Plane Migration

```
╔════════════════════════════════════════════════════════════════════════╗
║  Options 1/2/3 ALL require migrating CONTROL PLANE VMs               ║
║  Option 4 does NOT (CP stays on VMware)                              ║
║                                                                        ║
║  Control Plane migration is the HIGHEST RISK operation:               ║
║  - etcd cluster must be migrated (distributed consensus)             ║
║  - API server must be reconfigured                                    ║
║  - All control plane components must be reinstalled                    ║
║  - Cluster certificates may need regeneration                         ║
║  - Cluster may become UNRECOVERABLE if something goes wrong           ║
║                                                                        ║
║  Moving CP = Open heart surgery on a live patient                     ║
║  Moving workers = Swapping out a kidney (survivable)                  ║
╚════════════════════════════════════════════════════════════════════════╝
```

### Control Plane Components at Risk

| Component | Risk Level | Failure Impact |
|-----------|------------|----------------|
| etcd | CRITICAL | Cluster UNRECOVERABLE |
| kube-apiserver | CRITICAL | Cluster UNRECOVERABLE |
| kube-controller-manager | HIGH | Workloads fail |
| kube-scheduler | HIGH | No new pods scheduled |
| OpenShift controllers | HIGH | Cluster functions broken |
| Machine Config Operator | MEDIUM | Node config issues |
| Ingress Controller | MEDIUM | External access lost |
| DNS Operator | MEDIUM | Service discovery broken |

---


## Current Cluster Inventory

### Node Inventory

| Node | CPU | RAM | Role |
|------|-----|-----|------|
| master01 | 12 | 64GB | Control Plane |
| master02 | 12 | 64GB | Control Plane |
| master03 | 12 | 64GB | Control Plane |
| infra01 | 14 | 32GB | ODF/Ceph Storage |
| infra02 | 14 | 32GB | ODF/Ceph Storage |
| infra03 | 14 | 32GB | ODF/Ceph Storage |
| infra04 | 16 | 64GB | Monitoring, Quay, Egress |
| infra05 | 16 | 64GB | Monitoring, Quay, Egress |
| infra06 | 16 | 64GB | Monitoring, Quay, Egress |
| worker01 | 8 | 32GB | Apps + TopoLVM |
| worker02 | 8 | 32GB | Apps + TopoLVM |
| worker03 | 32 | 128GB | Apps + TopoLVM |

**Total:** 181 CPU, 728GB RAM  
**VMware licenses:** 12 (ALL nodes)  

### Storage (ODF 4.20.14)

- 3 ODF infra nodes (infra01-03)
- Ceph RBD, CephFS (default), Ceph RGW, Noobaa
- 47 ODF pods running
- 7 Storage Classes:
  - ocs-storagecluster-cephfs (default)
  - ocs-storagecluster-ceph-rbd
  - ocs-storagecluster-ceph-rgw
  - openshift-storage.noobaa.io
  - lvms-vg1 (TopoLVM on workers)
  - central-db (local)
  - lab (local)

### Monitoring

- 3 monitoring infra nodes (infra04-06)
- OpenShift monitoring stack (Prometheus, Alertmanager, Thanos)
- Loki, Tempo, Jaeger
- Elasticsearch ECK
- User workload monitoring

### GitOps & CI/CD

- OpenShift GitOps (ArgoCD)
- OpenShift Pipelines (Tekton)
- Pipelines-as-Code
- Quay registry

### Operators (65 total)

Critical operators:
- ODF/OCS (storage)
- Quay (registry)
- Service Mesh (OSSM 2 + 3)
- Elasticsearch ECK
- Loki, Tempo, Jaeger
- ACM (Advanced Cluster Management)
- Multicluster Engine
- NeuVector, Aqua Security, RHACS
- Cert Manager
- Confluent (Kafka)
- CloudNativePG
- DevWorkspace
- Web Terminal
- Kasten K10 (backup)
- OpenTelemetry
- KEDA (autoscaling)

### Ingress & Egress

- 66 routes across multiple namespaces
- Custom domains: *.apps.lab.devops.local, *.devops.local, *.luban.paulhome.local
- 108 network policies
- Egress-assignable nodes: infra04-06 + worker01-03
- No EgressFirewall CRDs

### Projects & Applications

- 135 projects
- 300+ applications
- ArgoCD managed
- Multiple ingress and egress configurations

---


## Option Analysis

### Option 1: Full Bare Metal (Rebuild Everything)

**Effort:** EXTREME (6-10 weeks)  
**Risk:** HIGH  
**VMware savings:** 100% (12→0 licenses)  
**Supported:** YES  
**Platform:** platform: none (bare metal)

#### What You Must Rebuild

**Infrastructure (Week 1-2):**
- Procure 12 bare metal servers
- 3 master: 12 CPU, 64GB each
- 3 ODF: 14 CPU, 32GB each (plus local disks for Ceph)
- 3 monitoring: 16 CPU, 64GB each
- 3 worker: 8/8/32 CPU, 32/32/128GB each
- BMC/IPMI/Redfish on all servers
- Same network (VLAN, DNS, DHCP, NTP)
- Load balancer for API VIP + Ingress VIP

**Cluster Install (Week 2-3):**
- Install OCP on bare metal (IPI or UPI)
- Configure OVN-Kubernetes networking
- Configure API VIP + Ingress VIP
- Install 65 operators from scratch
- Configure all operator subscriptions

**Storage - ODF (Week 3-5) ⚠️ BIGGEST RISK:**
- Install ODF operator on 3 new bare metal nodes
- Create Ceph cluster from scratch
- Wait for Ceph health OK (can take hours)
- Backup ALL PVCs from old cluster
- Restore ALL PVCs to new cluster
- Verify all data intact
- Recreate StorageClasses
- TopoLVM on new workers

**Monitoring (Week 5-6):**
- Install OpenShift monitoring stack
- Configure Prometheus retention
- Configure Alertmanager
- Configure Thanos
- Recreate all monitoring rules
- Reconfigure Loki, Tempo, Jaeger
- Reconfigure Elasticsearch ECK

**Networking (Week 6-7):**
- Recreate all 66 routes
- Recreate all 108 network policies
- Recreate egress configuration
- Reconfigure DNS entries
- Reconfigure firewall rules
- Reconfigure certificates

**Applications (Week 7-9):**
- Re-point ArgoCD to new cluster
- Re-sync all 135 projects
- Reconfigure all secrets
- Reconfigure all ConfigMaps
- Reconfigure all PVCs
- Re-test all applications
- Verify all ingress/egress

**CI/CD (Week 9-10):**
- Reconfigure OpenShift Pipelines
- Reconfigure Tekton
- Reconfigure Pipelines-as-Code
- Reconfigure Quay registry
- Reconfigure webhooks

#### Critical Risks

⚠️ **ODF DATA MIGRATION (Weeks 3-5):**
- Ceph cluster cannot be "moved"
- Must backup/restore ALL PVCs
- 135 projects × unknown PVC count
- Data loss risk if backup fails
- Downtime for stateful applications

⚠️ **INGRESS ROUTE RECREATION (66 routes):**
- Each route must be manually recreated
- Custom domains must be reconfigured
- SSL certificates must be regenerated
- DNS must be updated

⚠️ **NETWORK POLICY RECREATION (108 policies):**
- Must recreate all 108 policies
- Must test all egress paths
- Misconfiguration = application outage

⚠️ **OPERATOR REINSTALLATION (65 operators):**
- Each operator has its own CRDs
- Some operators have complex configurations
- Service Mesh migration (OSSM 2 → 3)
- Cross-operator dependencies

---

### Option 2: Nutanix (Full Cluster)

**Effort:** HIGH (4-8 weeks)  
**Risk:** HIGH  
**VMware savings:** 100% (12→0 licenses)  
**Supported:** YES  
**Platform:** platform: nutanix (Nutanix IPI)

#### What You Must Rebuild

**Infrastructure (Week 1-2):**
- Procure 12 Nutanix nodes (or use existing Nutanix cluster)
- 3 master: 12 CPU, 64GB each
- 3 ODF: 14 CPU, 32GB each
- 3 monitoring: 16 CPU, 64GB each
- 3 worker: 8/8/32 CPU, 32/32/128GB each
- Nutanix Prism Central access
- Same network (VLAN, DNS, DHCP, NTP)

**Cluster Install (Week 2-3):**
- Install OCP on Nutanix via IPI
- Configure OVN-Kubernetes networking
- Configure Nutanix cloud provider
- Install 65 operators from scratch
- Configure all operator subscriptions

**Storage - ODF (Week 3-5) ⚠️ BIGGEST RISK:**
- Install ODF operator on 3 new Nutanix nodes
- Create Ceph cluster from scratch
- Wait for Ceph health OK (can take hours)
- Backup ALL PVCs from old cluster
- Restore ALL PVCs to new cluster
- Verify all data intact
- Recreate StorageClasses

**Monitoring (Week 5-6):**
- Install OpenShift monitoring stack
- Configure Prometheus retention
- Configure Alertmanager
- Configure Thanos
- Recreate all monitoring rules
- Reconfigure Loki, Tempo, Jaeger
- Reconfigure Elasticsearch ECK

**Networking (Week 6-7):**
- Recreate all 66 routes
- Recreate all 108 network policies
- Recreate egress configuration
- Reconfigure DNS entries
- Reconfigure firewall rules
- Reconfigure certificates

**Applications (Week 7-8):**
- Re-point ArgoCD to new cluster
- Re-sync all 135 projects
- Reconfigure all secrets
- Reconfigure all ConfigMaps
- Reconfigure all PVCs
- Re-test all applications
- Verify all ingress/egress

**CI/CD (Week 8):**
- Reconfigure OpenShift Pipelines
- Reconfigure Tekton
- Reconfigure Pipelines-as-Code
- Reconfigure Quay registry
- Reconfigure webhooks

#### Advantages of Nutanix

✓ **Cloud Provider Integration:**
- Nutanix CCM (Cloud Controller Manager)
- Dynamic storage provisioning
- Node hostname resolution
- Load balancer integration

✓ **Machine API:**
- Nutanix Machine API Provider
- MachineSets for automated provisioning
- Cluster autoscaling possible

✓ **IPI Installation:**
- Automated node provisioning
- Nutanix Prism Central integration
- Simplified install process

#### Critical Risks

⚠️ **ODF DATA MIGRATION (Weeks 3-5):**
- Same as Option 1 (Ceph rebuild required)
- Data loss risk if backup fails
- Downtime for stateful applications

⚠️ **NUTANIX DEPENDENCY:**
- Requires Nutanix infrastructure
- Nutanix licensing costs
- Nutanix support required

---

### Option 3: Microsoft Hyper-V (Full Cluster)

**Effort:** EXTREME (6-10 weeks)  
**Risk:** HIGH  
**VMware savings:** 100% (12→0 licenses)  
**Supported:** YES (bare metal install method)  
**Platform:** platform: none (bare metal)

#### What You Must Rebuild

**Infrastructure (Week 1-2):**
- Procure 12 Hyper-V servers (or use existing Hyper-V cluster)
- 3 master: 12 CPU, 64GB each
- 3 ODF: 14 CPU, 32GB each
- 3 monitoring: 16 CPU, 64GB each
- 3 worker: 8/8/32 CPU, 32/32/128GB each
- Windows Server 2016+ with Hyper-V enabled
- Same network (VLAN, DNS, DHCP, NTP)
- Load balancer for API VIP + Ingress VIP

**Cluster Install (Week 2-3):**
- Create Hyper-V VMs manually
- Install RHCOS via ISO (no ignition injection)
- Host ignition configs on separate HTTP server
- Manually join nodes to cluster
- Install 65 operators from scratch
- Configure all operator subscriptions

**Storage - ODF (Week 3-5) ⚠️ BIGGEST RISK:**
- Install ODF operator on 3 new Hyper-V nodes
- Create Ceph cluster from scratch
- Wait for Ceph health OK (can take hours)
- Backup ALL PVCs from old cluster
- Restore ALL PVCs to new cluster
- Verify all data intact
- Recreate StorageClasses

**Monitoring (Week 5-6):**
- Install OpenShift monitoring stack
- Configure Prometheus retention
- Configure Alertmanager
- Configure Thanos
- Recreate all monitoring rules
- Reconfigure Loki, Tempo, Jaeger
- Reconfigure Elasticsearch ECK

**Networking (Week 6-7):**
- Recreate all 66 routes
- Recreate all 108 network policies
- Recreate egress configuration
- Reconfigure DNS entries
- Reconfigure firewall rules
- Reconfigure certificates

**Applications (Week 7-9):**
- Re-point ArgoCD to new cluster
- Re-sync all 135 projects
- Reconfigure all secrets
- Reconfigure all ConfigMaps
- Reconfigure all PVCs
- Re-test all applications
- Verify all ingress/egress

**CI/CD (Week 9-10):**
- Reconfigure OpenShift Pipelines
- Reconfigure Tekton
- Reconfigure Pipelines-as-Code
- Reconfigure Quay registry
- Reconfigure webhooks

#### Hyper-V Limitations

✗ **NO Cloud Provider Integration:**
- No Hyper-V CCM
- No dynamic storage provisioning
- No node hostname resolution
- No load balancer integration

✗ **NO Machine API:**
- No Machine API provider for Hyper-V
- No MachineSets
- No cluster autoscaling
- Manual node lifecycle management

✗ **Manual Install Only:**
- No IPI installation
- Must create VMs manually
- Must host ignition configs separately
- Must join nodes manually

✗ **Red Hat Support Limitations:**
- Red Hat will NOT provide Hyper-V configuration advice
- Contact Microsoft for Hyper-V specific issues
- "Mostly manual install" per Red Hat

#### Critical Risks

⚠️ **ODF DATA MIGRATION (Weeks 3-5):**
- Same as Option 1 (Ceph rebuild required)
- Data loss risk if backup fails
- Downtime for stateful applications

⚠️ **HYPER-V DEPENDENCY:**
- Requires Windows Server 2016+ licensing
- Requires Hyper-V expertise
- Microsoft support required
- No Red Hat help for Hyper-V issues

⚠️ **MANUAL LIFECYCLE:**
- All node management is manual
- No automation possible
- Higher operational overhead

---

### Option 4: VMware (Masters) + Bare Metal (Workers) - RECOMMENDED

**Effort:** LOW-MODERATE (1-2 weeks)  
**Risk:** LOW  
**VMware savings:** 25% (12→9 licenses, save 3)  
**Supported:** YES (Red Hat SLA applies)  
**Platform:** platform: none (bare metal)

#### Why Option 4 is Supported for Your Cluster

From Red Hat article https://access.redhat.com/solutions/5020331:

> "OpenShift 4 installation with a mix of virtual and bare metal nodes is fully supported if the following conditions are met:
> 1. The platform-agnostic installation method is used (platform: none configured in the install-config.yaml)
> 2. Cluster should meet network requirement as mentioned in Guidance for Red Hat OpenShift Container Platform Clusters - Deployments Spanning Multiple Sites"

Your cluster uses `platform: none` (platform-agnostic), so Option 4 is fully supported with Red Hat production SLA.

**Note:** Starting OCP 4.21, adding bare metal compute machines to a vSphere cluster is Technology Preview. However, this is for clusters installed with `platform: vsphere`. Your cluster uses `platform: none`, so this does not apply.

#### What You Must Do

**Phase 1: Preparation (Day 1-2)**
- Provision 3 bare metal servers
  - worker01: 8 CPU, 32GB RAM
  - worker02: 8 CPU, 32GB RAM
  - worker03: 32 CPU, 128GB RAM (MUST match!)
- Configure network (same VLAN as vSphere)
- Configure DNS for worker01-03
- Test BMC/IPMI access
- Download RHCOS ISO
- Extract Ignition config:
  ```
  oc extract -n openshift-machine-api \
    secret/worker-user-data-managed \
    --keys=userData --to=- > worker.ign
  ```

**Phase 2: Add Bare Metal Workers (Day 3-4)**
- Boot worker01 with RHCOS ISO + worker.ign
- Wait for node to join cluster
- Verify node Ready
- Verify node labels correct
- Repeat for worker02, worker03

**Phase 3: Migrate Workloads (Day 5-7)**
- Start with worker01 (smallest):
  ```
  oc cordon worker01
  oc drain worker01 --ignore-daemonsets \
    --delete-emptydir-data
  ```
  → Verify apps running on other nodes  
  → Shut down VMware VM
- Repeat for worker02
- Repeat for worker03 (LARGEST node - last)

**Phase 4: Cleanup (Day 8)**
- Remove VMware worker VMs from vCenter
- Decommission 3 VMware hosts
- Adjust VMware license

#### What Stays UNCHANGED

✓ **ODF (infra01-03):**
- Ceph cluster untouched
- All PVCs intact
- All StorageClasses intact
- Zero data migration

✓ **Monitoring (infra04-06):**
- Prometheus untouched
- Alertmanager untouched
- Thanos untouched
- All rules intact

✓ **65 Operators:**
- All operators stay running
- No reconfiguration needed
- All CRDs intact

✓ **GitOps (ArgoCD):**
- ArgoCD stays on same cluster
- All 135 projects stay intact
- No re-sync needed
- No reconfiguration

✓ **Pipelines (Tekton):**
- Pipelines stay on same cluster
- All pipeline runs intact
- No reconfiguration

✓ **66 Routes:**
- All routes stay intact
- All custom domains work
- All SSL certificates valid
- DNS unchanged

✓ **108 Network Policies:**
- All policies stay intact
- All egress paths work
- No firewall changes

✓ **Secrets & ConfigMaps:**
- All secrets intact
- All ConfigMaps intact
- No reconfiguration

#### What Changes

⚠️ **TopoLVM on workers:**
- Workers move to bare metal
- TopoLVM must be re-provisioned
- Local storage attached to new workers
- Verify TopoLVM nodes join correctly

⚠️ **Egress-assignable:**
- worker01-03 move to bare metal
- Must ensure same network connectivity
- Egress traffic must route correctly

⚠️ **Machine API:**
- No MachineSets for bare metal workers
- Manual lifecycle management
- No autoscaling for bare metal workers

---


## Comprehensive Comparison Table

```
═══════════════════════════════════════════════════════════════════════════════════
COMPONENT          OPTION 1          OPTION 2          OPTION 3          OPTION 4
                   (Full Bare Metal) (Nutanix)         (Hyper-V)         (Hybrid)
═══════════════════════════════════════════════════════════════════════════════════
EFFORT             ██████████████    ████████████░░    ██████████████    ████░░░░
                   EXTREME           HIGH              EXTREME           LOW-MOD

TIME               6-10 weeks        4-8 weeks         6-10 weeks        1-2 weeks

RISK               HIGH              HIGH              HIGH              LOW

VMWARE SAVINGS     100% (12→0)       100% (12→0)       100% (12→0)       25% (12→9)

PLATFORM           platform: none    platform: nutanix platform: none    platform: none

SUPPORTED          YES ✓             YES ✓             YES ✓             YES ✓
                   (full RH SLA)     (full RH SLA)     (bare metal only) (full RH SLA)
═══════════════════════════════════════════════════════════════════════════════════

                   ── CONTROL PLANE (HIGHEST RISK) ──
Migrate CP?        YES ⚠️ CRITICAL   YES ⚠️ CRITICAL   YES ⚠️ CRITICAL   NO ✓
etcd migration?    YES ⚠️            YES ⚠️            YES ⚠️            NO ✓
API reconfig?      YES ⚠️            YES ⚠️            YES ⚠️            NO ✓
Cert regen?        MAYBE ⚠️          MAYBE ⚠️          MAYBE ⚠️          NO ✓
Cluster risk?      UNRECOVERABLE     UNRECOVERABLE     UNRECOVERABLE     ZERO
                   if failed         if failed         if failed
═══════════════════════════════════════════════════════════════════════════════════

                   ── INSTALL METHOD ──
Installer          IPI/UPI           IPI (Nutanix)     Manual/Bare Metal IPI/UPI
                   or bare metal                     (platform: none)
Auto-provision?    YES (IPI)         YES (IPI)         NO (manual)       YES (IPI)
Machine API?       YES               YES               NO                NO (workers
                                                                         only)
Autoscaling?       YES               YES               NO                NO
Cloud provider?    NO                YES (Nutanix)     NO                NO
═══════════════════════════════════════════════════════════════════════════════════

                   ── STORAGE (ODF) ──
ODF rebuild?       YES ⚠️            YES ⚠️            YES ⚠️            NO ✓
Ceph migration?    YES (weeks)       YES (weeks)       YES (weeks)       NO ✓
PVC backup/        YES (all PVCs)    YES (all PVCs)    YES (all PVCs)    NO ✓
  restore?
StorageClasses?    Recreate all 7    Recreate all 7    Recreate all 7    NO ✓
TopoLVM?           Recreate          Recreate          Recreate          Re-provision
Data loss risk?    HIGH              HIGH              HIGH              ZERO
═══════════════════════════════════════════════════════════════════════════════════

                   ── MONITORING ──
Prometheus?        Reinstall         Reinstall         Reinstall         NO ✓
Alertmanager?      Recreate rules    Recreate rules    Recreate rules    NO ✓
Thanos?            Reinstall         Reinstall         Reinstall         NO ✓
Loki?              Reinstall         Reinstall         Reinstall         NO ✓
Tempo?             Reinstall         Reinstall         Reinstall         NO ✓
Jaeger?            Reinstall         Reinstall         Reinstall         NO ✓
ECK?               Reinstall         Reinstall         Reinstall         NO ✓
Rules intact?      NO (recreate)     NO (recreate)     NO (recreate)     YES ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── OPERATORS (65) ──
Reinstall all?     YES (65 ops)      YES (65 ops)      YES (65 ops)      NO ✓
CRDs intact?       NO (recreate)     NO (recreate)     NO (recreate)     YES ✓
Config intact?     NO (reconfigure)  NO (reconfigure)  NO (reconfigure)  YES ✓
Dependencies?      Re-solve          Re-solve          Re-solve          NO ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── GITOPS (ArgoCD) ──
ArgoCD?            Reinstall         Reinstall         Reinstall         NO ✓
Re-point apps?     ALL 135 projects  ALL 135 projects  ALL 135 projects  NO ✓
Re-sync?           YES               YES               YES               NO ✓
Config intact?     NO                NO                NO                YES ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── PIPELINES (Tekton) ──
Tekton?            Reinstall         Reinstall         Reinstall         NO ✓
Pipelines-as-      Reinstall         Reinstall         Reinstall         NO ✓
  Code?
Pipeline runs?     LOST              LOST              LOST              PRESERVED ✓
Webhooks?          Reconfigure       Reconfigure       Reconfigure       NO ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── INGRESS (66 routes) ──
Routes intact?     NO (recreate)     NO (recreate)     NO (recreate)     YES ✓
SSL certs?         Regenerate        Regenerate        Regenerate        YES ✓
DNS changes?       YES               YES               YES               NO ✓
Custom domains?    Reconfigure       Reconfigure       Reconfigure       NO ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── EGRESS ──
Network policies   Recreate ALL      Recreate ALL      Recreate ALL      NO ✓
  (108)?
Egress paths?      Reconfigure       Reconfigure       Reconfigure       NO ✓
Firewall rules?    Reconfigure       Reconfigure       Reconfigure       NO ✓
Egress nodes?      Reconfigure       Reconfigure       Reconfigure       NO ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── SECRETS/CONFIG ──
Secrets?           Recreate all      Recreate all      Recreate all      NO ✓
ConfigMaps?        Recreate all      Recreate all      Recreate all      NO ✓
PVCs?              Backup/restore    Backup/restore    Backup/restore    NO ✓
═══════════════════════════════════════════════════════════════════════════════════

                   ── HARDWARE REQUIREMENTS ──
New servers?       YES (12 servers)  YES (12 servers)  YES (12 servers)  YES (3 servers)
BMC/IPMI?          YES               YES               NO (Hyper-V mgmt) YES
Network config?    Full rebuild      Full rebuild      Full rebuild      Same VLAN
Storage config?    Local disks       Nutanix storage   Hyper-V VHDX     N/A
═══════════════════════════════════════════════════════════════════════════════════

VERDICT:           HIGH RISK         HIGH RISK         HIGH RISK         LOW RISK
                   WEEKS OF WORK     WEEKS OF WORK     WEEKS OF WORK     DAYS
                   DATA LOSS RISK    DATA LOSS RISK    DATA LOSS RISK    ZERO RISK
                   ════════════      ════════════      ════════════      ════════════
                   NOT RECOMMENDED   NOT RECOMMENDED   NOT RECOMMENDED   RECOMMENDED ✓
═══════════════════════════════════════════════════════════════════════════════════
```


## Platform Comparison

```
═══════════════════════════════════════════════════════════════════════════
FEATURE            OPTION 1          OPTION 2          OPTION 3          OPTION 4
                   (Bare Metal)      (Nutanix)         (Hyper-V)         (Hybrid)
═══════════════════════════════════════════════════════════════════════════
Platform type      platform: none    platform: nutanix platform: none    platform: none

Cloud provider?    NO                YES (Nutanix)     NO                NO
Dynamic storage?   NO (manual)       YES (Nutanix)     NO (manual)       NO
Load balancer?     Manual            YES (Nutanix)     Manual            Manual
Node hostname?     Manual            YES (Nutanix)     Manual            Manual
Autoscaling?       NO                YES               NO                NO
Machine API?       NO                YES               NO                NO
═══════════════════════════════════════════════════════════════════════════

INSTALL COMPLEXITY:
  Option 1:  Manual (ISO + Ignition)           ██████████ HIGH
  Option 2:  IPI (Nutanix auto-provision)      ████░░░░░░ MODERATE
  Option 3:  Manual (ISO + Ignition)           ██████████ HIGH
  Option 4:  IPI for masters, manual workers   ████░░░░░░ MODERATE
═══════════════════════════════════════════════════════════════════════════

LIFECYCLE MANAGEMENT:
  Option 1:  Manual (no Machine API)           ██████████ HIGH
  Option 2:  Automated (Machine API)           ████░░░░░░ MODERATE
  Option 3:  Manual (no Machine API)           ██████████ HIGH
  Option 4:  Manual for workers only           ███░░░░░░░ LOW-MOD
═══════════════════════════════════════════════════════════════════════════

SUPPORT LEVEL:
  Option 1:  Full Red Hat SLA                  ✓✓✓✓✓✓✓✓✓✓ FULL
  Option 2:  Full Red Hat SLA                  ✓✓✓✓✓✓✓✓✓✓ FULL
  Option 3:  Bare metal only (no Hyper-V help) ✓✓✓✓░░░░░░ PARTIAL
  Option 4:  Full Red Hat SLA                  ✓✓✓✓✓✓✓✓✓✓ FULL
═══════════════════════════════════════════════════════════════════════════
```


## Why Option 4 Wins (Phase 1) + Phase 2 Extension

```
╔════════════════════════════════════════════════════════════════════════╗
║                                                                        ║
║  2-PHASE MIGRATION PLAN:                                              ║
║                                                                        ║
║  Phase 1 (Option 4): VMware Masters + BM Workers                      ║
║  - Effort: 1-2 weeks                                                  ║
║  - Risk: LOW                                                           ║
║  - VMware savings: 25%                                                 ║
║  - ODF impact: ZERO                                                    ║
║  - Supported: YES (platform: none, full RH SLA)                       ║
║                                                                        ║
║  Phase 2 (Plan B): BM Masters + BM Workers                            ║
║  - Effort: 2-3 weeks (per node × 3 nodes)                             ║
║  - Risk: MEDIUM-HIGH (etcd involved)                                   ║
║  - VMware savings: Additional 25%                                      ║
║  - ODF impact: ZERO (Ceph stays untouched)                            ║
║  - Supported: YES (platform: none, full RH SLA)                       ║
║  - Method: One-by-one Replacement control plane nodes                               ║
║                                                                        ║
║  Total VMware savings: 50% (12 → 6 licenses)                         ║
║                                                                        ║
║  Phase 1 Reason:                                                       ║
║  - Lowest risk start                                                   ║
║  - Only need 3 BM servers                                              ║
║  - Worker replacement is simplest (no etcd)                            ║
║                                                                        ║
║  Phase 2 Reason:                                                       ║
║  - Save more VMware licenses                                           ║
║  - Plan B doesn't require reinstalling everything                      ║
║  - ODF, operators, routes all preserved                                ║
║  - Only etcd member replacement one at a time                                          ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝
```

### Phase 1 Advantages (same as before)
1. ZERO ODF rebuild
2. ZERO monitoring rebuild
3. ZERO operator reconfiguration
4. ZERO GitOps changes
5. ZERO pipeline changes
6. ZERO ingress changes
7. ZERO egress changes
8. EFFORT: 1-2 weeks vs 6-10 weeks
9. RISK: LOW vs HIGH
10. SUPPORTED: Red Hat SLA applies

### Phase 2 Advantages (Plan B)
1. ZERO ODF rebuild (Ceph stays untouched)
2. ZERO monitoring rebuild
3. ZERO operator reconfiguration
4. ZERO GitOps changes
5. ZERO pipeline changes
6. ZERO ingress changes
7. ZERO egress changes
8. Only etcd member replacement
9. Cluster remains operational throughout
10. SUPPORTED: Red Hat SLA applies


## Summary Table

```
═══════════════════════════════════════════════════════════════════════════
OPTION    TIME      RISK      EFFORT    SAVINGS   VERDICT
═══════════════════════════════════════════════════════════════════════════
1         6-10 wk   HIGH      EXTREME   100%      NOT RECOMMENDED
2         4-8 wk    HIGH      HIGH      100%      NOT RECOMMENDED
3         6-10 wk   HIGH      EXTREME   100%      NOT RECOMMENDED
4 (Ph1)   1-2 wk    LOW       MODERATE  25%       PHASE 1 ✓
4+Ph2     3-5 wk    MED-HIGH  MODERATE  50%       PHASE 2 ✓ (Plan B)
═══════════════════════════════════════════════════════════════════════════

2-PHASE PLAN:
  Phase 1: Workers VM → BM (1-2 weeks, LOW risk, -25% VMware)
  Phase 2: Masters VM → BM (2-3 weeks/node, MED-HIGH risk, -25% VMware)
  Total:   50% VMware license savings, ZERO data migration
═══════════════════════════════════════════════════════════════════════════
```

---


## OCP 4.21 Technology Preview Clarification

### What is this TP Feature
OCP 4.21 added a new feature: adding bare-metal compute machines to an already-installed vSphere cluster (using `platform: vsphere`).

### Your Cluster is Not Affected
Your cluster uses `platform: none`, so:
- ❌ The TP feature doesn't apply to you
- ❌ You don't need to turn off vSphere CSI (you don't have it installed)
- ❌ You don't need to handle the manual CSR approval requirements
- ✅ Your hybrid deployment method has always been fully supported

### TP Feature Limitations (for reference only)
- No Machine API management
- No autoscaling
- No SLA guarantee
- Requires turning off vSphere CSI (you don't have it, so not affected)

---


## Technical Reference: Multi-site Deployment Requirements

If Phase 2 control plane migrates to BM, you need to ensure compliance with multi-site network requirements:

### etcd Requirements
- etcd peer RTT < 100ms (not regular network RTT)
- OCP 4.16+ can relax to 500ms (hardware speed tolerance)
- Must use high-speed, low-latency storage (SSD/NVMe)

### Network Requirements
- L3 direct IP connectivity
- MTU consistency
- GSLB for traffic scheduling (if cross-site is needed)

### Storage Requirements
- Cross-site storage must consider reachability across all sites
- Registry should use object storage
- Layered storage (like ODF) requires latency < 10ms RTT

### Workload Scheduling
- Use topology-aware scheduling (OCP 4.6+)
- Avoid SPoF (Single Point of Failure)

---


## Future Considerations

After workers are migrated, you could ALSO migrate infra04-06 (monitoring/quay/egress) to bare metal to save 3 more VMware licenses (total 50% savings). But do workers FIRST - lowest risk, highest impact.

---


---

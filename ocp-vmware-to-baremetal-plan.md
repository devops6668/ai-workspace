# OCP VMware to Bare Metal Migration Plan

**Author:** Hermes Agent  
**Date:** 2026-08-10 (updated 2026-09-14 v5)  
**Cluster:** lab.devops.local (OCP 4.20.27)  
**Platform:** BareMetal (platform: none)  
**Status:** Part 1 reviewed, Part 2 ready to execute (4-phase plan)  
**Red Hat Articles:**
- https://access.redhat.com/solutions/5020331 (mixed virtual/bare metal support)
- https://access.redhat.com/solutions/7061543 (Hyper-V support)
- https://access.redhat.com/articles/4207611 (non-tested platforms)
- https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/replacing_nodes/index (ODF node replacement)
- Red Hat KB: Guidance for OCP Clusters - Deployments Spanning Multiple Sites

---

## Table of Contents

### Part 1: Solution Analysis
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

### Part 2: Solution Selection and Execution
- [Phase 1a: Workers VM → BM](#phase-1a-workers-vm--bm)
- [Phase 1b: ODF VM → BM (Ceph OSD Rolling Replace)](#phase-1b-odf-vm--bm-ceph-osd-rolling-replace)
- [Phase 1c: Monitoring/Other VM → BM](#phase-1c-monitoringother-vm--bm)
- [Phase 2: Masters VM → BM (Checklist)](#phase-2-masters-vm--bm-plan-b)
- [Phase 2: Control Plane Migration (Detailed Steps)](#phase-2-control-plane-migration-plan-b---One-by-one Replacement)
- [Bare Metal Network Configuration (NIC Bonding)](#bare-metal-network-configuration-nic-bonding)
- [References](#references)

---

# Part 1: Solution Analysis

---

## Executive Summary

This plan migrates an existing OCP 4.20.27 cluster from VMware VMs to bare metal, preserving all existing configurations, data, and operators.

> **Updated 2026-09-14 (v4)**: Restructured into 4 phases (1a/1b/1c/2). Phase 1 now covers ALL non-control-plane nodes (workers + ODF + monitoring). Phase 2 covers control plane replacement.

**Key Points:**
- **No data migration needed** — ODF/Ceph stays intact (rolling OSD replacement)
- **No rebuild needed** — 65 operators, 66 routes, 108 network policies all preserved
- **Cluster stays running** throughout the entire migration
- **Supported:** Red Hat SLA applies (platform: none, mixed VM/BM)


## Final Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Final State: All Bare Metal (12 nodes)                 │
├─────────────────────────────────────────────────────────┤
│  Master Nodes x 3 (bare metal)                          │
│  master01 (12CPU/64GB + NVMe):                          │
│    etcd, API server, control plane                      │
│    ODF/Ceph OSD (NVMe dedicated disk)                   │
│    Monitoring stack (Prometheus, Alertmanager, Thanos)   │
│    Loki, Tempo, Jaeger                                  │
│  master02 (12CPU/64GB + NVMe):                          │
│    etcd, API server, control plane                      │
│    ODF/Ceph OSD (NVMe dedicated disk)                   │
│    GitOps (ArgoCD), Pipelines (Tekton)                  │
│    Quay registry                                        │
│  master03 (12CPU/64GB + NVMe):                          │
│    etcd, API server, control plane                      │
│    ODF/Ceph OSD (NVMe dedicated disk)                   │
│    Service Mesh, Elasticsearch ECK                      │
│    ACM, Multicluster Engine                             │
│    NeuVector/Aqua/RHACS, Cert Manager                   │
│    Confluent (Kafka), CloudNativePG                     │
│    DevWorkspace, Web Terminal                           │
│    Kasten K10, OpenTelemetry, KEDA                      │
├─────────────────────────────────────────────────────────┤
│  Worker Nodes x 6 (bare metal)                          │
│  worker01 (8CPU/32GB): Apps + TopoLVM                   │
│  worker02 (8CPU/32GB): Apps + TopoLVM                   │
│  worker03 (32CPU/128GB): Apps + TopoLVM                 │
│  worker04 (16CPU/64GB): Apps + TopoLVM                  │
│  worker05 (16CPU/64GB): Apps + TopoLVM                  │
│  worker06 (16CPU/64GB): Apps + TopoLVM                  │
└─────────────────────────────────────────────────────────┘
```

**Note:** Each master node has a dedicated NVMe disk for ODF/Ceph OSD, separate from etcd storage. This eliminates I/O contention between etcd and Ceph.


## Phase Overview

```
Phase 1a: Worker VM → BM (3 BM nodes)
  Risk: LOW | Time: 1-2 weeks | Method: cordon/drain/replace

Phase 1b: ODF VM → BM (3 BM nodes, Ceph OSD rolling replace)
  Risk: MEDIUM | Time: 1-2 weeks | Method: add-then-remove (add first, remove later)
  Reference: ODF 4.20 Replacing nodes (Section 2.1.1)

Phase 1c: Monitoring/Other VM → BM (3 BM nodes)
  Risk: LOW | Time: 3-5 days | Method: cordon/drain/replace + nodeSelector update

Phase 2: Master VM → BM (3 BM nodes, etcd replacement)
  Risk: MEDIUM-HIGH | Time: 2-3 weeks | Method: delete Machine triggers etcd auto-remove
  Reference: OCP 4.20 "Replacing a healthy etcd member by scaling up and scaling down"

Total estimated time: 5-8 weeks
```

---


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

# Part 2: Solution Selection and Execution

---


## Phase 1: Workers VM → BM

> **Risk: LOW | Time: 1-2 weeks | Method: cordon/drain/replace**

#### Day 1-2: Prepare
- [ ] Provision 3 bare metal servers (match worker specs)
- [ ] worker01: 8 CPU, 32GB RAM
- [ ] worker02: 8 CPU, 32GB RAM
- [ ] worker03: 32 CPU, 128GB RAM
- [ ] Configure network (same VLAN as vSphere)
- [ ] confirm NIC names (`ip link` to query eno1/eno2/em1/em2 etc.)
- [ ] confirm Switch LACP support (has → mode 4, no → mode 1)
- [ ] Prepare NMState YAML (bonding + br-ex configure)
- [ ] Base64 encode NMState YAML
- [ ] Prepare MachineConfig manifest (one per node)
- [ ] Configure DNS for worker01-03
- [ ] Test BMC/IPMI access
- [ ] Download RHCOS ISO
- [ ] Extract Ignition config: `oc extract -n openshift-machine-api secret/worker-user-data-managed --keys=userData --to=- > worker.ign`

#### Day 3-4: Add Bare Metal Workers
- [ ] Boot worker01 with RHCOS ISO + worker.ign
- [ ] verify bonding status (`cat /proc/net/bonding/bond0`)
- [ ] verify OVS bridge (`ovs-vsctl show`)
- [ ] Verify node Ready
- [ ] Boot worker02 with RHCOS ISO + worker.ign
- [ ] verify bonding status
- [ ] verify OVS bridge
- [ ] Verify node Ready
- [ ] Boot worker03 with RHCOS ISO + worker.ign
- [ ] verify bonding status
- [ ] verify OVS bridge
- [ ] Verify node Ready

#### Day 5-7: Migrate Workloads
- [ ] worker01: cordon → drain → verify → shutdown VM
- [ ] worker02: cordon → drain → verify → shutdown VM
- [ ] worker03: cordon → drain → verify → shutdown VM

#### Day 8: Cleanup & Validate
- [ ] Remove VMware worker VMs from vCenter
- [ ] Decommission 3 VMware hosts
- [ ] test bonding failover (unplug a network cable to test)
- [ ] confirm all BM worker bonding normal
- [ ] Verify ODF health
- [ ] Verify monitoring
- [ ] Verify all 66 routes
- [ ] Verify all egress paths
- [ ] Verify ArgoCD sync
- [ ] Monitor for issues

#### Phase 1a Acceptance Criteria
- [ ] 3 BM workers Ready
- [ ] All apps running normally
- [ ] TopoLVM normal
- [ ] All routes normal
- [ ] All network policies normal
- [ ] ArgoCD sync normal

---


## Phase 2: Infra VM → BM (ODF + Monitoring)

> **Risk: MEDIUM | Time: 2-3 weeks | Method: add-then-remove (ODF) + cordon/drain (Monitoring)**

### Overview

Replace infra01-06 VMware VMs with bare metal nodes. Split into two sub-phases:
- **Phase 2a:** ODF/Ceph storage nodes (infra01-03) — Ceph OSD rolling replace
- **Phase 2b:** Monitoring/other infra nodes (infra04-06) — cordon/drain/replace

### Phase 2a: ODF VM → BM (Ceph OSD Rolling Replace)

> **Risk: MEDIUM | Time: 1-2 weeks | Method: add-then-remove**
> **Reference:** ODF 4.20 Replacing nodes — Section 2.1.1 "Replacing an operational node on bare metal user-provisioned infrastructure"

#### Phase 2a Concept

```
Add new BM storage node → wait for Ceph rebalance → remove old VM storage node
Repeat 3 times (infra01→bm-storage01, infra02→bm-storage02, infra03→bm-storage03)
```

**Reason for add-then-remove:** Ceph always has sufficient OSDs, data availability is not affected.

#### Phase 2a Prerequisites
- [ ] 3 BM storage machines ready (14 CPU, 32GB + local SSD for Ceph OSD)
- [ ] New BM disk size/type matches old infra
- [ ] RHCOS ISO ready
- [ ] Network connectivity (same VLAN)
- [ ] DNS forward/reverse resolution working
- [ ] BMC/IPMI available
- [ ] Phase 1 completed (3 BM workers in place)
- [ ] Ceph cluster healthy (`ceph health` = HEALTH_OK)

#### Each Storage Node Replacement Steps (repeat 3 times, one at a time)

##### Step A1: Add new BM storage node to cluster
```bash
# Install RHCOS + join cluster as worker
# Approve CSR
# Wait for node Ready
```

##### Step A2: Add ODF label to new node
```bash
oc label node <new-bm-storage> cluster.ocs.openshift.io/openshift-storage=""
```

##### Step A3: Update LocalVolumeDiscovery + LocalVolumeSet (add new node, keep old node)
```bash
# Find local storage namespace
local_storage_project=$(oc get csv --all-namespaces | awk '{print $1}' | grep local)
echo $local_storage_project

# Update LocalVolumeDiscovery (add new node, keep all old nodes)
oc edit -n $local_storage_project localvolumediscovery auto-discover-devices
# nodeSelector values add new node:
#   - infra01.example.com  # keep
#   - infra02.example.com  # keep
#   - infra03.example.com  # keep
#   - <new-bm-storage>     # add

# Update LocalVolumeSet (same - add new node)
oc get -n $local_storage_project localvolumeset
oc edit -n $local_storage_project localvolumeset localblock
# Add new node
```

##### Step A4: Verify new PV appeared
```bash
oc get pv | grep localblock | grep Available
# Expected: new Available PV present
```

##### Step A5: Wait for Ceph Rebalance + health
```bash
# ⚠️ Wait for Ceph healthy before continuing (may take several hours)
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph health
# Wait for HEALTH_OK
ceph osd tree
exit
```

##### Step B1: Scale down ODF pods on old node
```bash
# Identify ODF pods on old node
oc get pods -n openshift-storage -o wide | grep -i <old-infra>

# Scale down mon (if mon runs on this node)
oc scale deployment rook-ceph-mon-c --replicas=0 -n openshift-storage

# Scale down OSD
oc scale deployment rook-ceph-osd-0 --replicas=0 -n openshift-storage

# Scale down crashcollector
oc scale deployment --selector=app=rook-ceph-crashcollector,node_name=<old-infra> --replicas=0 -n openshift-storage
```

##### Step B2: Delete old OSD
```bash
# Verify old OSD ID
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph osd tree
# Note old OSD IDs on infra node
exit

# Run OSD removal job
oc process -n openshift-storage ocs-osd-removal \
  -p FAILED_OSD_IDS=<old-osd-id1>,<old-osd-id2>,<old-osd-id3> | oc create -f -

# Wait for removal job to complete
oc get pod -l job-name=ocs-osd-removal-job -n openshift-storage -w
# Wait for Completed

# Delete removal job
oc delete job ocs-osd-removal-job -n openshift-storage
```

##### Step B3: Update LocalVolumeDiscovery + LocalVolumeSet (remove old node)
```bash
# Update LocalVolumeDiscovery (remove old node)
oc edit -n $local_storage_project localvolumediscovery auto-discover-devices
# nodeSelector values remove old node

# Update LocalVolumeSet (same - remove old node)
oc edit -n $local_storage_project localvolumeset localblock
# Remove old node
```

##### Step B4: Cordon + Drain + Delete old VM
```bash
oc adm cordon <old-infra>
oc adm drain <old-infra> --force --delete-emptydir-data --ignore-daemonsets
oc delete node <old-infra>
```

##### Step B5: Verify
```bash
# Verify Ceph health
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph health
ceph osd tree
exit

# Verify all ODF pods normal
oc get pods -n openshift-storage | grep -v Running

# Verify CSI driver normal
oc get pods -n openshift-storage | grep csi

# Verify StorageClass normal
oc get sc

# Verify PVC normal
oc get pvc --all-namespaces | grep -v Bound
```

##### Step B6: Wait for Ceph Rebalance to complete
```bash
# ⚠️ May take several hours
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph -s
# Wait for "recovery" or "backfill" to complete
# Wait for ceph health to become HEALTH_OK
exit
```

##### Step B7: Wait for Stability
```
⚠️ Wait at least 24 hours to observe stability:
- Ceph HEALTH_OK
- All PVCs Bound
- All ODF pods Running
- Applications healthy
```

##### Repeat Step A1-B7 (infra02→bm-storage02, infra03→bm-storage03)

#### Phase 2a Acceptance Criteria
- [ ] 3 BM storage nodes Ready
- [ ] Ceph HEALTH_OK
- [ ] All OSDs normal
- [ ] All PVCs Bound
- [ ] All StorageClasses normal
- [ ] All ODF pods Running
- [ ] All CSI driver pods Running

#### Phase 2a ⚠️ Important Notes
1. **Replace only one node at a time** — Do not replace multiple simultaneously
2. **Wait for Ceph HEALTH_OK** — Wait for rebalance to complete before next node
3. **Disk specifications must match** — New BM disk size/type must match old infra
4. **Rebalance time** — Depends on data volume, may take several hours
5. **I/O impact** — Significant background I/O during rebalance
6. **Scale down sequence** — Scale down ODF pods first, then cordon/drain

---

### Phase 2b: Monitoring/Other VM → BM

> **Risk: LOW | Time: 3-5 days | Method: cordon/drain/replace + nodeSelector update**

#### Phase 2b Concept

```
infra04-06 (VM) → bm-infra01-03 (BM)
Monitoring, Quay, Egress components follow nodeSelector migration
```

#### Phase 2b Prerequisites
- [ ] 3 BM infra machines ready (16 CPU, 64GB)
- [ ] RHCOS ISO ready
- [ ] Network connectivity (same VLAN)
- [ ] Phase 1 + 2a completed

#### Each Infra Node Replacement Steps (repeat 3 times)

##### Step C1: Add new BM infra node to cluster
```bash
# Install RHCOS + join cluster as worker
# Approve CSR
# Wait for node Ready
```

##### Step C2: Update monitoring/quoter/egress nodeSelector
```bash
# Update OpenShift Monitoring stack nodeSelector
# Change Prometheus/Alertmanager/Thanos nodeSelector to point to new BM node

# Update Quay nodeSelector (if applicable)

# Update Egress nodeSelector (if applicable)
```

##### Step C3: Cordon + Drain old VM
```bash
oc adm cordon <old-infra>
oc adm drain <old-infra> --force --delete-emptydir-data --ignore-daemonsets
```

##### Step C4: Delete old VM
```bash
oc delete node <old-infra>
# Delete VM from vCenter
```

##### Step C5: Verify
```bash
# Verify monitoring stack normal
oc get pods -n openshift-monitoring

# Verify Quay normal (if applicable)

# Verify Egress normal

# Verify all pods normal
oc get pods --all-namespaces | grep -v Running | grep -v Completed
```

##### Repeat Step C1-C5 (infra05→bm-infra02, infra06→bm-infra03)

#### Phase 2b Acceptance Criteria
- [ ] 3 BM infra nodes Ready
- [ ] Monitoring stack normal (Prometheus, Alertmanager, Thanos)
- [ ] Quay normal
- [ ] Egress normal
- [ ] All pods normal
- [ ] All alerts normal

---

> **Updated 2026-09-14 (v3)**: Based on expert review + OCP 4.20 official documentation correction.
> - Core correction: delete Machine object Triggers etcd Operator automatic member removal, no more manual `etcdctl member remove`
> - Added: etcd Secrets cleanup, HAProxy backend update, etcd Quorum Guard explanation, CSR monitor script, stability Acceptance Criteria
> - Reference: OCP 4.20 "Replacing a healthy etcd member by scaling up and scaling down"

### Why Choose Plan B
- No need to reinstall ODF, operators, routes, ArgoCD, etc.
- Cluster remains operational throughout
- Only etcd member replacement one at a time
- Core method corresponds to Red Hat official documentation:"Replacing a healthy etcd member by scaling up and scaling down"

### etcd Quorum Guard Explanation
etcd Quorum Guard is a protection mechanism that blocks drain operations if drain would cause etcd quorum loss. During the 4 CP node transition period, Quorum Guard allows draining old nodes (since there are still enough etcd members). But if you attempt to force drain one of only 3 CP nodes, Quorum Guard will block it. This is a protection mechanism, not an error.

### Prerequisites
- 3 BM servers ready (same master specs: 12 CPU, 64GB)
- RHCOS ISO ready (matching OCP version 4.20.27)
- Network connectivity (same VLAN)
- DNS forward/reverse resolution normal
- BMC/IPMI accessible
- HTTP server ready to host master Ignition config
- HAProxy backend configured (able to add new BM node IP)
- Verify no ControlPlaneMachineSet (`platform: none` clusters typically don't have one)

### Extract Master Ignition Config
```bash
# Note: if MachineConfig update was applied after cluster install, master-user-data-managed will auto-update
# Ensure extracting the latest version before adding new nodes
oc extract -n openshift-machine-api secret/master-user-data-managed \
  --keys=userData --to=- > master.ign
```

### CSR Monitoring Script (keep a terminal running throughout Phase 3)
```bash
watch -n 5 'oc get csr | grep Pending'
```

### Steps (replace one at a time, repeat 3 times)

#### Step 1: Pre-check + Backup etcd (mandatory before each operation!)
```bash
# 1a. Verify cluster health
oc get nodes
oc get co | grep -v "True.*False.*False"

# 1b. confirm etcd healthy (3 members, all healthy)
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# 1c. Verify no ControlPlaneMachineSet
oc get controlplanemachineset -n openshift-machine-api

# 1d. Backup etcd (using official backup script)
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# 1e. verify backup
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  ls -la /home/core/assets/backup/
```

#### Step 2: Prepare BareMetalHost + Machine object
```bash
# Create BMC Secret
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: master-bm-<N>-bmc-secret
  namespace: openshift-machine-api
type: Opaque
data:
  username: $(echo -n '<bmc_user>' | base64)
  password: $(echo -n '<bmc_pass>' | base64)
EOF

# Create BareMetalHost
cat <<EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: master-bm-<N>
  namespace: openshift-machine-api
spec:
  automatedCleaningMode: disabled
  bmc:
    address: idrac-virtualmedia://<bmc_ip>/redfish/v1/Systems/System.Embedded.1
    credentialsName: master-bm-<N>-bmc-secret
    disableCertificateVerification: true
  bootMACAddress: "<NIC_MAC>"
  bootMode: UEFI
  externallyProvisioned: false
  online: true
EOF

# Wait for BMH status to become available
oc get bmh -n openshift-machine-api master-bm-<N> -w
```

#### Step 3: Install RHCOS on BM server
```bash
# ⚠️ If BMH is configured with Redfish Virtual Media (BMC/IPMI available),
# RHCOS installation is handled automatically by Bare Metal Operator (externallyProvisioned: false), Step 3 can be skipped.
# Step 3 is only for scenarios without BMC support, requiring manual USB/ISO insertion.

# Manual installation method (only when BMC is unavailable):
# Method 1: coreos-installer (boot from ISO)
sudo coreos-installer install /dev/sda \
    --ignition-url=http://<http_server>/master.ign \
    --insecure-ignition \
    --platform=metal

# Method 2: Boot directly from ISO + Ignition
# Place master.ign in ISO or use PXE boot
```

#### Step 4: Create Machine object and join cluster
```bash
# Create Machine object (copy providerSpec from another control plane Machine)
cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: Machine
metadata:
  annotations:
    metal3.io/BareMetalHost: openshift-machine-api/master-bm-<N>
  labels:
    machine.openshift.io/cluster-api-cluster: <cluster-name>
    machine.openshift.io/cluster-api-machine-role: master
    machine.openshift.io/cluster-api-machine-type: master
  name: <cluster-name>-master-bm-<N>
  namespace: openshift-machine-api
spec:
  metadata: {}
  providerSpec:
    value:
      apiVersion: baremetal.cluster.k8s.io/v1alpha1
      customDeploy:
        method: install_coreos
      hostSelector: {}
      image:
        checksum: ""
        url: ""
      kind: BareMetalMachineProviderSpec
      metadata:
        creationTimestamp: null
      userData:
        name: master-user-data-managed
EOF
```

```bash
# approve CSR (new node will generate client + server CSRs)
# Method 1: Manual approval
oc get csr | grep Pending
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs oc adm certificate approve

# Method 2: Auto-approval script (run in a terminal throughout Phase 3)
while true; do
  PENDING=$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  if [ -n "$PENDING" ]; then
    echo "$PENDING" | xargs oc adm certificate approve
    echo "$(date): Approved CSRs"
  fi
  sleep 10
done

# wait for node Ready
oc get nodes -w
# wait for <cluster-name>-master-bm-<N> status to become Ready
```

#### Step 5: Wait for etcd Operator to automatically add new member + HAProxy update
```bash
# ⚠️ Important: etcd Operator automatically detects new control plane nodes
# and automatically adds the new node to the etcd cluster, no manual patch or etcdctl member add needed
# Wait approximately 5-10 minutes

# ⚠️ Critical wait steps: must see 4 members all "is healthy" before proceeding
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table

# Expected output: 4 members (3 old + 1 new)
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# |        ID        | STATUS  |  NAME   |        PEER ADDRS        |       CLIENT ADDRS        |  IS LEARNER |
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# | <id1>            | started | master01| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id2>            | started | master02| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id3>            | started | master03| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id4>            | started | new-bm  | https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# +------------------+---------+---------+---------------------------+---------------------------+------------+

# verify all etcd members healthy
etcdctl endpoint health --cluster
# Expected: 4 endpoints all "is healthy"
exit

# update HAProxy: add new BM node IP to backend
# In HAProxy config add new node to:
#   backend openshift-api-server
#   backend machine-config-server
# Then reload HAProxy
# systemctl reload haproxy
```

#### Step 6: Remove old VM — Cordon + Drain + delete Machine (triggers automatic etcd remove)
```bash
# ⚠️ Important: cordon/drain first, then delete Machine object
# delete Machine triggers etcd Operator to automatically remove the corresponding etcd member
# No need to manually run etcdctl member remove

# 6a. Cordon old VM node (stop new Pod scheduling)
oc adm cordon <old-vm-master-name>

# 6b. Drain old VM node (evict Pods)
# Note: etcd Quorum Guard allows this operation with 4 CP nodes
oc adm drain <old-vm-master-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 6c. Delete old VM Machine object
# ⚠️ This step triggers etcd Operator to automatically remove the corresponding etcd member
# No need to manually run etcdctl member remove
oc delete machine <old-vm-machine-name> -n openshift-machine-api

# 6d. Delete old VM BMH object
oc delete bmh <old-vm-bmh-name> -n openshift-machine-api

# 6e. Wait for Node object to auto-delete (automatically triggered after Machine delete)
oc get nodes -w
```

#### Step 7: Clean up etcd Secrets + Force redeployment + verify
```bash
# 7a. Clean up old node etcd TLS secrets
# After removing old node, clean up its corresponding etcd secrets to avoid etcd Operator alerts
oc get secrets -n openshift-etcd | grep <old-vm-master-name>
# Expected to see:
# etcd-peer-<old-master-name>
# etcd-serving-<old-master-name>
# etcd-serving-metrics-<old-master-name>

oc get secrets -n openshift-etcd | grep <old-vm-master-name> | \
  awk '{print $1}' | xargs oc -n openshift-etcd delete secrets

# 7b. Force etcd Operator to redeploy all etcd pods (ensure config consistency)
# ⚠️ During force redeployment, etcd will have rolling restart, which is normal behavior (2 of 3 members still healthy, quorum unaffected)
# Wait for all etcd pods to become Running before proceeding to Step 8 verification
oc patch etcd cluster \
  -p='{"spec": {"forceRedeploymentReason": "master-replacement-'"$(date --rfc-3339=ns)"'"}}' \
  --type=merge

# Wait for etcd pods to finish redeployment
oc get pods -n openshift-etcd -w
# Wait for all etcd pods to become Running

# 7c. Update HAProxy: remove old VM node IP from backend
# In HAProxy config remove old node
# Then reload HAProxy
# systemctl reload haproxy

# 7d. Update DNS (if needed)
```

#### Step 8: Final verify (stability Acceptance Criteria)
```bash
# etcd healthy (3 members, all healthy)
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# All nodes Ready
oc get nodes

# All Cluster Operators normal (Available=True, Progressing=False, Degraded=False)
oc get co | grep -v "True.*False.*False"

# ODF healthy
oc get pods -n openshift-storage

# Monitoring system no alerts
oc get alerts --all-namespaces | grep -i "firing"

# Applications normal
oc get routes --all-namespaces | wc -l
```

**⚠️ Stability acceptance: all of the following conditions must be met before proceeding to next node:**
- [ ] etcd cluster 3 members all healthy
- [ ] All Cluster Operators Available=True, Progressing=False, Degraded=False
- [ ] All nodes Ready
- [ ] Monitoring system no new alerts (especially etcd-related)
- [ ] Wait at least 24 hours to observe stability

### ⚠️ Phase 3 Risk Reminders
1. **Replace only one at a time** — wait for etcd to fully stabilize before proceeding (recommend waiting 24 hours)
2. **3 control planes = tolerate 1 failure** — if another fails during replacement, cluster will have issues
3. **Schedule maintenance window** — etcd will have brief instability during replacement (during force redeployment)
4. **CSR approval** — use auto-approval script (run in a terminal throughout Phase 3)
5. **Time estimate** — each node approximately 2-3 hours (excluding 24-hour stability observation)
6. **HAProxy update** — must be updated promptly during steps, otherwise API requests will be routed to removed old VM
7. **DNS** — need to update control plane node DNS records
8. **etcd Quorum Guard** — allows drain with 4 CP nodes, blocks with 3 (protection mechanism)
9. **etcd Secrets** — old node TLS secrets must be cleaned up to avoid Operator alerts

### Phase 3 Command Quick Reference
```bash
# Verify cluster health
oc get nodes && oc get co | grep -v "True.*False.*False"

# backup
oc exec -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# Add (automatic) — etcd Operator handles automatically, no manual commands needed

# Remove (automatic) — delete Machine object triggers
oc delete machine <old-machine-name> -n openshift-machine-api

# Clean up etcd secrets
oc get secrets -n openshift-etcd | grep <old-name> | awk '{print $1}' | \
  xargs oc -n openshift-etcd delete secrets

# Force redeployment
oc patch etcd cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'$(date --rfc-3339=ns)'"}}' --type=merge

# verify
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit
```

---


## Phase 3: Masters VM → BM (etcd Replacement)

> **Risk: MEDIUM-HIGH | Time: 2-3 weeks | Method: delete Machine triggers etcd auto-remove**
> **Reference:** OCP 4.20 "Replacing a healthy etcd member by scaling up and scaling down"

### Why Choose Plan B (One-by-one Replacement)
- No need to reinstall ODF, operators, routes, ArgoCD, etc.
- Cluster remains operational throughout
- Only etcd member replacement one at a time
- Core method corresponds to Red Hat official documentation: "Replacing a healthy etcd member by scaling up and scaling down"

### etcd Quorum Guard Explanation
etcd Quorum Guard is a protection mechanism that blocks drain operations if drain would cause etcd quorum loss. During the 4 CP node transition period, Quorum Guard allows draining the old node (because there are still enough etcd members). However, if you attempt to force drain one of only 3 CP nodes, Quorum Guard will block it. This is a protection mechanism, not an error.

### Prerequisites
- [ ] 3 BM machines ready (12 CPU, 64GB each)
- [ ] RHCOS ISO ready (matching OCP version 4.20.27)
- [ ] Network connectivity (same VLAN)
- [ ] DNS forward/reverse resolution working
- [ ] BMC/IPMI available
- [ ] HTTP server ready for ignition config (master.ign)
- [ ] HAProxy backend configured (can add new BM node IP)
- [ ] Verify no ControlPlaneMachineSet: `oc get controlplanemachineset -n openshift-machine-api`
- [ ] Extract master Ignition config: `oc extract -n openshift-machine-api secret/master-user-data-managed --keys=userData --to=- > master.ign`
- [ ] Keep a CSR monitoring terminal running: `watch -n 5 'oc get csr | grep Pending'`

### Steps (repeat 3 times, one node at a time)

#### Step 1: Pre-check + Backup etcd (required before every operation!)
```bash
# 1a. Verify cluster health
oc get nodes
oc get co | grep -v "True.*False.*False"

# 1b. Verify etcd healthy (3 members, all healthy)
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# 1c. Verify no ControlPlaneMachineSet
oc get controlplanemachineset -n openshift-machine-api

# 1d. Backup etcd (using official backup script)
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# 1e. Verify backup
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  ls -la /home/core/assets/backup/
```

#### Step 2: Create BareMetalHost + Machine object
```bash
# Create BMC Secret
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: master-bm-<N>-bmc-secret
  namespace: openshift-machine-api
type: Opaque
data:
  username: $(echo -n '<bmc_user>' | base64)
  password: $(echo -n '<bmc_pass>' | base64)
EOF

# Create BareMetalHost
cat <<EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: master-bm-<N>
  namespace: openshift-machine-api
spec:
  automatedCleaningMode: disabled
  bmc:
    address: idrac-virtualmedia://<bmc_ip>/redfish/v1/Systems/System.Embedded.1
    credentialsName: master-bm-<N>-bmc-secret
    disableCertificateVerification: true
  bootMACAddress: "<NIC_MAC>"
  bootMode: UEFI
  externallyProvisioned: false
  online: true
EOF

# Wait for BMH status to become available
oc get bmh -n openshift-machine-api master-bm-<N> -w
```

#### Step 3: Install RHCOS to BM machine
```bash
# ⚠️ If BMH is configured with Redfish Virtual Media (BMC/IPMI available),
# RHCOS installation is handled automatically by Bare Metal Operator (externallyProvisioned: false), Step 3 can be skipped.
# Step 3 is only for scenarios without BMC support, requiring manual USB/ISO insertion.

# Manual installation method (only when BMC is unavailable):
# Method 1: coreos-installer (boot from ISO)
sudo coreos-installer install /dev/sda \
    --ignition-url=http://<http_server>/master.ign \
    --insecure-ignition \
    --platform=metal

# Method 2: Use ISO + Ignition directly
# Place master.ign in ISO or use PXE boot
```

#### Step 4: Create Machine object and join cluster
```bash
# Create Machine object (copy providerSpec from another control plane Machine)
cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: Machine
metadata:
  annotations:
    metal3.io/BareMetalHost: openshift-machine-api/master-bm-<N>
  labels:
    machine.openshift.io/cluster-api-cluster: <cluster-name>
    machine.openshift.io/cluster-api-machine-role: master
    machine.openshift.io/cluster-api-machine-type: master
  name: <cluster-name>-master-bm-<N>
  namespace: openshift-machine-api
spec:
  metadata: {}
  providerSpec:
    value:
      apiVersion: baremetal.cluster.k8s.io/v1alpha1
      customDeploy:
        method: install_coreos
      hostSelector: {}
      image:
        checksum: ""
        url: ""
      kind: BareMetalMachineProviderSpec
      metadata:
        creationTimestamp: null
      userData:
        name: master-user-data-managed
EOF
```

```bash
# Approve CSRs (new node produces client + server CSRs)
# Method 1: Manual approval
oc get csr | grep Pending
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs oc adm certificate approve

# Method 2: Auto-approval script (keep running throughout Phase 3)
while true; do
  PENDING=$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  if [ -n "$PENDING" ]; then
    echo "$PENDING" | xargs oc adm certificate approve
    echo "$(date): Approved CSRs"
  fi
  sleep 10
done

# Wait for node Ready
oc get nodes -w
# Wait for <cluster-name>-master-bm-<N> to become Ready
```

#### Step 5: Wait for etcd Operator to auto-add new member + HAProxy update
```bash
# ⚠️ Important: etcd Operator automatically detects new control plane node
# and automatically adds new node to etcd cluster, no manual patch or etcdctl member add needed
# Wait approximately 5-10 minutes

# ⚠️ Critical wait step: Must see 4 members all "is healthy" before continuing
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table

# Expected output: 4 members (3 old + 1 new)
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# |        ID        | STATUS  |  NAME   |        PEER ADDRS        |       CLIENT ADDRS        |  IS LEARNER |
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# | <id1>            | started | master01| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id2>            | started | master02| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id3>            | started | master03| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id4>            | started | new-bm  | https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# +------------------+---------+---------+---------------------------+---------------------------+------------+

# Verify all etcd members healthy
etcdctl endpoint health --cluster
# Expected: 4 endpoints all "is healthy"
exit

# Update HAProxy: add new BM node IP to backend
# Add new node to HAProxy config:
#   backend openshift-api-server
#   backend machine-config-server
# Then reload HAProxy
# systemctl reload haproxy
```

#### Step 6: Remove Old VM — Cordon + Drain + Delete Machine (triggers automatic etcd removal)
```bash
# ⚠️ Important: Cordon/drain first, then delete Machine object
# Deleting Machine triggers etcd Operator automatic member removal
# No need to manually run etcdctl member remove

# 6a. Cordon old VM node (stop new Pod scheduling)
oc adm cordon <old-vm-master-name>

# 6b. Drain old VM node (evict Pods)
# Note: etcd Quorum Guard allows this operation at 4 CP nodes
oc adm drain <old-vm-master-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 6c. Delete old VM Machine object
# ⚠️ This step triggers etcd Operator automatic member removal
# No need to manually run etcdctl member remove
oc delete machine <old-vm-machine-name> -n openshift-machine-api

# 6d. Delete old VM BMH object
oc delete bmh <old-vm-bmh-name> -n openshift-machine-api

# 6e. Wait for Node object to auto-delete (triggered by Machine deletion)
oc get nodes -w
```

#### Step 7: Clean etcd Secrets + Force Redeployment + Verify
```bash
# 7a. Clean up old node etcd TLS secrets
# After removing old node, clean up its etcd secrets to avoid etcd Operator alerts
oc get secrets -n openshift-etcd | grep <old-vm-master-name>
# Should see:
# etcd-peer-<old-master-name>
# etcd-serving-<old-master-name>
# etcd-serving-metrics-<old-master-name>

oc get secrets -n openshift-etcd | grep <old-vm-master-name> | \
  awk '{print $1}' | xargs oc -n openshift-etcd delete secrets

# 7b. Force etcd Operator to redeploy all etcd pods (ensure configuration consistency)
# ⚠️ Force redeployment causes rolling restart, which is normal (2 of 3 members remain healthy, quorum unaffected)
# Wait for all etcd pods to become Running before proceeding to Step 8 verification
oc patch etcd cluster \
  -p='{"spec": {"forceRedeploymentReason": "master-replacement-'$(date --rfc-3339=ns)'"}}' \
  --type=merge

# Wait for etcd pods to finish redeployment
oc get pods -n openshift-etcd -w
# Wait for all etcd pods to become Running

# 7c. Update HAProxy: remove old VM node IP from backend
# Remove old node from HAProxy config
# Then reload HAProxy
# systemctl reload haproxy

# 7d. Update DNS (if needed)
```

#### Step 8: Final Verification (Stability Acceptance Criteria)
```bash
# etcd healthy (3 members, all healthy)
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# All nodes Ready
oc get nodes

# All Cluster Operators normal (Available=True, Progressing=False, Degraded=False)
oc get co | grep -v "True.*False.*False"

# ODF healthy
oc get pods -n openshift-storage

# Monitoring system no alerts
oc get alerts --all-namespaces | grep -i "firing"

# Applications normal
oc get routes --all-namespaces | wc -l
```

**⚠️ Stability acceptance: All conditions must be met before proceeding to next node:**
- [ ] etcd cluster 3 members all healthy
- [ ] All Cluster Operators Available=True, Progressing=False, Degraded=False
- [ ] All nodes Ready
- [ ] Monitoring system no new alerts (especially etcd-related)
- [ ] Wait at least 24 hours to observe stability

### ⚠️ Phase 3 Risk Reminders
1. **Replace only one at a time** — Wait for etcd to be fully stable before next (recommend 24 hours)
2. **3 control planes = fault tolerant 1** — If another fails during replacement, cluster will have issues
3. **Schedule maintenance window** — etcd will have brief instability during force redeployment
4. **CSR approval** — Use auto-approval script (keep running throughout Phase 3)
5. **Time estimate** — Each node approximately 2-3 hours (excluding 24-hour stability observation)
6. **HAProxy update** — Must update in steps promptly, otherwise API requests will route to removed old VM
7. **DNS** — Update control plane node DNS records
8. **etcd Quorum Guard** — Allows drain at 4 CP nodes, blocks at 3 (protection mechanism)
9. **etcd Secrets** — Old node TLS secrets must be cleaned up to avoid Operator alerts

### Phase 3 Command Quick Reference
```bash
# Verify cluster health
oc get nodes && oc get co | grep -v "True.*False.*False"

# Backup
oc exec -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# Add (automatic) — etcd Operator handles automatically, no manual commands needed

# Remove (automatic) — Delete Machine object triggers
oc delete machine <old-machine-name> -n openshift-machine-api

# Clean etcd secrets
oc get secrets -n openshift-etcd | grep <old-name> | awk '{print $1}' | \
  xargs oc -n openshift-etcd delete secrets

# Force redeployment
oc patch etcd cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'$(date --rfc-3339=ns)'"}}' --type=merge

# Verify
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit
```

## Phase 4: Move Workloads to Master Nodes

> **Risk: LOW-MEDIUM | Time: 1-2 weeks | Method: update nodeSelector/affinity + rebalance**

### Overview

After Phase 3, you have 3 master BM + 6 worker BM. Master nodes have abundant resources (12 CPU, 64GB + NVMe each). This phase moves infra workloads from workers to masters to optimize resource utilization.

**Target workload distribution on each master node:**

```
master01: etcd + control plane + ODF/Ceph OSD (NVMe) + Monitoring stack + Loki/Tempo/Jaeger
master02: etcd + control plane + ODF/Ceph OSD (NVMe) + GitOps + Pipelines + Quay
master03: etcd + control plane + ODF/Ceph OSD (NVMe) + Service Mesh + ECK + ACM +
          Multicluster Engine + NeuVector/Aqua/RHACS + Cert Manager + Confluent +
          CloudNativePG + DevWorkspace + Web Terminal + Kasten K10 + OpenTelemetry + KEDA
```

### Phase 4 Prerequisites
- [ ] Phase 3 completed (3 master BM + 6 worker BM)
- [ ] Each master has dedicated NVMe disk for ODF/Ceph OSD
- [ ] etcd cluster healthy (3 members)
- [ ] All Cluster Operators normal

### Step-by-Step Procedure

#### Step 1: Verify master node resources
```bash
# Verify each master has sufficient resources
oc describe node master01-bm | grep -A 5 "Allocated resources"
oc describe node master02-bm | grep -A 5 "Allocated resources"
oc describe node master03-bm | grep -A 5 "Allocated resources"
```

#### Step 2: Move ODF to master nodes (NVMe)
```bash
# ODF should already be on masters if Phase 2a placed OSDs there
# Verify Ceph OSD pods running on master nodes
oc get pods -n openshift-storage -o wide | grep osd
```

#### Step 3: Move Monitoring to master01
```bash
# Update OpenShift Monitoring stack nodeSelector to master01
# Edit Cluster Monitoring Config:
oc edit configmap monitoring-config -n openshift-monitoring

# Update Prometheus nodeSelector
# Update Alertmanager nodeSelector
# Update Thanos nodeSelector

# Wait for pods to reschedule
oc get pods -n openshift-monitoring -w
```

#### Step 4: Move GitOps + Pipelines + Quay to master02
```bash
# Update ArgoCD nodeSelector to master02
# Update OpenShift Pipelines nodeSelector to master02
# Update Quay nodeSelector to master02

# Wait for pods to reschedule
oc get pods -n openshift-gitops -w
oc get pods -n openshift-pipelines -w
oc get pods -n quay-enterprise -w
```

#### Step 5: Move remaining operators to master03
```bash
# Update Service Mesh nodeSelector to master03
# Update Elasticsearch ECK nodeSelector to master03
# Update ACM nodeSelector to master03
# Update Multicluster Engine nodeSelector to master03
# Update NeuVector/Aqua/RHACS nodeSelector to master03
# Update Cert Manager nodeSelector to master03
# Update Confluent nodeSelector to master03
# Update CloudNativePG nodeSelector to master03
# Update DevWorkspace nodeSelector to master03
# Update Web Terminal nodeSelector to master03
# Update Kasten K10 nodeSelector to master03
# Update OpenTelemetry nodeSelector to master03
# Update KEDA nodeSelector to master03

# Wait for pods to reschedule
```

#### Step 6: Verify all workloads
```bash
# Verify all pods running on correct master nodes
oc get pods --all-namespaces -o wide | grep master

# Verify no pods left on old infra nodes (if they were removed)
# Verify all applications healthy
oc get pods --all-namespaces | grep -v Running | grep -v Completed
```

#### Step 7: Rebalance worker nodes
```bash
# After moving infra workloads to masters, workers should have more capacity
# Verify worker resource utilization
oc describe node worker01-bm | grep -A 5 "Allocated resources"

# Rebalance application pods if needed
oc get pods --all-namespaces -o wide | grep worker
```

### Phase 4 Acceptance Criteria
- [ ] All infra workloads running on master nodes
- [ ] Each master running its assigned components
- [ ] All Cluster Operators normal
- [ ] All applications healthy
- [ ] Worker nodes have sufficient capacity for apps
- [ ] etcd cluster healthy
- [ ] ODF/Ceph healthy with NVMe-backed OSDs
- [ ] Monitoring stack healthy on master01
- [ ] GitOps/Pipelines/Quay healthy on master02
- [ ] All other operators healthy on master03

### Phase 4 ⚠️ Important Notes
1. **NVMe for ODF** — Each master must have dedicated NVMe for Ceph OSD, separate from etcd
2. **Resource planning** — Verify each master has enough resources before moving workloads
3. **One operator at a time** — Move operators one at a time, verify stability before next
4. **Rebalancing** — Ceph rebalance may take time after OSD migration
5. **Monitoring** — Watch for resource pressure on master nodes after workload migration

---



# OCP VMware to Bare Metal Migration Plan

**Author:** Hermes Agent  
**Date:** 2026-08-10 (updated)  
**Cluster:** lab.devops.local (OCP 4.20.27)  
**Platform:** BareMetal (platform: none)  
**Status:** Phase 1 planned, Phase 2 planned  
**Red Hat Articles:** 
- https://access.redhat.com/solutions/5020331 (mixed virtual/bare metal support)
- https://access.redhat.com/solutions/7061543 (Hyper-V support)
- https://access.redhat.com/articles/4207611 (non-tested platforms)
- https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/machine_management/managing-user-provisioned-infrastructure-manually#adding-bare-metal-compute-vsphere-user-infra
- Red Hat KB: Guidance for OCP Clusters - Deployments Spanning Multiple Sites

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [2-Phase Migration Plan (User's Decision)](#2-phase-migration-plan-users-decision)
- [Critical Point: Control Plane Migration](#critical-point-control-plane-migration)
- [Current Cluster Inventory](#current-cluster-inventory)
- [Option Analysis](#option-analysis)
  - [Option 1: Full Bare Metal (Rebuild Everything)](#option-1-full-bare-metal-rebuild-everything)
  - [Option 2: Nutanix (Full Cluster)](#option-2-nutanix-full-cluster)
  - [Option 3: Microsoft Hyper-V (Full Cluster)](#option-3-microsoft-hyper-v-full-cluster)
  - [Option 4: VMware (Masters) + Bare Metal (Workers) - RECOMMENDED](#option-4-vmware-masters--bare-metal-workers---recommended)
- [Comprehensive Comparison Table](#comprehensive-comparison-table)
- [Platform Comparison](#platform-comparison)
- [Why Option 4 Wins (Phase 1) + Phase 2 Extension](#why-option-4-wins-phase-1--phase-2-extension)
- [Summary Table](#summary-table)
- [Migration Checklist](#migration-checklist)
  - [Phase 1: Workers VM → BM (Option 4)](#phase-1-workers-vm--bm-option-4)
  - [Phase 2: Masters VM → BM (Plan B)](#phase-2-masters-vm--bm-plan-b)
- [Future Considerations](#future-considerations)
- [Bare Metal Network Configuration (NIC Bonding)](#bare-metal-network-configuration-nic-bonding)
  - [Bonding 方法選擇](#bonding-方法選擇)
  - [方法 1: Kernel Argument（安裝時最簡單）](#方法-1-kernel-argument安裝時最簡單)
  - [方法 2: NMState YAML + Ignition（安裝時 Official 方式）](#方法-2-nmstate-yaml-- ignition安裝時-official-方式)
  - [方法 3: MachineConfig（安裝後 / 現有 Cluster）](#方法-3-machineconfig安裝後--現有-cluster)
  - [Bonding Mode 選擇](#bonding-mode-選擇)
  - [驗證 Bonding](#驗證-bonding)
  - [Rollback](#rollback)
- [Phase 2: Control Plane Migration (Plan B - 逐個替換)](#phase-2-control-plane-migration-plan-b---逐個替換)
- [OCP 4.21 Technology Preview 澄清](#ocp-421-technology-preview-澄清)
- [技術參考：多站點部署要求](#技術參考多站點部署要求)
- [References](#references)

---

## Executive Summary

This plan analyzes 4 options for reducing VMware license costs on an existing OCP cluster running on VMware vSphere. The cluster has 12 nodes, 135 projects, 66 routes, 108 network policies, 65 installed operators, and ODF storage.

**Recommendation:** Option 4 (VMware Masters + Bare Metal Workers) is the clear winner.

- **Effort:** 1-2 weeks vs 6-10 weeks for full rebuild
- **Risk:** LOW vs HIGH
- **VMware savings:** 25% (3 worker licenses saved)
- **ODF impact:** ZERO (Ceph stays untouched)
- **Control Plane impact:** ZERO (CP stays on VMware)
- **Supported:** YES (Red Hat SLA applies)

## 2-Phase Migration Plan (User's Decision)

```
Phase 1: VMware 控制平面 + BM workers  ←  現在計劃（fully supported）
Phase 2: BM 控制平面 + BM workers     ←  全裸機（方案 B 逐個替換）
```

### Phase 1: VM Masters + BM Workers (Option 4)
- **Effort:** 1-2 weeks
- **Risk:** LOW
- **VMware savings:** 25% (3 worker licenses)
- **Supported:** YES (platform: none, full Red Hat SLA)
- **Action:** Replace worker01-03 VMware VMs with bare metal

### Phase 2: BM Masters + BM Workers (Option 1, Plan B)
- **Effort:** 2-3 weeks (per node, 3 nodes)
- **Risk:** MEDIUM-HIGH (etcd migration involved)
- **VMware savings:** Additional 25% (3 master licenses)
- **Supported:** YES (platform: none, full Red Hat SLA)
- **Method:** Plan B - 逐個替換 control plane nodes
- **Advantage:** 冇需要重新安裝所有野（ODF、operators、routes 等全部保留）
- **Key:** etcd snapshot before each swap, one node at a time

### Phase 2 追加 VMware savings: 50% total
```
Phase 1: 12 → 9 VMware licenses (-25%)
Phase 2: 9 → 6 VMware licenses  (-25%)
Total:   50% VMware license savings
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
║  - Method: 逐個替換 control plane nodes                               ║
║                                                                        ║
║  Total VMware savings: 50% (12 → 6 licenses)                         ║
║                                                                        ║
║  Phase 1 理由：                                                        ║
║  - 最低風險開始                                                         ║
║  - 只需要 3 台 BM 機                                                  ║
║  - Worker 替換最簡單（冇 etcd）                                        ║
║                                                                        ║
║  Phase 2 理由：                                                        ║
║  - 省更多 VMware license                                                ║
║  - 方案 B 冇需要重新安裝全部嘢                                          ║
║  - ODF、operators、routes 全部保留                                     ║
║  - 只係逐個 etcd member 替換                                          ║
║                                                                        ║
╚════════════════════════════════════════════════════════════════════════╝
```

### Phase 1 優勢（同之前一樣）
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

### Phase 2 優勢（方案 B）
1. ZERO ODF rebuild（Ceph stays untouched）
2. ZERO monitoring rebuild
3. ZERO operator reconfiguration
4. ZERO GitOps changes
5. ZERO pipeline changes
6. ZERO ingress changes
7. ZERO egress changes
8. 只係 etcd member 替換
9. Cluster 一直保持運作
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

## Migration Checklist

### Phase 1: Workers VM → BM (Option 4)

#### Day 1-2: Prepare
- [ ] Provision 3 bare metal servers (match worker specs)
- [ ] worker01: 8 CPU, 32GB RAM
- [ ] worker02: 8 CPU, 32GB RAM
- [ ] worker03: 32 CPU, 128GB RAM
- [ ] Configure network (same VLAN as vSphere)
- [ ] 確認 NIC 名稱（`ip link` 查詢 eno1/eno2/em1/em2 等）
- [ ] 確認 Switch LACP support（有 → mode 4，冇 → mode 1）
- [ ] 準備 NMState YAML（bonding + br-ex 配置）
- [ ] Base64 編碼 NMState YAML
- [ ] 準備 MachineConfig manifest（每個 node 一份）
- [ ] Configure DNS for worker01-03
- [ ] Test BMC/IPMI access
- [ ] Download RHCOS ISO
- [ ] Extract Ignition config

#### Day 3-4: Add Bare Metal Workers
- [ ] Boot worker01 with RHCOS ISO + worker.ign
- [ ] 驗證 bonding 狀態（`cat /proc/net/bonding/bond0`）
- [ ] 驗證 OVS bridge（`ovs-vsctl show`）
- [ ] Verify node Ready
- [ ] Boot worker02 with RHCOS ISO + worker.ign
- [ ] 驗證 bonding 狀態
- [ ] 驗證 OVS bridge
- [ ] Verify node Ready
- [ ] Boot worker03 with RHCOS ISO + worker.ign
- [ ] 驗證 bonding 狀態
- [ ] 驗證 OVS bridge
- [ ] Verify node Ready

#### Day 5-7: Migrate Workloads
- [ ] worker01: cordon → drain → verify → shutdown VM
- [ ] worker02: cordon → drain → verify → shutdown VM
- [ ] worker03: cordon → drain → verify → shutdown VM

#### Day 8: Cleanup & Validate
- [ ] Remove VMware worker VMs from vCenter
- [ ] Decommission 3 VMware hosts
- [ ] Adjust VMware license
- [ ] 測試 bonding failover（拔一條網線測試）
- [ ] 確認所有 BM worker bonding 正常
- [ ] Verify ODF health
- [ ] Verify monitoring
- [ ] Verify all 66 routes
- [ ] Verify all egress paths
- [ ] Verify ArgoCD sync
- [ ] Monitor for issues

---

### Phase 2: Masters VM → BM (Plan B)

> **Updated 2026-09-14 (v3)**: 根據專家審查 + OCP 4.20 官方文檔修正。
> - 核心修正：刪除 Machine 對象觸發 etcd Operator 自動移除 member，唔再手動 `etcdctl member remove`
> - 新增：etcd Secrets 清理、HAProxy 後端更新、etcd Quorum Guard 說明、CSR 監控腳本、穩定性驗收標準

#### 前置條件
- [ ] 3 台 BM 機已準備好（12 CPU, 64GB each）
- [ ] RHCOS ISO 已準備好（匹配 OCP 版本 4.20.27）
- [ ] Network 連通（同 VLAN）
- [ ] DNS 正反向解析正常
- [ ] BMC/IPMI 可用
- [ ] HTTP server 準備好放 ignition config（master.ign）
- [ ] HAProxy 後端已配置好（可以添加新 BM node IP）
- [ ] 確認冇 ControlPlaneMachineSet：`oc get controlplanemachineset -n openshift-machine-api`
- [ ] 提取 master Ignition config：`oc extract -n openshift-machine-api secret/master-user-data-managed --keys=userData --to=- > master.ign`
- [ ] 開一個終端跑 CSR 監控：`watch -n 5 'oc get csr | grep Pending'`

#### 每個 Node（重複 3 次，一次只做一個）

##### Node 1: master01 → BM
- [ ] 前置確認：集群健康、etcd 健康（3 members）、冇 CPMS
- [ ] 備份 etcd（用官方 backup 腳本）
- [ ] 準備 BMC Secret + BareMetalHost + Machine object
- [ ] 等 BMH 狀態變 available
- [ ] 安裝 RHCOS 到 BM 機
- [ ] 批准 CSR（手動或自動腳本）
- [ ] 等 node Ready
- [ ] 等 etcd Operator 自動加入新 member（約 5-10 分鐘）
- [ ] 確認 etcd cluster 有 4 個 members 且全部 healthy
- [ ] 更新 HAProxy：添加新 BM node IP 到後端
- [ ] Cordon + drain 舊 VM
- [ ] 刪除舊 Machine 對象（觸發 etcd Operator 自動移除 member）
- [ ] 刪除舊 BMH 對象
- [ ] 清理舊節點嘅 etcd TLS secrets
- [ ] 強制 etcd 重新部署
- [ ] 更新 HAProxy：移除舊 VM IP
- [ ] 更新 DNS（如需要）
- [ ] 驗證：etcd 3 members healthy、所有 CO 正常、所有 node Ready
- [ ] 等待 24 小時觀察穩定性

##### Node 2: master02 → BM
（同上）

##### Node 3: master03 → BM
（同上）

#### Phase 2 完成後驗證
- [ ] 所有 6 個 node Ready（3 masters + 3 workers 全 BM）
- [ ] etcd cluster 健康（3 members）
- [ ] ODF 健康
- [ ] 所有 65 operators 正常
- [ ] 所有 66 routes 正常
- [ ] 所有 108 network policies 正常
- [ ] ArgoCD sync 正常
- [ ] Monitoring 正常
- [ ] 移除舊 VMware master VMs
- [ ] 調整 VMware license（12 → 6）

---

## Future Considerations

After workers are migrated, you could ALSO migrate infra04-06 (monitoring/quay/egress) to bare metal to save 3 more VMware licenses (total 50% savings). But do workers FIRST - lowest risk, highest impact.

---

## Bare Metal Network Configuration (NIC Bonding)

VMware 有 vSwitch 做 NIC teaming，裸機要自己搞 bonding。OCP bare metal 有三個時機配 bonding：

### Bonding 方法選擇

| 時機 | 方法 | 適用場景 | 唔使裝 Operator |
|------|------|----------|----------------|
| 安裝時 | Kernel argument `bond=` | 最簡單，initramfs 階段 | ✅ |
| 安裝時 | NMState YAML + Ignition | Official Recommended，完整控制 | ✅ |
| 安裝後 | MachineConfig + NMState | 已有 cluster 遷移 | ✅ |

**重要：唔需要裝 Kubernetes NMState Operator。**
NMState Operator 只能管理 secondary NIC，管唔到 br-ex bridge。
你嘅 bonding 需求用 MachineConfig 就夠。

### 方法 1: Kernel Argument（安裝時最簡單）

用 RHCOS ISO 啟動嗰陣，喺 kernel command line 加 `bond=` 參數：

```
# DHCP 模式
bond=bond0:em1,em2:mode=active-backup
ip=bond0:dhcp
nameserver=192.168.89.61

# Static IP 模式
bond=bond0:em1,em2:mode=active-backup
ip=192.168.89.50::192.168.89.1:255.255.255.0:worker01.baremetal.bond:bond0:none
```

- `bond0` = bonding device name
- `em1,em2` = 物理 NIC（用 `ip link` 查詢實際名稱）
- `mode=active-backup` = 單活備援（最安全，唔使 switch config）
- ⚠️ 只控制 initramfs 階段，後續 br-ex 要另外配

### 方法 2: NMState YAML + Ignition（安裝時 Official 方式）

建立 NMState YAML → base64 → 放入 ignition config：

```yaml
interfaces:
  # 物理 NIC 1
  - name: eno1
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  # 物理 NIC 2
  - name: eno2
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  # Bond 介面
  - name: bond0
    type: bond
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: true
      dhcp: true
    link-aggregation:
      mode: active-backup
      port:
        - eno1
        - eno2

  # OVS Bridge（OVN-Kubernetes 嘅 br-ex）
  - name: br-ex
    type: ovs-bridge
    state: up
    ipv4:
      enabled: false
    bridge:
      options:
        mcast-snooping-enable: true
      port:
        - name: bond0
        - name: br-ex

  # OVS Interface（br-ex 嘅 internal port）
  - name: br-ex
    type: ovs-interface
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: true
      dhcp: true
      auto-route-metric: 48
```

Base64 編碼後放入 ignition：

```bash
cat br-ex-public.yaml | base64 -w 0
```

### 方法 3: MachineConfig（安裝後 / 現有 Cluster）

用 MachineConfig 推送 NMState YAML 到 `/etc/nmstate/openshift/<node>.yml`：

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 10-br-ex-worker01
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,<base64_encoded_nmstate>
          mode: 0644
          overwrite: true
          path: /etc/nmstate/openshift/worker01.yml
```

Apply 同 reboot：

```bash
oc apply -f 10-br-ex-worker01.yaml
# Node 會自動 reboot 套用配置
```

### Bonding Mode 選擇

| Mode | Name | Switch Config | Redundancy | Load Balance |
|------|------|---------------|------------|--------------|
| 1 | active-backup | 唔需要 | ✅ | ❌ |
| 2 | balance-xor | 要 | ✅ | ✅ (XOR) |
| 4 | 802.3ad (LACP) | 要 LACP | ✅ | ✅ (最好) |
| 6 | balance-alb | 唔需要 | ✅ | ✅ (ALB) |

建議：
- Switch 冇 LACP → mode 1 (active-backup)
- Switch 有 LACP → mode 4 (802.3ad)

### 驗證 Bonding

```bash
# 檢查 bond 狀態
oc debug node/<node> -- chroot /host cat /proc/net/bonding/bond0

# 檢查 OVS bridge
oc debug node/<node> -- chroot /host ovs-vsctl show

# 檢查 nmstate
oc debug node/<node> -- chroot /host nmstatectl show bond0
```

### Rollback

如果 bonding 配置失敗：

```bash
# 方法 1: 刪除 NMState 配置
oc debug node/<node> -- chroot /host rm /etc/nmstate/openshift/<node>.yml
oc debug node/<node> -- chroot /host systemctl restart NetworkManager

# 方法 2: 刪除 MachineConfig（從其他 working node）
oc delete machineconfig 10-br-ex-worker01
# 觸發 reboot 套用
```

### ⚠️ Bonding 注意事項

1. ** NIC 名稱要正確** — 用 `ip link` 確認實際 NIC 名稱（eno1/eno2/em1/em2/ens160 等）
2. **MAC 地址** — bond 介面建議用 `copy-mac-from` 複製其中一個 NIC 嘅 MAC
3. **auto-route-metric: 48** — 確保 br-ex default route 優先級最高
4. **每台 BM 機都要配** — 唔好只配一台，3 台 worker 都要做
5. **測試 failover** — 裝機後拔一條網線測試 bonding failover

---

## Phase 2: Control Plane Migration (Plan B - 逐個替換)

> **Updated 2026-09-14 (v3)**: 根據專家審查 + OCP 4.20 官方文檔修正。
> - 核心修正：刪除 Machine 對象觸發 etcd Operator 自動移除 member，唔再手動 `etcdctl member remove`
> - 新增：etcd Secrets 清理、HAProxy 後端更新、etcd Quorum Guard 說明、CSR 監控腳本、穩定性驗收標準
> - 參考：OCP 4.20 "Replacing a healthy etcd member by scaling up and scaling down"

### 為什麼揀方案 B
- 冇需要重新安裝 ODF、operators、routes、ArgoCD 等全部嘢
- Cluster 一直保持運作
- 只係逐個 etcd member 替換
- 核心方法對應 Red Hat 官方文檔："Replacing a healthy etcd member by scaling up and scaling down"

### etcd Quorum Guard 說明
etcd Quorum Guard 係一個保護機制，會阻止 drain 操作如果 drain 會導致 etcd quorum 喺 4 個 CP 節點過渡期間，Quorum Guard 允許 drain 舊節點（因為仍有足夠 etcd members）。但如果你嘗試喺只有 3 個 CP 節點時強制 drain 其中一個，Quorum Guard 會阻止。呢個係保護機制，唔係錯誤。

### 前置條件
- 3 台 BM 機已準備好（同 master 規格：12 CPU, 64GB）
- RHCOS ISO 已準備好（匹配 OCP 版本 4.20.27）
- Network 連通（同 VLAN）
- DNS 正反向解析正常
- BMC/IPMI 可用
- HTTP server 準備好放 master Ignition config
- HAProxy 後端已配置好（可以添加新 BM node IP）
- 確認冇 ControlPlaneMachineSet（`platform: none` 集群通常冇）

### 提取 Master Ignition Config
```bash
# 注意：如果集群安裝後有 MachineConfig 更新，master-user-data-managed 會自動更新
# 確保喺添加新節點前提取最新版本
oc extract -n openshift-machine-api secret/master-user-data-managed \
  --keys=userData --to=- > master.ign
```

### CSR 監控腳本（整個 Phase 2 期間開一個終端監控）
```bash
watch -n 5 'oc get csr | grep Pending'
```

### 步驟（每次只替換一個，重複 3 次）

#### Step 1: 前置確認 + 備份 etcd（每次操作前必做！）
```bash
# 1a. 確認集群健康
oc get nodes
oc get co | grep -v "True.*False.*False"

# 1b. 確認 etcd 健康（3 個 members，全部 healthy）
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# 1c. 確認冇 ControlPlaneMachineSet
oc get controlplanemachineset -n openshift-machine-api

# 1d. 備份 etcd（用官方 backup 腳本）
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# 1e. 驗證 backup
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  ls -la /home/core/assets/backup/
```

#### Step 2: 準備 BareMetalHost + Machine object
```bash
# 建立 BMC Secret
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

# 建立 BareMetalHost
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

# 等 BMH 狀態變 available
oc get bmh -n openshift-machine-api master-bm-<N> -w
```

#### Step 3: 安裝 RHCOS 到 BM 機
```bash
# 方法 1: coreos-installer（從 ISO 啟動）
sudo coreos-installer install /dev/sda \
    --ignition-url=http://<http_server>/master.ign \
    --insecure-ignition \
    --platform=metal

# 方法 2: 用 ISO + Ignition 直接啟動
# 將 master.ign 放入 ISO 或用 PXE 啟動
```

#### Step 4: 建立 Machine object 並加入集群
```bash
# 建立 Machine object（copy providerSpec from 另一個 control plane Machine）
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
# 批准 CSR（新節點會產生 client + server 兩個 CSR）
# 方法 1: 手動批准
oc get csr | grep Pending
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs oc adm certificate approve

# 方法 2: 自動批准腳本（整個 Phase 2 期間開一個終端跑）
while true; do
  PENDING=$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  if [ -n "$PENDING" ]; then
    echo "$PENDING" | xargs oc adm certificate approve
    echo "$(date): Approved CSRs"
  fi
  sleep 10
done

# 等 node Ready
oc get nodes -w
# 等 <cluster-name>-master-bm-<N> 狀態變 Ready
```

#### Step 5: 等 etcd Operator 自動加入新 member + HAProxy 更新
```bash
# ⚠️ 重要：etcd Operator 會自動偵測新嘅 control plane node
# 並自動將新 node 加入 etcd cluster，唔需要手動 patch 或 etcdctl member add
# 大約等 5-10 分鐘

# ⚠️ 關鍵等待步驟：必須看到 4 個 members 且全部 "is healthy" 才能繼續
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table

# 預期輸出：4 個 members（3 舊 + 1 新）
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# |        ID        | STATUS  |  NAME   |        PEER ADDRS        |       CLIENT ADDRS        |  IS LEARNER |
# +------------------+---------+---------+---------------------------+---------------------------+------------+
# | <id1>            | started | master01| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id2>            | started | master02| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id3>            | started | master03| https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# | <id4>            | started | new-bm  | https://192.168.x.x:2380  | https://192.168.x.x:2379  |      false |
# +------------------+---------+---------+---------------------------+---------------------------+------------+

# 驗證所有 etcd members 健康
etcdctl endpoint health --cluster
# 預期：4 個 endpoints 全部 "is healthy"
exit

# 更新 HAProxy：將新 BM 節點 IP 加入後端
# 在 HAProxy 配置中添加新節點到：
#   backend openshift-api-server
#   backend machine-config-server
# 然後重載 HAProxy
# systemctl reload haproxy
```

#### Step 6: 移除舊 VM — Cordon + Drain + 刪除 Machine（觸發自動 etcd 移除）
```bash
# ⚠️ 重要：先 cordon/drain，再刪除 Machine 對象
# 刪除 Machine 會觸發 etcd Operator 自動移除對應嘅 etcd member
# 唔需要手動執行 etcdctl member remove

# 6a. Cordon 舊 VM 節點（停止新 Pod 調度）
oc adm cordon <old-vm-master-name>

# 6b. Drain 舊 VM 節點（驅逐 Pod）
# 注意：etcd Quorum Guard 在 4 個 CP 節點時允許此操作
oc adm drain <old-vm-master-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 6c. 刪除舊 VM 嘅 Machine 對象
# ⚠️ 呢一步會觸發 etcd Operator 自動移除對應嘅 etcd member
# 唔需要手動執行 etcdctl member remove
oc delete machine <old-vm-machine-name> -n openshift-machine-api

# 6d. 刪除舊 VM 嘅 BMH 對象
oc delete bmh <old-vm-bmh-name> -n openshift-machine-api

# 6e. 等待 Node 對象自動刪除（Machine 刪除後自動觸發）
oc get nodes -w
```

#### Step 7: 清理 etcd Secrets + 強制重新部署 + 驗證
```bash
# 7a. 清理舊節點嘅 etcd TLS secrets
# 移除舊節點後，清理其對應嘅 etcd secrets，避免 etcd Operator 出現告警
oc get secrets -n openshift-etcd | grep <old-vm-master-name>
# 應該看到：
# etcd-peer-<old-master-name>
# etcd-serving-<old-master-name>
# etcd-serving-metrics-<old-master-name>

oc get secrets -n openshift-etcd | grep <old-vm-master-name> | \
  awk '{print $1}' | xargs oc -n openshift-etcd delete secrets

# 7b. 強制 etcd Operator 重新部署所有 etcd pods（確保配置一致）
oc patch etcd cluster \
  -p='{"spec": {"forceRedeploymentReason": "master-replacement-'"$(date --rfc-3339=ns)"'"}}' \
  --type=merge

# 等 etcd pods 重新部署完成
oc get pods -n openshift-etcd -w
# 等所有 etcd pods 變 Running

# 7c. 更新 HAProxy：從後端移除舊 VM 節點 IP
# 在 HAProxy 配置中移除舊節點
# 然後重載 HAProxy
# systemctl reload haproxy

# 7d. 更新 DNS（如需要）
```

#### Step 8: 最終驗證（穩定性驗收標準）
```bash
# etcd 健康（3 個 members，全部 healthy）
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# 所有 node Ready
oc get nodes

# 所有 Cluster Operators 正常（Available=True, Progressing=False, Degraded=False）
oc get co | grep -v "True.*False.*False"

# ODF 健康
oc get pods -n openshift-storage

# 監控系統無告警
oc get alerts --all-namespaces | grep -i "firing"

# 應用程序正常
oc get routes --all-namespaces | wc -l
```

**⚠️ 穩定性驗收：以下所有條件都要滿足先做下一個 node：**
- [ ] etcd cluster 3 個 members 全部 healthy
- [ ] 所有 Cluster Operators Available=True, Progressing=False, Degraded=False
- [ ] 所有 nodes Ready
- [ ] 監控系統無新告警（特別係 etcd 相關）
- [ ] 至少等 24 小時觀察穩定性

### ⚠️ Phase 2 風險提醒
1. **一次只換一個** — 等 etcd 完全穩定先做下一個（建議等 24 小時）
2. **3 個 control plane = 容錯 1 個** — 換緊嗰陣如果另一個掛咗，cluster 會出問題
3. **安排 maintenance window** — 換嘅時候 etcd 會有短暫唔穩定（force redeployment 時）
4. **CSR 批准** — 用自動批准腳本（整個 Phase 2 期間開一個終端跑）
5. **時間估算** — 每個 node 大約 2-3 小時（唔包括 24 小時穩定觀察）
6. **HAProxy 更新** — 必須喺步驟中及時更新，否則 API 請求會路由到已移除嘅舊 VM
7. **DNS** — 要更新 control plane node 嘅 DNS 記錄
8. **etcd Quorum Guard** — 4 個 CP 節點時允許 drain，3 個時會阻止（保護機制）
9. **etcd Secrets** — 舊節點嘅 TLS secrets 要清理，避免 Operator 告警

### Phase 2 命令快速參考
```bash
# 確認集群健康
oc get nodes && oc get co | grep -v "True.*False.*False"

# 備份
oc exec -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# 加入（自動）— etcd Operator 自動處理，唔需要手動命令

# 移除（自動）— 刪除 Machine 對象觸發
oc delete machine <old-machine-name> -n openshift-machine-api

# 清理 etcd secrets
oc get secrets -n openshift-etcd | grep <old-name> | awk '{print $1}' | \
  xargs oc -n openshift-etcd delete secrets

# 強制重新部署
oc patch etcd cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'$(date --rfc-3339=ns)'"}}' --type=merge

# 驗證
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit
```

---

## OCP 4.21 Technology Preview 澄清

### 呢個 TP 功能係咩
OCP 4.21 新增咗一個功能：喺已安裝嘅 vSphere 集群（用 `platform: vsphere`）上面加入 bare-metal compute machines。

### 你嘅 cluster 唔受影響
你嘅 cluster 用 `platform: none`，所以：
- ❌ TP 功能唔關你事
- ❌ 唔需要關 vSphere CSI（你根本冇裝）
- ❌ 唔需要理手動 CSR 批准嘅特殊要求
- ✅ 你嘅混合部署方式一直都係 fully supported

### TP 功能嘅限制（僅供參考）
- 冇 Machine API 管理
- 冇 autoscaling
- 冇 SLA 保障
- 要關 vSphere CSI（你冇裝，唔影響）

---

## 技術參考：多站點部署要求

如果 Phase 2 控制平面轉 BM，要確保符合多站點網絡要求：

### etcd 要求
- etcd peer RTT < 100ms（唔係普通 network RTT）
- OCP 4.16+ 可放寬到 500ms（hardware speed tolerance）
- 必須用高速低延遲存儲（SSD/NVMe）

### 網絡要求
- L3 直接 IP 連通
- MTU 一致
- GSLB 做流量調度（如需要跨站）

### 存儲要求
- 跨站存儲要考慮所有站嘅可達性
- Registry 建議用 object storage
- 層疊存儲（如 ODF）延遲要求 < 10ms RTT

### 工作負載調度
- 用 topology-aware scheduling（OCP 4.6+）
- 避免 SPoF（Single Point of Failure）

---

## References

- Red Hat Article (mixed support): https://access.redhat.com/solutions/5020331
- Red Hat Article (Hyper-V support): https://access.redhat.com/solutions/7061543
- Red Hat Article (non-tested platforms): https://access.redhat.com/articles/4207611
- OCP 4.20 etcd docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/etcd/
- OCP 4.20 Backing up and restoring etcd data: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/etcd/backing-up-and-restoring-etcd-data
- OCP 4.20 Expanding the cluster (bare metal): https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installing_on_bare_metal/bare-metal-expanding-the-cluster
- OCP 4.20 Managing control plane machines: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/machine_management/managing-control-plane-machines
- OCP 4.21 Bare Metal Docs: https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/machine_management/managing-user-provisioned-infrastructure-manually#adding-bare-metal-compute-vsphere-user-infra
- Red Hat KB (multi-site guidance): Guidance for OCP Clusters - Deployments Spanning Multiple Sites
- OCP Bare Metal Network Customizations (bonding): https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/installing_on_bare_metal/installing-bare-metal-network-customizations
- Advanced br-ex Bonding (blog): https://blog.stderr.at/openshift-platform/networking/2026-02-05-advanced-br-ex-with-bonding
- Kubernetes NMState Operator: https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/networking/kubernetes-nmstate
- Platform-agnostic install: platform: none in install-config.yaml
- SPLAT-2561, OCPSTRAT-2650 (future GA tracking)
- OCP 4.20 Replacing a healthy etcd member (scaling up/down): https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/etcd/backing-up-and-restoring-etcd-data#replacing-a-healthy-etcd-member-by-scaling-up-and-scaling-down
- OKD Replacing an unhealthy etcd member: https://docs.okd.io/latest/backup_and_restore/control_plane_backup_and_restore/replacing-unhealthy-etcd-member.html

# OCP VMware to Bare Metal Migration Plan

**Author:** Hermes Agent  
**Date:** 2026-08-10 (updated 2026-09-15 v6)  
**Cluster:** lab.devops.local (OCP 4.20.27)  
**Platform:** BareMetal (platform: none)  
**Status:** Part 1 reviewed, Part 2 ready to execute (4-phase plan, corrected order)  
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
- [Phase 1: Workers VM to BM](#phase-1-workers-vm-to-bm)
  - [Phase 1 Prerequisites (including NIC Bonding)](#phase-1-prerequisites)
  - [Step 1: Add First BM Worker (worker01)](#step-1-add-first-bm-worker-worker01)
    - [Option A: Without BMC/IPMI (Manual)](#option-a-without-bmchipmi-manual-installation)
    - [Option B: With BMC/IPMI (Automated via BareMetalHost)](#option-b-with-bmchipmi-automated-installation-via-baremetalhost)
  - [Step 2: Migrate Workloads from VM to BM](#step-2-migrate-workloads-from-vm-to-bm)
  - [Step 3: Repeat for worker02 and worker03](#step-3-repeat-for-worker02-and-worker03)
  - [Step 4: Cleanup](#step-4-cleanup)
  - [Phase 1 Acceptance Criteria](#phase-1-acceptance-criteria)
- [Phase 2: Masters VM to BM (etcd Replacement)](#phase-2-masters-vm-to-bm-etcd-replacement)
  - [Phase 2 Prerequisites](#phase-2-prerequisites)
  - [Phase 2 Steps](#phase-2-steps-repeat-3-times-one-node-at-a-time)
  - [Phase 2 Acceptance Criteria](#phase-2-acceptance-criteria)
- [Phase 3: Infra to Master BM (Move Infra Components)](#phase-3-infra-to-master-bm-move-infra-components)
  - [Phase 3 Overview](#phase-3-overview)
  - [Phase 3 Component Distribution](#phase-3-component-distribution)
  - [Phase 3 Step-by-Step](#phase-3-step-by-step)
  - [Phase 3 Acceptance Criteria](#phase-3-acceptance-criteria)
- [Phase 4: Add 3 More Workers (Optional)](#phase-4-add-3-more-workers-optional)
- [Bare Metal Network Configuration (NIC Bonding)](#bare-metal-network-configuration-nic-bonding)
### Part 3: Rollback Procedures
- [Rollback: Phase 1 - Workers VM to BM](#rollback-phase-1---workers-vm-to-bm)
- [Rollback: Phase 2 - Masters VM to BM (etcd Replacement)](#rollback-phase-2---masters-vm-to-bm-etcd-replacement)
- [Rollback: Phase 3 - Infra to Master BM (Move Infra Components)](#rollback-phase-3---infra-to-master-bm-move-infra-components)
- [Rollback Summary](#rollback-summary)
- [References](#references)

### Part 4: ODF OSD Migration (600GB → 1TB NVMe, Same StorageClass)
- [Part 4 Scenario](#part-4-scenario)
- [Part 4 Prerequisites](#part-4-prerequisites)
- [Part 4 Phase 1: Prepare New Nodes (OCP + ODF Label)](#part-4-phase-1-prepare-new-nodes-ocp--odf-label)
- [Part 4 Phase 2: Update LocalVolumeSet (nodeSelector + minSize/maxSize)](#part-4-phase-2-update-localvolumeset-nodeselector--minsizemaxsize)
- [Part 4 Phase 3: Update LocalVolumeDiscovery (nodeSelector)](#part-4-phase-3-update-localvolumediscovery-nodeselector)
- [Part 4 Phase 4: Verify New 1TB PVs Discovered (Same SC)](#part-4-phase-4-verify-new-1tb-pvs-discovered-same-sc)
- [Part 4 Phase 5: Backup StorageCluster](#part-4-phase-5-backup-storagecluster)
- [Part 4 Phase 6: Scale Up StorageCluster (Add New 1TB OSDs)](#part-4-phase-6-scale-up-storagecluster-add-new-1tb-ossds)
- [Part 4 Phase 7: Wait for Rebalance — HEALTH_OK](#part-4-phase-7-wait-for-rebalance--health_ok)
- [Part 4 Phase 8: Scale Down Rook-Ceph-Operator](#part-4-phase-8-scale-down-rook-ceph-operator)
- [Part 4 Phase 9: Remove Old 600GB OSDs (One at a Time!)](#part-4-phase-9-remove-old-600gb-ossds-one-at-a-time)
- [Part 4 Phase 10: Adjust StorageCluster Count Back](#part-4-phase-10-adjust-storagecluster-count-back)
- [Part 4 Phase 11: Scale Up Rook-Ceph-Operator & Verify](#part-4-phase-11-scale-up-rook-ceph-operator--verify)
- [Part 4 Verification Checklist](#part-4-verification-checklist)
- [Part 4 Rollback Plan](#part-4-rollback-plan)
- [Part 4 Critical Warnings](#part-4-critical-warnings)

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

# Part 2: Solution Selection and Execution

---


## Phase 1: Workers VM to BM

> **Risk: LOW | Time: 1-2 weeks | Method: cordon/drain/replace**

### Overview

Replace worker01-03 VMware VMs with bare metal nodes. Each worker is replaced one at a time using cordon -> drain -> add BM -> remove VM workflow.

### Phase 1 Prerequisites

#### Hardware Requirements

- [ ] 3 bare metal servers provisioned (match worker specs)
- [ ] worker01: 8 CPU, 32GB RAM
- [ ] worker02: 8 CPU, 32GB RAM
- [ ] worker03: 32 CPU, 128GB RAM
- [ ] Each BM server: minimum 2x NIC (e.g. eno1, eno2)
- [ ] BMC/IPMI access tested

#### Network Requirements

- [ ] Network configured (same VLAN as vSphere)
- [ ] DNS configured for worker01-03 (forward + reverse)
- [ ] DHCP available on bare metal network (or static IPs planned)
- [ ] Switch LACP confirmed (you have LACP -> use bonding mode 4)
- [ ] API VIP + Ingress VIP reachable from bare metal network

#### NIC Bonding Configuration (Required Before Booting)

Each bare metal server needs NIC bonding before joining the cluster. VMware uses vSwitch with uplinks for the same purpose. On bare metal, we use Linux bonding + OVN-Kubernetes br-ex bridge.

**Bonding mode: 802.3ad (LACP) - mode 4** (your Switch supports LACP)

**Step B1: Identify NIC names on each BM server**

```bash
# Boot from RHCOS Live ISO first (do not install yet)
# Check available NICs:
ip link show
# Note the NIC names (e.g. eno1, eno2, em1, em2, ens160, ens192)
# Each server may have different NIC names - verify on each one
```

**Step B2: Create NMState YAML for bonding + br-ex**

Create a file `bond-br-ex.yaml` for each worker node. Example for worker01:

```yaml
interfaces:
  # Physical NIC 1
  - name: eno1
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  # Physical NIC 2
  - name: eno2
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  # Bond interface (LACP mode 4)
  - name: bond0
    type: bond
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: false
    link-aggregation:
      mode: 802.3ad
      port:
        - eno1
        - eno2

  # OVS Bridge (OVN-Kubernetes br-ex)
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

  # OVS Interface (br-ex internal port)
  - name: br-ex
    type: ovs-interface
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: true
      dhcp: true
      auto-route-metric: 48
```

**Step B3: Base64 encode the NMState YAML**

```bash
base64 -w 0 bond-br-ex.yaml
# Copy the output (this is your base64 encoded NMState)
```

**Step B4: Create MachineConfig for bonding**

Create a MachineConfig YAML for each worker node. Example for worker01:

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
            source: data:text/plain;charset=utf-8;base64,<BASE64_ENCODED_NMSTATE>
          mode: 0644
          overwrite: true
          path: /etc/nmstate/openshift/worker01.yml
```

Replace `<BASE64_ENCODED_NMSTATE>` with the output from Step B3.

Repeat for worker02 and worker03 (change node name in path and MachineConfig name).

**Step B5: Apply MachineConfig BEFORE booting the BM node**

```bash
# Apply the MachineConfig to the cluster
oc apply -f 10-br-ex-worker01.yaml
oc apply -f 10-br-ex-worker02.yaml
oc apply -f 10-br-ex-worker03.yaml

# The MachineConfig will be picked up when the new BM node joins the cluster
```

**Step B6: Verify bonding after node joins**

```bash
# After the BM node boots and joins the cluster:
oc debug node/<worker01-bm> -- chroot /host cat /proc/net/bonding/bond0
# Expected: Bonding Mode: IEEE 802.3ad (LACP), both NICs as slaves

oc debug node/<worker01-bm> -- chroot /host ovs-vsctl show
# Expected: br-ex bridge with bond0 as port
```

**Step B7: Test bonding failover**

```bash
# Unplug one network cable from the BM node
# Verify bond0 stays active with remaining NIC
oc debug node/<worker01-bm> -- chroot /host cat /proc/net/bonding/bond0
# "Active Slave" should change to the remaining NIC

# Replug the cable
# Verify both NICs are back
```

**Bonding Mode Reference:**

| Mode | Name | Switch Config Required | Redundancy | Load Balance |
|------|------|----------------------|------------|--------------|
| 1 | active-backup | No | Yes | No |
| 2 | balance-xor | Yes | Yes | Yes (XOR) |
| 4 | 802.3ad (LACP) | Yes (LACP) | Yes | Yes (best) |
| 6 | balance-alb | No | Yes | Yes (ALB) |

**Your choice: mode 4 (802.3ad)** because your Switch supports LACP.

#### Network Requirements

- [ ] Network configured (same VLAN as vSphere)
- [ ] NIC names confirmed on each BM server (`ip link show`)
- [ ] Switch LACP configured for the ports connected to BM servers
- [ ] DNS configured for worker01-03
- [ ] BMC/IPMI access tested
- [ ] RHCOS ISO downloaded
- [ ] Ignition config extracted: `oc extract -n openshift-machine-api secret/worker-user-data-managed --keys=userData --to=- > worker.ign`

#### Software Requirements

- [ ] NMState YAML prepared for each worker (bonding + br-ex, see Step B2)
- [ ] Base64 encoded NMState YAML for each worker (see Step B3)
- [ ] MachineConfig manifests prepared for each worker (see Step B4)
- [ ] MachineConfig applied to cluster before BM node boot (see Step B5)

### Step 1: Add First BM Worker (worker01)

#### Option A: Without BMC/IPMI (Manual Installation)

Use this option if your bare metal servers do not have BMC/IPMI (no remote management).

**Step 1a: Prepare RHCOS USB**

```bash
# On your workstation, create bootable USB
# Download RHCOS ISO matching your OCP version
wget https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.20/<version>/rhcos-<version>-live.x86_64.iso

# Write ISO to USB (Linux)
sudo dd if=rhcos-<version>-live.x86_64.iso of=/dev/sd bs=4M status=progress

# Or use Rufus on Windows
```

**Step 1b: Boot BM node from USB**

```bash
# Insert USB into BM server
# Boot from USB (may need to press F12/F2/Del to select boot device)
# Select USB device as boot source
```

**Step 1c: Install RHCOS to disk**

```bash
# At the RHCOS Live boot prompt, run:
sudo coreos-installer install /dev/sda \
    --ignition-url=http://<http_server>/worker.ign \
    --insecure-ignition \
    --platform=metal

# Replace <http_server> with your HTTP server hosting worker.ign
# /dev/sda is the target disk (check with lsblk)
```

**Step 1d: Reboot**

```bash
# Remove USB
# Reboot the server
sudo reboot
```

**Step 1e: Verify node joins cluster**

```bash
# On a machine with oc access:
oc get nodes -w
# Wait for worker01-bm to show Ready status
```

---

#### Option B: With BMC/IPMI (Automated Installation via BareMetalHost)

Use this option if your bare metal servers have BMC/IPMI (Dell iDRAC, HP iLO, Cisco UCS IMC, etc.).

**Step 1a: Verify BMC connectivity**

```bash
# Test Redfish API (Dell iDRAC example)
curl -k -u <bmc_user>:<bmc_pass> \
  https://<bmc_ip>/redfish/v1/Systems/System.Embedded.1

# For Cisco UCS
curl -k -u <bmc_user>:<bmc_pass> \
  https://<bmc_ip>/redfish/v1/Systems/1

# Expected: JSON response with system info
```

**Step 1b: Create BMC Secret**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: worker01-bmc-secret
  namespace: openshift-machine-api
type: Opaque
data:
  username: <base64_encoded_bmc_user>
  password: <base64_encoded_bmc_pass>
```

```bash
# Create the secret
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: worker01-bmc-secret
  namespace: openshift-machine-api
type: Opaque
data:
  username: $(echo -n '<bmc_user>' | base64)
  password: $(echo -n '<bmc_pass>' | base64)
EOF
```

**Step 1c: Create BareMetalHost**

```yaml
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: worker01-bm
  namespace: openshift-machine-api
spec:
  automatedCleaningMode: disabled
  bmc:
    address: redfish://<bmc_ip>/redfish/v1/Systems/System.Embedded.1
    credentialsName: worker01-bmc-secret
    disableCertificateVerification: true
  bootMACAddress: "<NIC1_MAC_ADDRESS>"
  bootMode: UEFI
  externallyProvisioned: false
  online: true
```

```bash
# Create the BareMetalHost
cat <<EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: worker01-bm
  namespace: openshift-machine-api
spec:
  automatedCleaningMode: disabled
  bmc:
    address: redfish://<bmc_ip>/redfish/v1/Systems/System.Embedded.1
    credentialsName: worker01-bmc-secret
    disableCertificateVerification: true
  bootMACAddress: "<NIC1_MAC_ADDRESS>"
  bootMode: UEFI
  externallyProvisioned: false
  online: true
EOF

# Wait for BMH to register and become available
oc get bmh -n openshift-machine-api -w
# Wait for STATE to become "available" or "provisioning"
```

**Step 1d: Create Machine object**

```bash
# Copy providerSpec from an existing worker Machine
oc get machine -n openshift-machine-api <existing-worker-machine> -o yaml > worker01-machine.yaml

# Edit the YAML:
# - Change name to worker01-bm
# - Update metal3.io/BareMetalHost annotation
# - Update labels (cluster-api-cluster, etc.)
# - Update userData name if needed

cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: Machine
metadata:
  annotations:
    metal3.io/BareMetalHost: openshift-machine-api/worker01-bm
  labels:
    machine.openshift.io/cluster-api-cluster: <cluster-name>
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: <cluster-name>-worker01-bm
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
        name: worker-user-data-managed
EOF
```

**Step 1e: Wait for node to join cluster**

```bash
# Bare Metal Operator will automatically:
# 1. Power on the server via BMC
# 2. Mount RHCOS ISO via virtual media
# 3. Install RHCOS
# 4. Server reboots and joins cluster

# Monitor progress
oc get bmh -n openshift-machine-api -w
# Wait for STATE to become "provisioned"

# Approve CSRs
oc get csr | grep Pending
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs oc adm certificate approve

# Wait for node Ready
oc get nodes -w
# Wait for worker01-bm to show Ready status
```

**Step 1f: Verify bonding status**

```bash
# Verify NMState bonding configuration applied
oc debug node/worker01-bm -- chroot /host cat /proc/net/bonding/bond0
# Expected: Bonding Mode: IEEE 802.3ad (LACP)

# Verify OVS bridge
oc debug node/worker01-bm -- chroot /host ovs-vsctl show
# Expected: br-ex bridge with bond0 as port
```

**Step 1g: Verify bonding failover (optional but recommended)**

```bash
# Unplug one network cable from the BM node
# Verify bond0 stays active with remaining NIC
oc debug node/worker01-bm -- chroot /host cat /proc/net/bonding/bond0
# "Active Slave" should change to the remaining NIC

# Replug the cable
# Verify both NICs are back as slaves
```

---

#### Summary: Which Option to Choose

| Scenario | Option | Steps |
|----------|--------|-------|
| No BMC/IPMI on BM servers | Option A | Manual USB install (15-20 min per node) |
| BMC/IPMI available (iDRAC/iLO/UCS) | Option B | BareMetalHost automated install |
| Cisco UCS with Redfish | Option B | Use redfish:// protocol |
| Many BM servers (>10) | Option B | Automation saves significant time |

### Step 2: Migrate Workloads from VM to BM

#### Step 2a: Cordon old VM worker

```bash
oc cordon worker01
# Expected: node/worker01 cordoned
```

#### Step 2b: Drain old VM worker

```bash
oc drain worker01 --ignore-daemonsets --delete-emptydir-data
# This will evict all pods from the old VM worker
# Pods will be rescheduled to the new BM node and other workers
```

#### Step 2c: Verify workloads migrated

```bash
# Verify pods are now running on the new BM node
oc get pods -o wide --all-namespaces | grep worker01-bm

# Verify all applications are healthy
oc get pods --all-namespaces | grep -v Running | grep -v Completed
# Expected: no output (all pods Running or Completed)

# Verify no pods left on old VM worker
oc get pods -o wide --all-namespaces | grep worker01
# Expected: no output
```

#### Step 2d: Shutdown old VM

```bash
# From vCenter or via SSH to the VM:
ssh root@worker01
shutdown -h now

# Or from vCenter: Power Off the VM
```

### Step 3: Repeat for worker02 and worker03

Repeat Steps 1-2 for worker02 and worker03.

**Important:** Wait for worker01 to be fully verified before starting worker02.

```
worker01: Boot -> Verify bonding -> Verify OVS -> Approve CSR -> Verify Ready -> Cordon VM -> Drain VM -> Verify -> Shutdown VM
worker02: Boot -> Verify bonding -> Verify OVS -> Approve CSR -> Verify Ready -> Cordon VM -> Drain VM -> Verify -> Shutdown VM
worker03: Boot -> Verify bonding -> Verify OVS -> Approve CSR -> Verify Ready -> Cordon VM -> Drain VM -> Verify -> Shutdown VM
```

### Step 4: Cleanup

#### Step 4a: Remove old VMs from vCenter

```bash
# Delete worker01, worker02, worker03 VMs from vCenter
# Right-click VM -> Delete from Disk
```

#### Step 4b: Decommission VMware hosts (if no longer needed)

#### Step 4c: Verify all services

```bash
# Verify ODF health
oc get pods -n openshift-storage | grep -v Running
# Expected: no output

# Verify monitoring
oc get pods -n openshift-monitoring | grep -v Running
# Expected: no output

# Verify all routes
oc get routes --all-namespaces | wc -l
# Expected: 66

# Verify ArgoCD sync
oc get applications -n openshift-gitops
# Expected: all apps Synced/Healthy

# Verify egress paths
# Test from application pods to external endpoints
oc debug <app-pod> -- curl -s http://external-endpoint

# Verify TopoLVM
oc get pods -n openshift-storage | grep topolvm
# Expected: topolvm pods Running

# Verify network policies
oc get networkpolicy --all-namespaces | wc -l
# Expected: 108
```

### Phase 1 Acceptance Criteria

- [ ] 3 BM workers Ready
- [ ] All apps running normally
- [ ] TopoLVM working on new BM nodes
- [ ] All 66 routes normal
- [ ] All 108 network policies normal
- [ ] ArgoCD sync normal
- [ ] ODF health normal
- [ ] Monitoring normal
- [ ] Bonding working on all 3 BM workers
- [ ] No pods left on old VM workers
---


## Phase 2: Masters VM to BM (etcd Replacement)

> **Risk: MEDIUM-HIGH | Time: 2-3 weeks | Method: delete Machine triggers etcd auto-remove**
> **Reference:** OCP 4.20 "Replacing a healthy etcd member by scaling up and scaling down"

### Why Choose Plan B (One-by-one Replacement)
- No need to reinstall ODF, operators, routes, ArgoCD, etc.
- Cluster remains operational throughout
- Only etcd member replacement one at a time
- Core method corresponds to Red Hat official documentation: "Replacing a healthy etcd member by scaling up and scaling down"

### etcd Quorum Guard Explanation
etcd Quorum Guard is a protection mechanism that blocks drain operations if drain would cause etcd quorum loss. During the 4 CP node transition period, Quorum Guard allows draining the old node (because there are still enough etcd members). However, if you attempt to force drain one of only 3 CP nodes, Quorum Guard will block it. This is a protection mechanism, not an error.

### Phase 2 Prerequisites

- [ ] 3 BM machines ready (12 CPU, 64GB each)
- [ ] RHCOS ISO ready (matching OCP version 4.20.27)
- [ ] Network connectivity (same VLAN)
- [ ] DNS forward/reverse resolution working
- [ ] BMC/IPMI available (or manual install plan)
- [ ] HTTP server ready for ignition config (master.ign)
- [ ] HAProxy backend configured (can add new BM node IP)
- [ ] Verify no ControlPlaneMachineSet: `oc get controlplanemachineset -n openshift-machine-api`
- [ ] Extract master Ignition config: `oc extract -n openshift-machine-api secret/master-user-data-managed --keys=userData --to=- > master.ign`
- [ ] Keep a CSR monitoring terminal running: `watch -n 5 'oc get csr | grep Pending'`

### Phase 2 Steps (repeat 3 times, one node at a time)

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

##### Option A: Without BMC/IPMI (Manual Installation)

Use this option if your bare metal servers do not have BMC/IPMI.

```bash
# 1. Prepare RHCOS USB on your workstation
wget https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.20/<version>/rhcos-<version>-live.x86_64.iso
sudo dd if=rhcos-<version>-live.x86_64.iso of=/dev/sd bs=4M status=progress

# 2. Insert USB into BM server, boot from USB

# 3. At RHCOS Live boot prompt, install to disk:
sudo coreos-installer install /dev/sda \\
    --ignition-url=http://<http_server>/master.ign \\
    --insecure-ignition \\
    --platform=metal

# 4. Remove USB and reboot
sudo reboot
```

##### Option B: With BMC/IPMI (Automated via BareMetalHost)

Use this option if your bare metal servers have BMC/IPMI (Dell iDRAC, HP iLO, Cisco UCS IMC, etc.).

**Verify BMC connectivity:**

```bash
# Dell iDRAC
curl -k -u <bmc_user>:<bmc_pass> \\
  https://<bmc_ip>/redfish/v1/Systems/System.Embedded.1

# Cisco UCS
curl -k -u <bmc_user>:<bmc_pass> \\
  https://<bmc_ip>/redfish/v1/Systems/1

# HP iLO
curl -k -u <bmc_user>:<bmc_pass> \\
  https://<bmc_ip>/redfish/v1/Systems/1
```

If BMC is reachable, Bare Metal Operator will automatically handle RHCOS installation via Redfish Virtual Media. **Skip manual coreos-installer** -- the BMH object created in Step 2 will power on the server, mount RHCOS ISO via virtual media, and install automatically.

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
# Approve CSRs
oc get csr | grep Pending
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
  xargs oc adm certificate approve

# Wait for node Ready
oc get nodes -w
```

#### Step 5: Wait for etcd Operator to auto-add new member + HAProxy update

```bash
# Wait approximately 5-10 minutes for etcd Operator to detect new control plane node

# Verify 4 etcd members, all healthy
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# Update HAProxy: add new BM node IP to backend
# Reload HAProxy
```

#### Step 6: Remove Old VM -- Cordon + Drain + Delete Machine

```bash
# Cordon old VM node
oc adm cordon <old-vm-master-name>

# Drain old VM node
oc adm drain <old-vm-master-name> --ignore-daemonsets --delete-emptydir-data --force

# Delete Machine object (triggers etcd Operator automatic member removal)
oc delete machine <old-vm-machine-name> -n openshift-machine-api

# Delete BMH object
oc delete bmh <old-vm-bmh-name> -n openshift-machine-api
```

#### Step 7: Clean etcd Secrets + Force Redeployment + Verify

```bash
# Clean old node etcd TLS secrets
oc get secrets -n openshift-etcd | grep <old-vm-master-name> | \
  awk '{print $1}' | xargs oc -n openshift-etcd delete secrets

# Force etcd Operator redeployment
oc patch etcd cluster \
  -p='{"spec": {"forceRedeploymentReason": "master-replacement-'$(date --rfc-3339=ns)'"}}' \
  --type=merge

# Wait for etcd pods to finish redeployment
oc get pods -n openshift-etcd -w

# Update HAProxy: remove old VM IP
# Update DNS (if needed)
```

#### Step 8: Final Verification (Stability Acceptance Criteria)

```bash
# etcd healthy (3 members)
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# All nodes Ready
oc get nodes

# All Cluster Operators normal
oc get co | grep -v "True.*False.*False"

# ODF healthy
oc get pods -n openshift-storage

# Monitoring normal
oc get alerts --all-namespaces | grep -i "firing"
```

**Stability acceptance: All conditions must be met before next node:**
- [ ] etcd cluster 3 members all healthy
- [ ] All Cluster Operators Available=True, Progressing=False, Degraded=False
- [ ] All nodes Ready
- [ ] Monitoring system no new alerts
- [ ] Wait at least 24 hours

### Phase 2 Acceptance Criteria

- [ ] 3 BM master nodes Ready
- [ ] etcd cluster 3 members HEALTH_OK
- [ ] All Cluster Operators normal
- [ ] All 66 routes normal
- [ ] ArgoCD sync normal

---

## Phase 3: Infra to Master BM (Move Infra Components)

> **Risk: LOW-MEDIUM | Time: 1-2 weeks | Method: update nodeSelector/tolerations + ODF rolling replace + cordon/drain VM**
> **Reference:** Red Hat Solution - Moving Infra Components to Master/Control Plane Nodes in RHOCP 4
> **Reference:** ODF 4.20 Replacing nodes - Section 2.1.1

### Overview

After Phase 2, you have 3 BM masters + 3 BM workers + 6 VMware infra VMs (infra01-06). This phase moves all infra components from the 6 VMware infra VMs to the 3 BM master nodes, then decommissions the infra VMs.

**No new BM machines needed.** All infra components run on the existing 3 BM master nodes alongside etcd and control plane.

### Important Caveats (from Red Hat)

1. **I/O hungry components should be avoided on master nodes** -- etcd is very sensitive to disk latency. Use NVMe for ODF/Ceph OSD, separate from etcd storage.
2. **Increased reboot time** -- Ingress controller pods can cause slow node reboots due to high `terminationGracePeriodSeconds`.
3. **Set resource limits** -- Set resource limits on infra workloads to prevent them from starving etcd/control plane.
4. **Node selector + toleration required** -- OpenShift is NOT configured by default to allow workloads on master nodes. You must apply both nodeSelector and toleration.

### Phase 3 Execution Order

**Critical: Follow this exact order:**

```
Step A: Move non-ODF components (Router, Registry, Monitoring) to master nodes
Step B: Move ODF from infra01-03 to master01-03 (Ceph OSD rolling replace, one at a time)
Step C: Move remaining components (GitOps, Pipelines, Quay, etc.) to master nodes
Step D: Cordon + Drain + Delete infra01-06 VMs
```

**Why this order:**
1. Move Router/Registry/Monitoring first -- these don't depend on ODF
2. Move ODF next -- this is the most complex step (Ceph OSD rolling replace)
3. Move remaining components last
4. Delete infra VMs only after ALL components are on master nodes

### Phase 3 Prerequisites

- [ ] Phase 2 completed (3 BM masters + 3 BM workers)
- [ ] Each master has dedicated NVMe disk for ODF/Ceph OSD (separate from etcd)
- [ ] etcd cluster healthy (3 members)
- [ ] All Cluster Operators normal
- [ ] 6 VMware infra VMs still running (infra01-06)
- [ ] Ceph cluster healthy (`ceph health` = HEALTH_OK)
- [ ] master01/02/03 not yet added to ODF (will be done in Step B)

### Phase 3 Component Distribution

| BM Master | Components |
|-----------|------------|
| master01 | etcd, control plane, ODF/Ceph OSD (NVMe), Monitoring (Prometheus, Alertmanager, Thanos), Loki, Tempo, Jaeger, ECK |
| master02 | etcd, control plane, ODF/Ceph OSD (NVMe), GitOps (ArgoCD), Pipelines (Tekton), Quay, Cert Manager, OpenTelemetry, KEDA |
| master03 | etcd, control plane, ODF/Ceph OSD (NVMe), Service Mesh, ACM, Multicluster Engine, NeuVector/Aqua/RHACS, Confluent, CloudNativePG, DevWorkspace, Web Terminal, Kasten K10 |

---

### Step A: Move Non-ODF Components to Master Nodes

#### Step A1: Move Router (IngressController) to Masters

```bash
# Patch IngressController to run on master nodes
oc patch ingresscontrollers.operator.openshift.io default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"nodePlacement": {"nodeSelector": {"matchLabels": {"node-role.kubernetes.io/master": ""}},"tolerations": [{"key": "node-role.kubernetes.io/master","operator": "Exists","effect":"NoSchedule"}]}}}'

# Scale to 3 replicas (one per master)
oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge -p '{"spec":{"replicas": 3}}'

# Verify
oc get pods -n openshift-ingress -o wide
# Expected: 3 router pods running on master nodes
```

#### Step A2: Move Registry to Masters

```bash
# Patch Image Registry to run on master nodes
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"nodeSelector": {"node-role.kubernetes.io/master": ""},"tolerations": [{"key": "node-role.kubernetes.io/master","operator": "Exists","effect": "NoSchedule"}]}}'

# Verify
oc get pods -n openshift-image-registry -o wide
```

#### Step A3: Move Monitoring Stack to Masters

```bash
# Create monitoring config with nodeSelector and tolerations
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
EOF

# Wait for pods to reschedule
oc get pods -n openshift-monitoring -w
# Verify all monitoring pods running on master nodes
oc get pods -n openshift-monitoring -o wide | grep master
```

**Note:** Grafana was removed in OCP 4.11. Do NOT include `grafana:` in the ConfigMap.

---

### Step B: Move ODF to Master Nodes (Ceph OSD Rolling Replace)

> **Reference:** ODF 4.20 Replacing nodes - Section 2.1.1
> **Reference:** ODF 4.20 Scaling Storage - Reorganization of ODF OSDs

**Key concept: Add-then-remove.** ODF/Ceph OSD should already be on master BM nodes (from Phase 2). This step removes ODF from the old VMware infra VMs, NOT adding new OSDs.

**If new BM NVMe disk is larger than old VM disk:** ODF does not support heterogeneous disk sizes. ODF will only use the same size as the old disk. After node replacement is complete, use "Add Capacity" in Storage > Data Foundation to utilize the remaining space.

```
For each infra VM (infra01-03):
  Phase A: Add master node to ODF (label + LocalVolumeDiscovery/Set)
  Phase B: Scale down ODF pods on old infra VM
  Phase C: Remove old OSD from Ceph
  Phase D: Update StorageCluster CR
  Phase E: Wait for Ceph HEALTH_OK + 24h observation
  Repeat for next infra VM
```

#### Step B1: Move ODF from infra01 to master01

**B1a. Add master01 to ODF**

```bash
# 1. Label master01 for ODF
oc label node master01-bm cluster.ocs.openshift.io/openshift-storage=""

# 2. Update LocalVolumeDiscovery (add master01)
local_storage_project=$(oc get csv --all-namespaces | awk '{print $1}' | grep local)
oc edit -n $local_storage_project localvolumediscovery auto-discover-devices
# Add master01-bm to nodeSelector values:
#   - infra01.example.com  # keep (will remove later)
#   - infra02.example.com  # keep
#   - infra03.example.com  # keep
#   - master01-bm          # add

# 3. Update LocalVolumeSet (add master01)
oc edit -n $local_storage_project localvolumeset localblock
# Same: add master01-bm to nodeSelector values

# 4. Wait for new localblock PV to appear
oc get pv | grep localblock | grep Available
# Expected: new Available PV present

# 5. Wait for new OSD pod to run on master01
oc get pods -o wide -n openshift-storage | grep master01 | grep osd
# Expected: OSD pods running on master01

# 6. Wait for Ceph HEALTH_OK (new OSD must be healthy before removing old)
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph health
# Wait for HEALTH_OK
exit
```

**Note:** If master01 already has ODF from Phase 2, skip steps 1-5 and only verify OSD is running.

**B1b. Scale down ODF pods on infra01**

```bash
# Scale down OSD on infra01
oc scale deployment rook-ceph-osd-0 --replicas=0 -n openshift-storage

# Scale down mon (if mon runs on this node)
oc scale deployment rook-ceph-mon-c --replicas=0 -n openshift-storage

# Scale down crashcollector
oc scale deployment --selector=app=rook-ceph-crashcollector,node_name=infra01 --replicas=0 -n openshift-storage
```

**B1c. Remove old OSD from Ceph**

```bash
# Get old OSD ID
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph osd tree
# Note OSD IDs on infra01
exit

# Delete any existing ocs-osd-removal-job
oc delete -n openshift-storage job ocs-osd-removal-job 2>/dev/null || true

# Run OSD removal job (one OSD at a time)
osd_id_to_remove=<old_osd_id>
oc scale -n openshift-storage deployment rook-ceph-osd-${osd_id_to_remove} --replicas=0
oc process -n openshift-storage ocs-osd-removal \
  -p FAILED_OSD_IDS=${osd_id_to_remove} FORCE_OSD_REMOVAL=true | oc create -n openshift-storage -f -

# Monitor removal job
oc logs -l job-name=ocs-osd-removal-job -n openshift-storage --tail=-1
oc logs -l job-name=ocs-osd-removal-job -n openshift-storage \
  --tail=-1 | egrep -i 'completed removal'

# Wait for Ceph HEALTH_OK after each OSD removal
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) ceph status
# CRITICAL: Do not proceed until HEALTH_OK
```

**B1d. Update LocalVolumeDiscovery + LocalVolumeSet (remove infra01, keep master01)**

```bash
# Update LocalVolumeDiscovery (remove infra01)
oc edit -n $local_storage_project localvolumediscovery auto-discover-devices
# nodeSelector values:
#   - infra02.example.com  # keep
#   - infra03.example.com  # keep
#   - master01-bm          # keep (added in B1a)
#   #- infra01.example.com # remove

# Update LocalVolumeSet (same)
oc edit -n $local_storage_project localvolumeset localblock
# Same changes
```

**B1e. Clean up released PVs and crashcollector**

```bash
# Delete released PVs
oc get pv -L kubernetes.io/hostname | grep localblock | grep Released
oc delete pv <released-pv>

# Delete crashcollector deployment
oc delete deployment --selector=app=rook-ceph-crashcollector,node_name=infra01 -n openshift-storage
```

**B1f. Backup and Update StorageCluster CR**

```bash
# Backup current StorageCluster
oc get storagecluster -n openshift-storage -o yaml > storagecluster-backup-$(date +%s).yaml

# Edit StorageCluster to remove old storageDeviceSet entries for infra01
oc edit storagecluster ocs-storagecluster -n openshift-storage
# Remove storageDeviceSet entries associated with infra01's old disk
```

**B1g. Cordon + Drain + Delete infra01**

```bash
oc adm cordon infra01
oc adm drain infra01 --force --delete-emptydir-data --ignore-daemonsets
oc delete node infra01
```

**B1h. Final verification for this node**

```bash
# Verify Ceph health
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) ceph status

# Verify OSD topology
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) ceph osd tree

# Verify all ODF pods normal
oc get pods -n openshift-storage | grep -v Running

# Verify PVC normal
oc get pvc --all-namespaces | grep -v Bound
```

**B1i. Wait for Stability**

```
Wait at least 24 hours:
- Ceph HEALTH_OK
- All PVCs Bound
- All ODF pods Running
- Applications healthy
```

#### Step B2: Repeat for infra02 -> master02

Repeat Step B1 for infra02 -> master02.

#### Step B3: Repeat for infra03 -> master03

Repeat Step B1 for infra03 -> master03.

#### Step B4: Final ODF Verification (after all 3 nodes replaced)

```bash
# Verify all OSDs on master nodes
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) ceph osd tree
# Expected: 3 OSDs, all on master01/02/03

# Verify Ceph status
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) ceph status
# Expected: HEALTH_OK

# Verify StorageCluster CR is clean
oc get storagecluster -n openshift-storage -o yaml | grep -A 5 storageDeviceSets

# If new BM NVMe is larger than old VM disk, use Add Capacity now:
# Storage > Data Foundation > Action Menu > Add Capacity
# Select the StorageClass backed by the new larger disks
```

### Step C: Move Remaining Components to Master Nodes

After ODF is migrated (Step B), move remaining infra components.

#### Step C1: Move GitOps + Pipelines + Quay to master02

```bash
# Update ArgoCD nodeSelector and tolerations to master02
# (modify ArgoCD CR, not Deployment directly)

# Update OpenShift Pipelines nodeSelector and tolerations to master02

# Update Quay nodeSelector and tolerations to master02

# Update Cert Manager nodeSelector and tolerations to master02

# Update OpenTelemetry nodeSelector and tolerations to master02

# Update KEDA nodeSelector and tolerations to master02

# Wait for pods to reschedule
oc get pods -n openshift-gitops -w
oc get pods -n openshift-pipelines -w
```

#### Step C2: Move remaining operators to master03

```bash
# Update Service Mesh nodeSelector and tolerations to master03
# Update Elasticsearch ECK nodeSelector and tolerations to master03
# Update ACM nodeSelector and tolerations to master03
# Update Multicluster Engine nodeSelector and tolerations to master03
# Update NeuVector/Aqua/RHACS nodeSelector and tolerations to master03
# Update Confluent nodeSelector and tolerations to master03
# Update CloudNativePG nodeSelector and tolerations to master03
# Update DevWorkspace nodeSelector and tolerations to master03
# Update Web Terminal nodeSelector and tolerations to master03
# Update Kasten K10 nodeSelector and tolerations to master03

# Wait for pods to reschedule
```

#### Step C3: Verify all workloads migrated

```bash
# Verify all infra pods running on master nodes
oc get pods --all-namespaces -o wide | grep master

# Verify no infra pods left on old VM infra nodes
oc get pods --all-namespaces -o wide | grep infra0
# Expected: no output

# Verify all applications healthy
oc get pods --all-namespaces | grep -v Running | grep -v Completed
```

---

### Step D: Delete Remaining infra VMs (infra04-06)

```bash
# infra01-03 already deleted in Step B
# Delete infra04-06

oc cordon infra04
oc drain infra04 --ignore-daemonsets --delete-emptydir-data
oc delete node infra04

oc cordon infra05
oc drain infra05 --ignore-daemonsets --delete-emptydir-data
oc delete node infra05

oc cordon infra06
oc drain infra06 --ignore-daemonsets --delete-emptydir-data
oc delete node infra06

# Delete VMs from vCenter
```

---

### Phase 3 Acceptance Criteria

- [ ] All infra components running on 3 BM master nodes
- [ ] No infra pods left on old VM nodes
- [ ] All 6 VMware infra VMs decommissioned
- [ ] etcd cluster healthy
- [ ] ODF/Ceph healthy with OSDs on master nodes
- [ ] Monitoring stack healthy
- [ ] All 66 routes normal
- [ ] ArgoCD sync normal
- [ ] All Cluster Operators normal

### Phase 3 Important Notes

1. **NVMe for ODF** -- Each master must have dedicated NVMe for Ceph OSD, separate from etcd
2. **Resource planning** -- Verify each master has enough resources before moving workloads
3. **One ODF node at a time** -- Move ODF one node at a time, wait for Ceph HEALTH_OK before next
4. **Rebalancing** -- Ceph rebalance may take time after OSD migration
5. **Monitoring** -- Watch for resource pressure on master nodes after workload migration
6. **Node selector + toleration required** -- Every component must have both nodeSelector and toleration to run on master nodes
7. **Grafana removed** -- Do NOT include `grafana:` in monitoring ConfigMap (removed in OCP 4.11)
8. **ODF order** -- Complete all ODF node replacements (Step B) before moving other components (Step C)

## Phase 4: Add 3 More Workers (Optional)

> **Risk: LOW | Time: 3-5 days | Method: cordon/drain/replace**

### Overview

After Phase 3, you have 3 master BM + 3 worker BM. This phase adds 3 more worker BM nodes to reach the final architecture of 3 masters + 6 workers.

### Phase 4 Steps

Repeat Phase 1 Steps 1-4 for worker04, worker05, worker06.

### Phase 4 Acceptance Criteria

- [ ] 6 BM workers Ready
- [ ] All apps running normally
- [ ] TopoLVM working on all BM workers
- [ ] All routes normal
- [ ] ArgoCD sync normal
- [ ] ODF health normal
- [ ] Monitoring normal

---

## Bare Metal Network Configuration (NIC Bonding)

VMware uses vSwitch with uplinks for NIC teaming. On bare metal, we use Linux bonding + OVN-Kubernetes br-ex bridge.

### Bonding Mode Selection

| Mode | Name | Switch Config Required | Redundancy | Load Balance |
|------|------|----------------------|------------|--------------|
| 1 | active-backup | No | Yes | No |
| 2 | balance-xor | Yes | Yes | Yes (XOR) |
| 4 | 802.3ad (LACP) | Yes (LACP) | Yes | Yes (best) |
| 6 | balance-alb | No | Yes | Yes (ALB) |

**Your choice: mode 4 (802.3ad)** because your Switch supports LACP.

### Method 1: Kernel Argument (Simplest at Install Time)

At RHCOS boot, add `bond=` parameter to kernel command line:

```
# DHCP mode
bond=bond0:eno1,eno2:mode=802.3ad
ip=bond0:dhcp
nameserver=192.168.89.61
```

- `bond0` = bonding device name
- `eno1,eno2` = physical NICs (check with `ip link`)
- `mode=802.3ad` = LACP (requires Switch LACP support)
- Only controls initramfs stage, br-ex needs separate configuration

### Method 2: NMState YAML + Ignition (Official Recommended)

Create NMState YAML -> base64 -> place in ignition config:

```yaml
interfaces:
  - name: eno1
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  - name: eno2
    type: ethernet
    state: up
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  - name: bond0
    type: bond
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: false
    link-aggregation:
      mode: 802.3ad
      port:
        - eno1
        - eno2

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

  - name: br-ex
    type: ovs-interface
    state: up
    copy-mac-from: eno1
    ipv4:
      enabled: true
      dhcp: true
      auto-route-metric: 48
```

### Method 3: MachineConfig (Post-install / Existing Cluster)

Push NMState YAML to `/etc/nmstate/openshift/<node>.yml` via MachineConfig:

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
            source: data:text/plain;charset=utf-8;base64,<BASE64_ENCODED_NMSTATE>
          mode: 0644
          overwrite: true
          path: /etc/nmstate/openshift/worker01.yml
```

### Verify Bonding

```bash
# Check bond status
oc debug node/<node> -- chroot /host cat /proc/net/bonding/bond0

# Check OVS bridge
oc debug node/<node> -- chroot /host ovs-vsctl show

# Check nmstate
oc debug node/<node> -- chroot /host nmstatectl show bond0
```

### Rollback

If bonding configuration fails:

```bash
# Method 1: Delete NMState config
oc debug node/<node> -- chroot /host rm /etc/nmstate/openshift/<node>.yml
oc debug node/<node> -- chroot /host systemctl restart NetworkManager

# Method 2: Delete MachineConfig (from other working node)
oc delete machineconfig 10-br-ex-worker01
# Triggers reboot to apply
```

### Bonding Important Notes

1. **NIC names must be correct** -- Use `ip link` to confirm actual NIC names (eno1/eno2/em1/em2/ens160 etc)
2. **MAC address** -- Bond interface should use `copy-mac-from` to copy one NIC's MAC
3. **auto-route-metric: 48** -- Ensures br-ex default route has highest priority
4. **Every BM node must be configured** -- Do not configure only one, all 3 workers need it
5. **Test failover** -- After installation, unplug one network cable to test bonding failover

---

# Part 3: Rollback Procedures

---

## Rollback: Phase 1 - Workers VM to BM

> **Risk: LOW | Rollback window: Before deleting old VMs**

Phase 1 is the easiest to rollback because the old VMs are simply powered off, not deleted until Step 4.

### Rollback Steps

#### Step R1: Verify old VMs are still available

```bash
# Check if old VMs are still in vCenter (not yet deleted)
# If VMs were only shut down (not deleted from disk), they can be powered back on
```

#### Step R2: Power on old VM workers

```bash
# From vCenter: Power On worker01, worker02, worker03 VMs
# Or via SSH if VMs are accessible:
ssh root@worker01
# VM should boot and rejoin cluster
```

#### Step R3: Verify old VMs rejoin cluster

```bash
oc get nodes -w
# Wait for worker01, worker02, worker03 to show Ready status
```

#### Step R4: Cordon + Drain BM workers

```bash
# Move workloads back to VM workers
oc cordon worker01-bm
oc drain worker01-bm --ignore-daemonsets --delete-emptydir-data

oc cordon worker02-bm
oc drain worker02-bm --ignore-daemonsets --delete-emptydir-data

oc cordon worker03-bm
oc drain worker03-bm --ignore-daemonsets --delete-emptydir-data
```

#### Step R5: Verify workloads migrated back

```bash
oc get pods --all-namespaces -o wide | grep worker01
# Expected: pods running on old VM worker01
```

#### Step R6: Delete BM workers (optional)

```bash
# If you want to fully revert to VMware-only:
oc delete node worker01-bm
oc delete node worker02-bm
oc delete node worker03-bm

# Delete BM machines from vCenter (if applicable)
```

#### Rollback Verification

```bash
# All nodes Ready
oc get nodes

# All pods healthy
oc get pods --all-namespaces | grep -v Running | grep -v Completed

# ODF healthy
oc get pods -n openshift-storage | grep -v Running

# Monitoring healthy
oc get pods -n openshift-monitoring | grep -v Running

# All routes normal
oc get routes --all-namespaces | wc -l
```

### Rollback Prerequisites

- [ ] Old VM workers still exist in vCenter (not deleted from disk)
- [ ] Old VM workers can be powered on
- [ ] BM workers have been drained before powering on old VMs

---

## Rollback: Phase 2 - Masters VM to BM (etcd Replacement)

> **Risk: HIGH | Rollback window: Before deleting old master VMs**
> **Reference:** OCP 4.20 Backup and Restore - Restoring to an earlier cluster state

Phase 2 rollback is more complex because it involves etcd. If the old master VMs are still available, rollback is possible but risky.

### Rollback Steps

#### Step R1: Verify old master VMs are still available

```bash
# Check if old master VMs are still in vCenter
# If VMs were only shut down (not deleted from disk), they can be powered back on
```

#### Step R2: Take etcd snapshot (from current BM masters)

```bash
# Backup current etcd state BEFORE rollback
oc exec -n openshift-etcd \
  $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1) -- \
  etcdctl snapshot save /tmp/etcd-rollback-$(date +%Y%m%d).db
```

#### Step R3: Power on old master VMs

```bash
# From vCenter: Power On master01, master02, master03 VMs
```

#### Step R4: Restore etcd from snapshot

```bash
# This is the most critical step
# Follow OCP 4.20 official restore procedure:
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore

# Stop etcd on all BM masters
# Restore etcd from snapshot
# Restart etcd

# WARNING: This can cause cluster downtime
```

#### Step R5: Update HAProxy

```bash
# Update HAProxy backend to point back to old VM master IPs
# Reload HAProxy
```

#### Step R6: Verify cluster health

```bash
# etcd healthy
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl endpoint health --cluster
exit

# All nodes Ready
oc get nodes

# All Cluster Operators normal
oc get co | grep -v "True.*False.*False"
```

#### Rollback Verification

```bash
# etcd cluster stable
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl member list -w table
etcdctl endpoint health --cluster
exit

# All pods healthy
oc get pods --all-namespaces | grep -v Running | grep -v Completed

# All routes normal
oc get routes --all-namespaces | wc -l
```

### Rollback Prerequisites

- [ ] Old master VMs still exist in vCenter (not deleted from disk)
- [ ] Old master VMs can be powered on
- [ ] etcd snapshot taken before rollback
- [ ] HAProxy configuration backed up
- [ ] Maintenance window scheduled (cluster may have downtime during restore)

### Rollback Risks

1. **etcd restore may cause downtime** -- Cluster may be unavailable during etcd restore
2. **Certificate issues** -- Old VMs may have stale certificates
3. **Node name conflicts** -- Old VM node names may conflict with new BM node names
4. **Data loss risk** -- If etcd restore fails, cluster may need full rebuild

---

## Rollback: Phase 3 - Infra to Master BM (Move Infra Components)

> **Risk: MEDIUM | Rollback window: Before deleting infra VMs**

Phase 3 rollback is possible if the old infra VMs are still available. The key is to move components back to the old VMs before deleting them.

### Rollback Steps

#### Step R1: Verify old infra VMs are still available

```bash
# Check if old infra01-06 VMs are still in vCenter
```

#### Step R2: Power on old infra VMs

```bash
# From vCenter: Power On infra01-06 VMs
```

#### Step R3: Move components back to old VMs

```bash
# Reverse the nodeSelector changes from Phase 3

# Move Router back to old infra VMs
oc patch ingresscontrollers.operator.openshift.io default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"nodePlacement": {"nodeSelector": {"matchLabels": {"node-role.kubernetes.io/worker": ""}},"tolerations": []}}}'

# Scale back to 2 replicas
oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge -p '{"spec":{"replicas": 2}}'

# Move Registry back
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"nodeSelector": {"node-role.kubernetes.io/worker": ""},"tolerations": []}}'

# Move Monitoring back
oc delete configmap cluster-monitoring-config -n openshift-monitoring
# Monitoring will revert to default placement on worker nodes
```

#### Step R4: Move ODF back to old infra VMs

```bash
# This is the most complex rollback step
# Reverse the ODF node replacement process

# For each master node (master01-03):
# 1. Scale down OSD on master
# 2. Update LocalVolumeDiscovery/Set (add old infra node, remove master)
# 3. Wait for Ceph rebalance
# 4. Re-add ODF label to old infra node

# WARNING: This may cause temporary Ceph unavailability
```

#### Step R5: Move remaining components back

```bash
# Reverse nodeSelector changes for:
# - GitOps, Pipelines, Quay
# - Service Mesh, ACM, Multicluster Engine
# - NeuVector/Aqua/RHACS, Cert Manager
# - Confluent, CloudNativePG
# - DevWorkspace, Web Terminal
# - Kasten K10, OpenTelemetry, KEDA
```

#### Step R6: Cordon + Drain BM master nodes

```bash
# After all components are moved back to old VMs
oc cordon master01-bm
oc drain master01-bm --ignore-daemonsets --delete-emptydir-data

oc cordon master02-bm
oc drain master02-bm --ignore-daemonsets --delete-emptydir-data

oc cordon master03-bm
oc drain master03-bm --ignore-daemonsets --delete-emptydir-data
```

#### Step R7: Verify

```bash
# All components running on old infra VMs
oc get pods --all-namespaces -o wide | grep infra

# No pods on BM masters (except etcd/control plane)
oc get pods --all-namespaces -o wide | grep master

# Cluster health
oc get nodes
oc get co | grep -v "True.*False.*False"
```

#### Rollback Verification

```bash
# etcd healthy
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd -o name | head -1)
etcdctl endpoint health --cluster
exit

# ODF healthy
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-mon -o name | head -1)
ceph health
exit

# Monitoring healthy
oc get pods -n openshift-monitoring | grep -v Running

# All routes normal
oc get routes --all-namespaces | wc -l

# ArgoCD sync normal
oc get applications -n openshift-gitops
```

### Rollback Prerequisites

- [ ] Old infra01-06 VMs still exist in vCenter (not deleted from disk)
- [ ] Old infra VMs can be powered on
- [ ] ODF rollback completed first (most complex step)
- [ ] All component nodeSelector changes backed up before Phase 3

### Rollback Risks

1. **ODF rollback is complex** -- Moving OSD back from masters to old infra VMs requires careful Ceph management
2. **Ceph rebalance** -- Rollback may cause temporary Ceph performance degradation
3. **Component downtime** -- Some components may have brief downtime during nodeSelector changes
4. **Monitoring gap** -- Monitoring may have a brief gap during ConfigMap recreation

---

## Rollback Summary

| Phase | Risk | Key Constraint | Rollback Complexity |
|-------|------|----------------|-------------------|
| Phase 1: Workers VM to BM | LOW | Old VMs must exist | SIMPLE - power on VMs, drain BM |
| Phase 2: Masters VM to BM | HIGH | Old VMs + etcd restore | COMPLEX - etcd restore may cause downtime |
| Phase 3: Infra to Master BM | MEDIUM | Old infra VMs must exist | MODERATE - ODF rollback is complex |

### General Rollback Rules

1. **Always backup before rollback** -- Take etcd snapshot, backup HAProxy config, backup monitoring rules
2. **One phase at a time** -- Do not attempt to rollback multiple phases simultaneously
3. **Test in lab first** -- If possible, test rollback procedure in a lab environment
4. **Schedule maintenance window** -- Phase 2 rollback may cause cluster downtime
5. **Verify after each step** -- Check cluster health after every rollback step

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
- Kubernetes NMState Operator: https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/networking/kubernetes-nmstate
- Platform-agnostic install: platform: none in install-config.yaml
- ODF 4.20 Replacing nodes (bare metal operational): https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/replacing_nodes/openshift_data_foundation_deployed_using_local_storage_devices#replacing-an-operational-node-using-local-storage-devices_bm-upi-operational
- ODF 4.20 Replacing nodes index: https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/replacing_nodes/index
- ODF 4.20 Deploying on bare metal: https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/deploying_openshift_data_foundation_using_bare_metal_infrastructure/
- ODF 4.20 Scaling Storage (Reorganization of ODF OSDs): https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.20/html/scaling_storage/scaling_storage_of_bare_metal_openshift_data_foundation_cluster
- Red Hat KB #7134635 (Migrating Ceph OSDs Using the Same StorageClass): https://access.redhat.com/solutions/7134635

---

# Part 4: ODF OSD Migration — 600GB → 1TB NVMe (Same StorageClass)

> **When to use:** If new BM nodes have different disk sizes (e.g., 1TB NVMe) than existing ODF nodes (e.g., 600GB), ODF does NOT support heterogeneous disk sizes within the same StorageDeviceSet. This section covers migrating OSDs using the Same StorageClass method (KB #7134635).
>
> **Applies to:** Phase 3 Step B (ODF migration) when new NVMe disks are larger than old VM disks.

---

## Part 4 Table of Contents

- [Part 4 Scenario](#part-4-scenario)
- [Part 4 Prerequisites](#part-4-prerequisites)
- [Part 4 Phase 1: Prepare New Nodes (OCP + ODF Label)](#part-4-phase-1-prepare-new-nodes-ocp--odf-label)
- [Part 4 Phase 2: Update LocalVolumeSet (nodeSelector + minSize/maxSize)](#part-4-phase-2-update-localvolumeset-nodeselector--minsizemaxsize)
- [Part 4 Phase 3: Update LocalVolumeDiscovery (nodeSelector)](#part-4-phase-3-update-localvolumediscovery-nodeselector)
- [Part 4 Phase 4: Verify New 1TB PVs Discovered (Same SC)](#part-4-phase-4-verify-new-1tb-pvs-discovered-same-sc)
- [Part 4 Phase 5: Backup StorageCluster](#part-4-phase-5-backup-storagecluster)
- [Part 4 Phase 6: Scale Up StorageCluster (Add New 1TB OSDs)](#part-4-phase-6-scale-up-storagecluster-add-new-1tb-ossds)
- [Part 4 Phase 7: Wait for Rebalance — HEALTH_OK](#part-4-phase-7-wait-for-rebalance--health_ok)
- [Part 4 Phase 8: Scale Down Rook-Ceph-Operator](#part-4-phase-8-scale-down-rook-ceph-operator)
- [Part 4 Phase 9: Remove Old 600GB OSDs (One at a Time!)](#part-4-phase-9-remove-old-600gb-ossds-one-at-a-time)
- [Part 4 Phase 10: Adjust StorageCluster Count Back](#part-4-phase-10-adjust-storagecluster-count-back)
- [Part 4 Phase 11: Scale Up Rook-Ceph-Operator & Verify](#part-4-phase-11-scale-up-rook-ceph-operator--verify)
- [Part 4 Verification Checklist](#part-4-verification-checklist)
- [Part 4 Rollback Plan](#part-4-rollback-plan)
- [Part 4 Critical Warnings](#part-4-critical-warnings)

---

## Part 4 Scenario

| Item | Before | After |
|------|--------|-------|
| Storage Nodes | infra01-03 (VMware, 600GB) | new-node1-3 (BM, 1TB NVMe) |
| Old OSD Count | 3 (600GB each) | 0 (removed) |
| New OSD Count | 0 | 3 (1TB NVMe each) |
| Final OSD Count | 3 | 3 (all 1TB) |
| Raw Capacity | 1,800 GB | 3,000 GB |
| Usable Capacity (3x replica) | 600 GB | 1,000 GB |
| StorageClass | lab | lab (SAME) |
| LocalVolumeSet name | lab | lab |
| Platform | Bare Metal + LSO | Bare Metal + LSO |
| failureDomain | host or rack | host or rack |
| ODF version | >= 4.16 required | — |

**Key constraint:** ODF does NOT support heterogeneous disk sizes within the same StorageDeviceSet. This migration adds new 1TB OSDs on new nodes, then removes old 600GB OSDs from old nodes, keeping the same StorageClass.

---

## Part 4 Prerequisites

- [ ] Administrative access to OCP console and `oc` CLI
- [ ] Running ODF StorageCluster in `Ready` state
- [ ] 3 new BM servers ready (each with 1TB NVMe)
- [ ] CPU/Memory headroom on new nodes: each OSD uses 2 CPU + 5GiB memory
- [ ] Backup of critical data (recommended before any OSD operation)
- [ ] ODF version >= 4.16 (this process is GA since 4.16)
- [ ] Current LocalVolumeSet: `lab`, nodes: infra01-03, storageClassName: lab

---

## Part 4 Phase 1: Prepare New Nodes (OCP + ODF Label)

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

## Part 4 Phase 2: Update LocalVolumeSet (nodeSelector + minSize/maxSize)

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

## Part 4 Phase 3: Update LocalVolumeDiscovery (nodeSelector)

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

## Part 4 Phase 4: Verify New 1TB PVs Discovered (Same SC)

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

## Part 4 Phase 5: Backup StorageCluster

```bash
oc get storagecluster -n openshift-storage ocs-storagecluster -o yaml > storagecluster.yaml
```

Keep this backup safe — you'll need it for rollback.

---

## Part 4 Phase 6: Scale Up StorageCluster (Add New 1TB OSDs)

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

## Part 4 Phase 7: Wait for Rebalance — HEALTH_OK

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

## Part 4 Phase 8: Scale Down Rook-Ceph-Operator

```bash
oc scale deployment -n openshift-storage rook-ceph-operator --replicas=0
```

Verify:
```bash
oc get deployment -n openshift-storage rook-ceph-operator
```

Expected: `0/1` ready.

---

## Part 4 Phase 9: Remove Old 600GB OSDs (One at a Time!)

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

## Part 4 Phase 10: Adjust StorageCluster Count Back

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

## Part 4 Phase 11: Scale Up Rook-Ceph-Operator & Verify

```bash
oc scale deployment -n openshift-storage rook-ceph-operator --replicas=1
```

Verify no OSD prepare pods appear (confirms count is correct):

```bash
oc get pods -n openshift-storage | grep osd-prepare
# Expected: no output (no new OSDs being prepared)
```

---

## Part 4 Verification Checklist

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

## Part 4 Rollback Plan

If anything goes wrong during migration:

1. **Before removing old OSDs:** Simply revert StorageCluster count to original. Old 600GB OSDs are still running on infra01-03.

2. **After removing some old OSDs but not all:**
   - Stop further removals
   - Wait for HEALTH_OK
   - The remaining old OSDs can continue serving data
   - Contact Red Hat Support for guidance

3. **Emergency:** Restore from backup taken in Phase 5.

---

## Part 4 Critical Warnings

> ⚠️ **OSD removal is IRREVERSIBLE** — once an OSD is removed, its data must be rebuilt from replicas on other OSDs.

> ⚠️ **NEVER remove multiple OSDs simultaneously** — this can cause COMPLETE DATA LOSS.

> ⚠️ **NEVER proceed if Ceph is not HEALTH_OK or PGs are not all active+clean.**

> ⚠️ **Each OSD uses 2 CPU + 5GiB memory** — ensure new nodes have sufficient resources before scaling up.

> ⚠️ **This process was introduced in ODF v4.16 GA** — verify your ODF version >= 4.16 before proceeding.

> ⚠️ **New node hostnames must be updated in both LocalVolumeSet AND LocalVolumeDiscovery nodeSelector.**

---

### How Part 4 Relates to Phase 3 Step B

Part 4 is an **alternative/complement** to Phase 3 Step B. Use Part 4 when:

- New BM nodes have **different disk sizes** than existing ODF nodes
- You cannot simply "add capacity" because ODF rejects heterogeneous disks
- You need to **replace** old OSDs with new ones on different hardware

**Integration point:** After Part 4 completes (old 600GB OSDs removed, new 1TB OSDs active), continue with Phase 3 Step C (move remaining components to master nodes).

```
Phase 3 Execution Order (with Part 4):
  Step A: Move non-ODF components (Router, Registry, Monitoring) to master nodes
  Step B: Move ODF from infra01-03 to master01-03
    → If disk sizes differ: use Part 4 (ODF OSD Migration) here
    → If disk sizes match: use standard ODF node replacement
  Step C: Move remaining components (GitOps, Pipelines, Quay, etc.) to master nodes
  Step D: Cordon + Drain + Delete infra01-06 VMs
```

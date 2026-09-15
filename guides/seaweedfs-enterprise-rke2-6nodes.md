# SeaweedFS Enterprise on RKE2 — 6 Nodes Deployment Guide

> Target: RKE2 cluster, 6 worker nodes, production datalake with Apache Paimon + Flink
> SeaweedFS version: 4.47+ Enterprise
> Last updated: 2026-09-15

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Step 1: Node Preparation & Labeling](#step-1-node-preparation--labeling)
- [Step 2: StorageClass Planning](#step-2-storageclass-planning)
- [Step 3: Namespace & Enterprise License](#step-3-namespace--enterprise-license)
- [Step 4: Helm Chart Installation](#step-4-helm-chart-installation)
- [Step 5: Verify Cluster Health](#step-5-verify-cluster-health)
- [Step 6: Configure S3 Access & Create Buckets](#step-6-configure-s3-access--create-buckets)
- [Step 7: Configure Erasure Coding (Enterprise)](#step-7-configure-erasure-coding-enterprise)
- [Step 8: Configure Data Recovery & PITR (Enterprise)](#step-8-configure-data-recovery--pitr-enterprise)
- [Step 9: Enable Iceberg REST Catalog for Paimon](#step-9-enable-iceberg-rest-catalog-for-paimon)
- [Step 10: Monitoring with Prometheus](#step-10-monitoring-with-prometheus)
- [Step 11: Backup Strategy](#step-11-backup-strategy)
- [Step 12: Day-2 Operations](#step-12-day-2-operations)
- [Appendix A: Node-to-Component Mapping](#appendix-a-node-to-component-mapping)
- [Appendix B: values.yaml Reference](#appendix-b-valuesyaml-reference)
- [Appendix C: Troubleshooting](#appendix-c-troubleshooting)
- [Appendix D: Enterprise License Activation](#appendix-d-enterprise-license-activation)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        6 RKE2 Worker Nodes                          │
├──────────┬──────────┬──────────┬──────────┬──────────┬──────────────┤
│ Worker 1 │ Worker 2 │ Worker 3 │ Worker 4 │ Worker 5 │ Worker 6     │
│ Master   │ Master   │ Master   │ Volume   │ Volume   │ Filer+S3     │
│ x3 Raft  │ (failov) │ (failov) │ +Worker  │ +Worker  │ Gateway x2   │
└──────────┴──────────┴──────────┴──────────┴──────────┴──────────────┘

Data Flow:
  Paimon/Flink ──S3 API──► S3 Gateway ──► Filer ──► Volume Servers
                                                        │
                                          ┌─────────────┼─────────────┐
                                          ▼             ▼             ▼
                                      Hot Data     Warm Data    Cloud Tier
                                    (Replicated)  (EC 10+4)   (S3/GCS/AZ)
```

### Component Distribution (6 Nodes)

| Node | Components | Rationale |
|------|-----------|-----------|
| Worker 1 | Master (Leader) | Raft leader for cluster coordination |
| Worker 2 | Master (Follower) | Raft quorum (2 of 3) |
| Worker 3 | Master (Follower) | Full Raft HA |
| Worker 4 | Volume Server + EC Worker | Data storage, EC processing |
| Worker 5 | Volume Server + EC Worker | Data storage, EC processing |
| Worker 6 | Filer x2 + S3 Gateway x2 | Stateless gateways, scale via replicas |

> **Note:** Master, Volume, and Filer pods use anti-affinity to avoid co-location.
> Filer and S3 gateways are stateless — scale horizontally as needed.

---

## Prerequisites

- RKE2 cluster running (v1.28+)
- `kubectl` access to the cluster
- `helm` v3.10+ installed
- StorageClass available (NFS, Longhorn, or local-path)
- DNS resolution for S3 endpoint (e.g., `s3.datalake.local`)
- (Optional) cert-manager for TLS

---

## Step 1: Node Preparation & Labeling

SeaweedFS Helm chart uses node labels for scheduling. Label nodes according to their role:

```bash
# Label Masters (Raft consensus — spread across 3 nodes)
kubectl label node worker1 sw-backend=true
kubectl label node worker2 sw-backend=true
kubectl label node worker3 sw-backend=true

# Label Volume Servers (data storage — spread across nodes)
kubectl label node worker4 sw-volume=true
kubectl label node worker5 sw-volume=true

# Label Filer/S3 nodes (stateless gateways)
kubectl label node worker6 sw-backend=true
```

Verify labels:
```bash
kubectl get nodes --show-labels | grep -E 'sw-backend|sw-volume'
```

---

## Step 2: StorageClass Planning

Choose a StorageClass for each component type:

| Component | Recommended StorageClass | Size per PVC | Rationale |
|-----------|------------------------|-------------|-----------|
| Master | `nfs-csi` or `longhorn` | 1Gi | Only stores Raft state, minimal I/O |
| Volume Server data | `nfs-csi` or `longhorn` | 500Gi+ (or disk) | Bulk data storage, I/O intensive |
| Volume Server WAL | `nfs-csi` or `longhorn` | 50Gi | Write-ahead log |
| Filer metadata | `nfs-csi` or `longhorn` | 50Gi | Filesystem metadata |
| Filer S3 config | `nfs-csi` or `longhorn` | 1Gi | S3 configuration |

> **Tip:** For best performance, Volume servers should use local SSDs or dedicated NFS exports.
> If using NFS, ensure 10GbE networking between nodes and NFS server.

---

## Step 3: Namespace & Enterprise License

### Create Namespace

```bash
kubectl create namespace seaweedfs
```

### Obtain Enterprise License

1. Deploy SeaweedFS first (Community edition), then apply license later
2. Or contact seaweedfs.com for a pre-configured Enterprise image + license

**License pricing:**
- < 25TB: **Free** (no license required)
- Monthly: $1/TB/month
- Yearly: $10/TB/year (save ~17%)
- Support: $2,000/year (optional, 24h business day response)

---

## Step 4: Helm Chart Installation

### Add Helm Repository

```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update seaweedfs
```

### Create values.yaml

```bash
cat > seaweedfs-values.yaml << 'EOF'
# ============================================================
# SeaweedFS Enterprise — 6-Node RKE2 Production Deployment
# ============================================================

global:
  seaweedfs:
    # Enterprise: use enterprise image (uncomment after license)
    # image:
    #   name: chrislusf/seaweedfs-enterprise
    # license:
    #   existingSecret: seaweedfs-license

    # Replication for hot data (2 copies across different nodes)
    enableReplication: true
    replicationPlacement: "001"

# ------------------------------------------------------------
# Master Servers — 3 nodes for Raft HA
# ------------------------------------------------------------
master:
  replicas: 3
  # Spread masters across worker1, worker2, worker3
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - seaweedfs
              - key: app.kubernetes.io/component
                operator: In
                values:
                  - master
          topologyKey: kubernetes.io/hostname
  data:
    type: persistentVolumeClaim
    storageClass: "nfs-csi"
    size: 1Gi
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 1Gi
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false  # set true if Prometheus Operator installed

# ------------------------------------------------------------
# Volume Servers — 2 nodes (expandable)
# ------------------------------------------------------------
volume:
  replicas: 2
  # Spread across worker4, worker5
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - seaweedfs
              - key: app.kubernetes.io/component
                operator: In
                values:
                  - volume
          topologyKey: kubernetes.io/hostname
  dataDirs:
    - name: data
      type: persistentVolumeClaim
      storageClass: "nfs-csi"
      size: 500Gi
      maxVolumes: 0    # 0 = auto-calculate from disk size
    - name: wal
      type: persistentVolumeClaim
      storageClass: "nfs-csi"
      size: 50Gi
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 4Gi
  metrics:
    enabled: true

# ------------------------------------------------------------
# Filer Servers — 2 replicas (stateless, scale freely)
# ------------------------------------------------------------
filer:
  replicas: 2
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
                - key: app.kubernetes.io/component
                  operator: In
                  values:
                    - filer
            topologyKey: kubernetes.io/hostname
  data:
    type: persistentVolumeClaim
    storageClass: "nfs-csi"
    size: 50Gi
  s3:
    enabled: true
    enableAuth: true
    createBuckets:
      - name: paimon-datalake
      - name: paimon-cdc
      - name: paimon-backup
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 2Gi
  metrics:
    enabled: true

# ------------------------------------------------------------
# S3 Gateway — 2 replicas for HA
# ------------------------------------------------------------
s3:
  enabled: true
  replicas: 2
  enableAuth: true
  credentials:
    paimon:
      accessKey: paimon-access-key
      secretKey: paimon-secret-key-change-me
    admin:
      accessKey: admin-access-key
      secretKey: admin-secret-key-change-me
  createBuckets:
    - name: paimon-datalake
    - name: paimon-cdc
    - name: paimon-backup
  ingress:
    enabled: true
    className: nginx
    annotations:
      nginx.ingress.kubernetes.io/proxy-body-size: "0"  # unlimited upload
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    hosts:
      - host: s3.datalake.local
        paths:
          - path: /
            pathType: Prefix
    tls: []
    #  - secretName: s3-datalake-tls
    #    hosts:
    #      - s3.datalake.local
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 2Gi
  metrics:
    enabled: true

# ------------------------------------------------------------
# Worker — EC, Vacuum, Volume Balance
# ------------------------------------------------------------
worker:
  enabled: true
  workingDir: /tmp/seaweedfs-worker
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 1Gi

# ------------------------------------------------------------
# Iceberg REST Catalog — for Paimon/Spark/Trino
# ------------------------------------------------------------
# Enabled via filer.s3 — the S3 gateway serves the Iceberg
# REST catalog at the same endpoint.
# Configure Paimon to use:
#   catalog-impl: org.apache.paimon.catalog.IcebergCatalog
#   uri: http://seaweedfs-s3.seaweedfs.svc:8333

# ------------------------------------------------------------
# Prometheus Monitoring
# ------------------------------------------------------------
monitoring:
  enabled: true
  serviceMonitor:
    enabled: false   # set true if Prometheus Operator installed

# ------------------------------------------------------------
# Network Policies
# ------------------------------------------------------------
networkPolicy:
  enabled: false     # set true if network policies enforced
EOF
```

### Install the Chart

```bash
helm install seaweedfs seaweedfs/seaweedfs \
  -n seaweedfs \
  -f seaweedfs-values.yaml \
  --version 4.46.0
```

### Wait for Pods to be Ready

```bash
kubectl -n seaweedfs get pods -w
# Wait until all pods show Running and Ready
# Expected:
#   seaweedfs-master-0     1/1     Running
#   seaweedfs-master-1     1/1     Running
#   seaweedfs-master-2     1/1     Running
#   seaweedfs-volume-0     1/1     Running
#   seaweedfs-volume-1     1/1     Running
#   seaweedfs-filer-0      1/1     Running
#   seaweedfs-filer-1      1/1     Running
#   seaweedfs-s3-0         1/1     Running
#   seaweedfs-s3-1         1/1     Running
#   seaweedfs-worker-0     1/1     Running
```

---

## Step 5: Verify Cluster Health

### Check Master Raft Status

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 <<< "cluster.info"
```

Expected output:
```
cluster leaders:
  192.168.x.x:9333  [Primary]
  192.168.x.x:9333  [Secondary]
  192.168.x.x:9333  [Secondary]

volume servers:
  192.168.x.x:8080
  192.168.x.x:8080
```

### Check Volume Servers

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 <<< "volume.list"
```

### Check Filer

```bash
kubectl -n seaweedfs port-forward svc/seaweedfs-filer-client 8888:8888 -n seaweedfs &
curl http://localhost:8888/
```

### Check S3 API

```bash
# Port-forward S3
kubectl -n seaweedfs port-forward svc/seaweedfs-s3-client 8333:8333 -n seaweedfs &

# Configure AWS CLI
export AWS_ACCESS_KEY_ID=admin-access-key
export AWS_SECRET_ACCESS_KEY=admin-secret-key-change-me
aws --endpoint-url http://localhost:8333 s3 ls

# Create test bucket and upload
aws --endpoint-url http://localhost:8333 s3 mb s3://test-bucket
echo "Hello SeaweedFS" | aws --endpoint-url http://localhost:8333 s3 cp - s3://test-bucket/test.txt
aws --endpoint-url http://localhost:8333 s3 ls s3://test-bucket/
```

### Check Web UI

```bash
kubectl -n seaweedfs port-forward svc/seaweedfs-master 9333:9333 -n seaweedfs &
# Open http://localhost:9333 in browser
```

---

## Step 6: Configure S3 Access & Create Buckets

### Create IAM Config for Paimon

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 << 'EOF'
iam.user.create -user=paimon-user
iam.policy.create -user=paimon-user -actions=s3:GetObject,s3:PutObject,s3:DeleteObject,s3:ListBucket,s3:GetBucketLocation -resources=arn:aws:s3:::paimon-*,arn:aws:s3:::paimon-*
iam.user.create -user=flink-user
iam.policy.create -user=flink-user -actions=s3:GetObject,s3:PutObject,s3:ListBucket -resources=arn:aws:s3:::paimon-*,arn:aws:s3:::paimon-*
iam.user.create -user=spark-user
iam.policy.create -user=spark-user -actions=s3:GetObject,s3:ListBucket -resources=arn:aws:s3:::paimon-*,arn:aws:s3:::paimon-*
EOF
```

### Verify Bucket Creation

```bash
aws --endpoint-url http://localhost:8333 s3 ls
```

---

## Step 7: Configure Erasure Coding (Enterprise)

Enterprise allows customizable EC ratios. Default is 10+4 (1.4x overhead, tolerates 4 failures).

### Recommended EC Ratios for Datalake

| Ratio | Overhead | Tolerance | Use Case |
|-------|----------|-----------|----------|
| 10+4 | 1.4x | 4 failures | Default, good balance |
| 16+4 | 1.25x | 4 failures | Cost-optimized, 4+ volume servers |
| 20+4 | 1.2x | 4 failures | Maximum savings, 5+ volume servers |

> **Constraint:** Total shards (data + parity) must be < 32.
> With 6 nodes, 20+4 = 24 shards, tolerating 4 simultaneous failures.

### Apply EC Configuration via weed shell

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 << 'EOF'
# View current EC settings
ec.configure

# Set EC ratio (e.g., 10+4)
ec.configure -defaultReplication=001 -ecShards=10 -ecParity=4

# Trigger EC on warm volumes
ec.balance
EOF
```

### How EC Works with Volume Tiers

1. **Hot data** → Written with replication (2x via `replicationPlacement: "001"`)
2. **Background worker** → After volume cools down, applies EC 10+4
3. **Warm data** → Erasure coded, 1.4x overhead, O(1) reads maintained
4. **Automatic** → EC repair, vacuum, and bitrot scrub run via worker

---

## Step 8: Configure Data Recovery & PITR (Enterprise)

### Enable Deletion Retention

Add to the master configuration in your values.yaml:

```yaml
master:
  extraArgs:
    - "-master.deletionRetention=72h"    # 72 hours retention
```

Or configure via weed shell:
```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 <<< "server.config -deletionRetention=72h"
```

### Data Recovery Workflow

1. Accidental delete happens → bytes retained for 72h
2. Open Admin UI → Recovery → Data Recovery
3. Click Scan → filter by path/prefix/owner/time
4. Restore one file or batch restore

### Point-in-Time Recovery (PITR)

Configure in values.yaml:
```yaml
master:
  extraArgs:
    - "-master.deletionRetention=72h"
    - "-master.pointInTimeRecovery=true"
```

PITR allows restoring to any point within the retention window:
```
Scope: folder, bucket prefix, single object, or entire bucket
Action: Reconstruct state at time T, revert overwrites, restore deletes
Default: Safe side-copy (never touches live data)
```

---

## Step 9: Enable Iceberg REST Catalog for Paimon

SeaweedFS S3 gateway natively serves an Iceberg REST catalog. No separate catalog service needed.

### Paimon Configuration

```java
// Flink SQL
CREATE CATALOG paimon_catalog WITH (
  'type' = 'paimon',
  'warehouse' = 's3://paimon-datalake/',
  's3.endpoint' = 'http://seaweedfs-s3.seaweedfs.svc:8333',
  's3.access-key' = '<paimon-access-key>',
  's3.secret-key' = '<paimon-secret-key>',
  's3.path.style.access' = 'true'
);

// Iceberg REST Catalog (for Spark/Trino)
CREATE CATALOG iceberg_catalog WITH (
  'type' = 'iceberg',
  'catalog-type' = 'rest',
  'uri' = 'http://seaweedfs-s3.seaweedfs.svc:8333',
  'warehouse' = 's3://paimon-datalake/'
);
```

### Spark Configuration

```python
spark = SparkSession.builder \
    .appName("Paimon on SeaweedFS") \
    .config("spark.sql.catalog.paimon", "org.apache.paimon.spark.SparkCatalog") \
    .config("spark.sql.catalog.paimon.warehouse", "s3://paimon-datalake/") \
    .config("spark.sql.catalog.paimon.s3.endpoint", "http://seaweedfs-s3.seaweedfs.svc:8333") \
    .config("spark.sql.catalog.paimon.s3.access.key", "<paimon-access-key>") \
    .config("spark.sql.catalog.paimon.s3.secret.key", "<paimon-secret-key>") \
    .config("spark.sql.catalog.paimon.s3.path.style.access", "true") \
    .getOrCreate()
```

### Test Iceberg Catalog

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 <<< "s3.table.list"
```

---

## Step 10: Monitoring with Prometheus

### Enable ServiceMonitor

Update values.yaml:
```yaml
monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    namespace: monitoring
    interval: 30s
```

### Key Metrics to Monitor

| Metric | Alert Threshold | Description |
|--------|----------------|-------------|
| `seaweedfs_volume_server_available` | 0 | Volume server down |
| `seaweedfs_master_leader_change` | > 0/hour | Frequent Raft elections |
| `seaweedfs_volume_disk_usage_bytes` | > 80% | Disk filling up |
| `seaweedfs_filer_request_latency_seconds` | p99 > 1s | Filer slow |
| `seaweedfs_s3_request_latency_seconds` | p99 > 2s | S3 slow |
| `seaweedfs_ec_repair_pending` | > 0 | EC shards need repair |

### Grafana Dashboard

Import SeaweedFS dashboard: https://grafana.com/grafana/dashboards/seaweedfs

---

## Step 11: Backup Strategy

### Filer Metadata Backup

```bash
# Export filer metadata (snapshot)
kubectl -n seaweedfs exec -it seaweedfs-filer-0 -- \
  weed filer.export -filer=localhost:8888 -dir=/backup/metadata

# Backup to NFS/external storage
kubectl -n seaweedfs port-forward svc/seaweedfs-filer-client 8888:8888 &
curl -X POST http://localhost:8888/heartbeat -d '{"action":"export"}'
```

### Automated Backup CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: seaweedfs-backup
  namespace: seaweedfs
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: chrislusf/seaweedfs:4.47
            command:
            - /bin/sh
            - -c
            - |
              weed shell -master=seaweedfs-master:9333 \
                -filer=seaweedfs-filer:8888 \
                -filer.export -filer.exportInclude="" \
                -filer.exportExclude="" \
                -filer.exportPath=/backup
          restartPolicy: OnFailure
```

### K3s/RKE2 Cluster Backup Integration

For etcd/snapshot backup of the RKE2 cluster itself:
```bash
# Manual etcd snapshot
k3s etcd-snapshot save --name seaweedfs-$(date +%Y%m%d)

# Restore if needed
systemctl stop rke2-server
rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>
systemctl start rke2-server
```

---

## Step 12: Day-2 Operations

### Scale Volume Servers

```bash
# Increase replicas
helm upgrade seaweedfs seaweedfs/seaweedfs -n seaweedfs \
  -f seaweedfs-values.yaml \
  --set volume.replicas=3
```

### Rebalance Volumes

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 <<< "volume.balance"
```

### EC Maintenance

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 << 'EOF'
# Balance EC shards across racks
ec.balance

# Check EC status
ec.status

# Trigger vacuum on EC volumes
ec.vacuum
EOF
```

### Upgrade SeaweedFS

```bash
# Update helm repo
helm repo update seaweedfs

# Check current version
helm list -n seaweedfs

# Upgrade (zero-downtime for filer/S3 gateways)
helm upgrade seaweedfs seaweedfs/seaweedfs -n seaweedfs \
  -f seaweedfs-values.yaml

# Verify pods restarted
kubectl -n seaweedfs get pods -w
```

### Check Cluster Status

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 -filer localhost:8888 <<< "cluster.info"
```

---

## Appendix A: Node-to-Component Mapping

```
RKE2 Cluster — 6 Worker Nodes
┌─────────────────────────────────────────────────────────┐
│ Worker 1 (192.168.x.1)                                 │
│   └─ seaweedfs-master-0 (Leader)                       │
│       Port: 9333 (Raft)                                │
│       PVC: 1Gi (Raft state)                            │
├─────────────────────────────────────────────────────────┤
│ Worker 2 (192.168.x.2)                                 │
│   └─ seaweedfs-master-1 (Follower)                     │
│       Port: 9333 (Raft)                                │
│       PVC: 1Gi (Raft state)                            │
├─────────────────────────────────────────────────────────┤
│ Worker 3 (192.168.x.3)                                 │
│   └─ seaweedfs-master-2 (Follower)                     │
│       Port: 9333 (Raft)                                │
│       PVC: 1Gi (Raft state)                            │
├─────────────────────────────────────────────────────────┤
│ Worker 4 (192.168.x.4)                                 │
│   └─ seaweedfs-volume-0                                │
│       Ports: 8080 (HTTP), 9324 (Metrics)               │
│       PVC: 500Gi (data) + 50Gi (WAL)                   │
│   └─ seaweedfs-worker-0 (EC/Vacuum)                    │
├─────────────────────────────────────────────────────────┤
│ Worker 5 (192.168.x.5)                                 │
│   └─ seaweedfs-volume-1                                │
│       Ports: 8080 (HTTP), 9324 (Metrics)               │
│       PVC: 500Gi (data) + 50Gi (WAL)                   │
├─────────────────────────────────────────────────────────┤
│ Worker 6 (192.168.x.6)                                 │
│   └─ seaweedfs-filer-0                                 │
│       Ports: 8888 (HTTP), 18888 (gRPC)                 │
│       PVC: 50Gi (metadata)                             │
│   └─ seaweedfs-filer-1                                 │
│   └─ seaweedfs-s3-0                                    │
│       Ports: 8333 (S3 API)                             │
│   └─ seaweedfs-s3-1                                    │
└─────────────────────────────────────────────────────────┘

Port Summary:
  9333  — Master Raft API
  8080  — Volume Server HTTP
  8888  — Filer HTTP API
  18888 — Filer gRPC
  8333  — S3 API Gateway
  9324  — Metrics (Prometheus)
```

---

## Appendix B: values.yaml Reference

See the complete `seaweedfs-values.yaml` in Step 4. Key parameters:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `master.replicas` | 3 | Number of master servers |
| `volume.replicas` | 2 | Number of volume servers |
| `filer.replicas` | 2 | Number of filer servers |
| `s3.replicas` | 2 | Number of S3 gateways |
| `global.seaweedfs.enableReplication` | true | Enable replication for hot data |
| `global.seaweedfs.replicationPlacement` | "001" | 2 copies, different servers |
| `filer.s3.enableAuth` | true | Enable S3 authentication |
| `worker.enabled` | true | Enable EC/vacuum worker |

---

## Appendix C: Troubleshooting

### Pod stuck in Pending

```bash
# Check node labels
kubectl get nodes --show-labels | grep sw-backend
kubectl get nodes --show-labels | grep sw-volume

# Check PVC binding
kubectl -n seaweedfs get pvc
kubectl -n seaweedfs describe pvc <pvc-name>
```

### Master Raft split-brain

```bash
# Check master status
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 <<< "cluster.info"

# If masters disagree, check network connectivity between nodes
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  ping seaweedfs-master-1.seaweedfs-headless.seaweedfs.svc
```

### S3 connection refused

```bash
# Check S3 pod status
kubectl -n seaweedfs get pods -l app.kubernetes.io/component=s3

# Check S3 service
kubectl -n seaweedfs get svc | grep s3

# Test direct connection
kubectl -n seaweedfs exec -it seaweedfs-s3-0 -- \
  curl -s http://localhost:8333/
```

### Volume server full

```bash
# Check volume usage
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 <<< "volume.serverStatus"

# Add new volume server
helm upgrade seaweedfs seaweedfs/seaweedfs -n seaweedfs \
  -f seaweedfs-values.yaml \
  --set volume.replicas=3
```

### Enterprise license not active

```bash
# Check license status
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  curl -s localhost:9333/license/status

# Re-apply license
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 <<< "license.set -file=/etc/seaweedfs/license/seaweed-license.json"
```

---

## Appendix D: Enterprise License Activation

### Method 1: Helm Values (Recommended)

```yaml
global:
  seaweedfs:
    image:
      name: chrislusf/seaweedfs-enterprise
    license:
      existingSecret: seaweedfs-license
      secretKey: seaweed-license.json
      mountPath: /etc/seaweedfs/license
```

```bash
# Create the secret
kubectl create secret generic seaweedfs-license -n seaweedfs \
  --from-file=seaweed-license.json=/path/to/seaweed-license.json

# Upgrade Helm release
helm upgrade seaweedfs seaweedfs/seaweedfs -n seaweedfs \
  -f seaweedfs-values.yaml
```

### Method 2: weed shell (Runtime)

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  weed shell -master localhost:9333 <<< "license.set -file=/etc/seaweedfs/license/seaweed-license.json"
```

### Verify License

```bash
kubectl -n seaweedfs exec -it seaweedfs-master-0 -- \
  curl -s localhost:9333/license/status
```

Expected:
```json
{
  "licensed": true,
  "cluster_uuid": "...",
  "capacity_tb": 25,
  "features": ["data_recovery", "pitr", "self_healing", "ec_customizable", "ec_repair", "ec_vacuum"]
}
```

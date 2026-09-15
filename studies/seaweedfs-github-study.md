# SeaweedFS — GitHub Deep Study

> Source: https://github.com/seaweedfs/seaweedfs
> Study date: 2026-09-15
> Latest release: v4.47 (Sep 14, 2026) — 321 releases, 15,147 commits, 516 contributors

---

## Table of Contents

- [Project Overview](#project-overview)
- [Core Architecture](#core-architecture)
- [Key Features](#key-features)
- [S3 API Coverage](#s3-api-coverage)
- [S3 Tables & Lakehouse](#s3-tables--lakehouse)
- [Cloud Tiering & Caching](#cloud-tiering--caching)
- [Replication & HA](#replication--ha)
- [Filer Stores (Metadata Backends)](#filer-stores-metadata-backends)
- [Benchmark Numbers](#benchmark-numbers)
- [Quick Start Methods](#quick-start-methods)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Comparison vs Other Systems](#comparison-vs-other-systems)
- [Enterprise Edition](#enterprise-edition)
- [Rust Volume Server (Experimental)](#rust-volume-server-experimental)
- [Key Design Decisions](#key-design-decisions)

---

## Project Overview

- **Language**: Go (83.3%), Rust (8%), templ (3.1%), Java (2%)
- **License**: Apache 2.0
- **Stars**: 34.6K | Forks: 3.0K | Watchers: 526
- **Latest release**: v4.47 (Sep 14, 2026)
- **Total releases**: 321
- **Total commits**: 15,147
- **Contributors**: 516
- **Maintained by**: chrislusf (Chris Lu)
- **Tagline**: "SeaweedFS is a distributed storage system for object storage (S3), file systems, and Iceberg tables, designed to handle billions of files with O(1) disk access and effortless horizontal scaling."

One `weed` binary serves an S3 object store, a POSIX file system, and a lakehouse with S3 Tables, all over the same data.

---

## Core Architecture

Three main components:

1. **Master servers** — track which volume lives on which volume server, hand out file IDs. Run 1 for small clusters, 3 for Raft failover. NOT in the read path (clients cache volume-to-server mapping).

2. **Volume servers** — store blobs in append-only volume files. Keep a 16-byte in-memory index per blob. Each blob is one disk read. Replicate or erasure-code at volume level.

3. **Filer servers** — add directories and files on top of volumes. Metadata stored in configurable backend. Expose HTTP, S3, WebDAV, SFTP, FUSE, and table catalogs. Stateless and horizontally scalable.

Design lineage:
- Blob store from Facebook's Haystack paper
- Erasure coding from Facebook's f4 (Warm BLOB Storage)
- Similarities with Facebook's Tectonic Filesystem and Google's Colossus File System

Key architecture points:
- 40 bytes of metadata per file on disk
- Small files packed into append-only volume files (no per-file inode, no fragmentation)
- Hot data replicated; erasure coding applied to warm data in background
- Master tracks volumes, not files — even billions of files means only thousands of volumes

---

## Key Features

### Storage
- O(1) disk seek for any file size
- Files from 1 byte to tens of TB
- Volumes up to 8TB with large-disk build
- 40 bytes metadata per file (compact!)
- Tiered storage across disk types

### Access Protocols
- S3 API (object storage)
- POSIX FUSE mount (Linux, macOS, Windows)
- WebDAV
- SFTP
- HDFS compatible file system (for Spark, Flink, HBase)
- HTTP REST API
- TUS resumable uploads

### Security
- AES256-GCM encryption at rest
- TLS and mTLS between components
- JWT-signed volume access
- FIPS compliance builds
- SSE-S3, SSE-KMS, and SSE-C server-side encryption
- OpenBao/Vault, AWS KMS, Azure Key Vault, GCP KMS as key providers

### Operations
- Admin UI
- Prometheus metrics
- TTL per file or volume
- Automatic compression and compaction
- `seaweed-up` for bare-metal clusters

### Replication
- Active-active or active-passive cross-cluster continuous synchronization
- Rack and datacenter-aware replication
- Filer store replication for metadata HA
- Async backup to cloud storage
- Metadata backup
- Change data capture with webhooks

---

## S3 API Coverage

The S3 gateway implements:

| API Category | Operations Count |
|---|---|
| S3 bucket and object | 73 |
| S3 Tables | 36 |
| IAM | 39 |
| STS | 5 |

### Supported S3 Features
- Versioning
- Object Lock with retention and legal hold
- Lifecycle rules
- Tagging
- CORS
- Conditional reads and writes
- Checksums
- Presigned URLs
- Browser POST uploads
- Multipart uploads
- Atomic RenameObject

### IAM & Auth
- Bucket policies with conditions and variables
- IAM users, groups, and policies
- STS with OIDC, LDAP, and Kubernetes service accounts

### Encryption
- SSE-S3, SSE-KMS, SSE-C

### Other
- Audit log
- Bucket quota
- Rate limiting
- Each bucket is its own collection (instant bucket delete)

### vs MinIO S3 Coverage
The README explicitly states: "MinIO followed AWS S3 closely and was ideal for testing for S3 API. SeaweedFS is trying to catch up here."
- S3 compatibility suite runs in CI on every change
- SDK, IAM, SSE, policy, and Spark integration tests also in CI

---

## S3 Tables & Lakehouse

This is the most relevant feature for Paimon datalake use case:

### S3 Table Buckets
- Hold Apache Iceberg tables by default
- Also support Lance tables (vectors, multimodal data)
- Built-in Iceberg REST Catalog and Lance namespace
- **No Hive Metastore, Glue, or separate catalog service needed**

### Query Engine Support
- Spark, Trino, Dremio, DuckDB, Apache Doris, RisingWave, ClickHouse, LanceDB
- All operate on the same tables simultaneously
- Catalog commits are atomic compare-and-swap (concurrent writer safe)
- Lakekeeper integration for STS-vended credentials

### Automated Table Maintenance
- Compaction
- Snapshot expiration
- Orphan file removal
- Manifest rewriting
- Configured per bucket or table through S3 Tables maintenance APIs
- Runs on dedicated workers (off the query path)

### Hadoop Compatibility
- Hadoop compatible file system for Spark, Flink, and HBase

### Quick Start Lakehouse
```
S3_TABLE_BUCKET=warehouse ./weed mini -dir=./data
```
This brings up the entire stack including Iceberg REST catalog on a laptop.

---

## Cloud Tiering & Caching

### Cloud Drive
Mounts a bucket from S3, GCS, Azure, B2, Wasabi, Storj, etc. into SeaweedFS:
- Metadata pulled once (no cloud API calls for listing/stat)
- Content cached on first read or warmed by folder/pattern/size/age
- Local writes complete at local latency, async write-back to cloud
- Uncache by same rules to free disk while keeping metadata

### Cloud Tier
Moves warm volumes to cloud storage while keeping one-read access.

### Gateway to Remote Object Storage
Mirrors every bucket to a remote store. Faster and cheaper than reading cloud directly.

---

## Replication & HA

- Active-active or active-passive replication between clusters
- Continuous and resumable
- For whole tree or chosen folders, across data centers
- Filer store replication for metadata HA
- Async backup to cloud storage
- Metadata backup
- Change data capture with webhooks on every metadata event

---

## Filer Stores (Metadata Backends)

The Filer metadata can be stored in any of these:
- LevelDB, RocksDB, SQLite (embedded)
- MySQL, PostgreSQL, MemSQL, TiDB, CockroachDB
- Cassandra, HBase, MongoDB
- Redis, Elasticsearch
- etcd, FoundationDB, YDB, ArangoDB, Tarantool

This is a significant advantage — you can use a database you already run.

---

## Benchmark Numbers

### Single Machine (MacBook SSD, 1M 1KB files, concurrency 16)

| Operation | Requests/sec | p50 | p99 |
|---|---|---|---|
| Write | 15,708 | 0.8ms | 2.6ms |
| Random Read | 47,019 | 0.3ms | 0.7ms |

### S3 Warp Mixed Benchmark (single node)

| Operation | % | Throughput |
|---|---|---|
| GET | 45% | 2,477 MiB/s (247.75 obj/s) |
| PUT | 15% | 825 MiB/s (82.59 obj/s) |
| DELETE | 10% | 55.13 obj/s |
| STAT | 30% | 165.27 obj/s |
| **Total** | **100%** | **3,302 MiB/s (550.51 obj/s)** |

### From NHR2022 Academic Benchmark
- SeaweedFS and MinIO reach very high bandwidths with large objects
- For small objects, SeaweedFS exceeds even BeeGFS and WekaFS in objects/second
- "S3 based object stores all provide a consistent performance profile, but suitability for HPC depends strongly on data structure"

### Mixed workload with replication (4 bare metal machines)
- 2000 objects/s at ~200MB/s for content replication

---

## Quick Start Methods

### 1. One Command (Binary)
```bash
curl -fsSL https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/install.sh | bash
AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=secret S3_BUCKET=my-bucket ./weed mini -dir=./data
# S3 endpoint: http://localhost:8333
```

### 2. Docker
```bash
docker run -p 8333:8333 -v weed-data:/data \
  -e AWS_ACCESS_KEY_ID=admin \
  -e AWS_SECRET_ACCESS_KEY=secret \
  -e S3_BUCKET=my-bucket \
  chrislusf/seaweedfs
```

### 3. Docker Compose
```bash
wget https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/docker/seaweedfs-compose.yml
docker compose -f seaweedfs-compose.yml -p seaweedfs up
```

### 4. Build from Source
```bash
git clone https://github.com/seaweedfs/seaweedfs.git
cd seaweedfs/weed && make install
```

### 5. Scale Out
```bash
weed volume -dir=/data -master=<master_host>:9333
```
No rebalancing until asked. Throughput scales with volume servers and gateways.

---

## Kubernetes Deployment

### Helm Chart (Official)
```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm install seaweedfs seaweedfs/seaweedfs -n seaweedfs --create-namespace -f values.yaml
```

### Production values.yaml Example
```yaml
global:
  seaweedfs:
    enableReplication: true
    replicationPlacement: "001"   # one extra copy on another server

master:
  replicas: 3
  data:
    type: persistentVolumeClaim
    size: 1Gi

volume:
  replicas: 3
  dataDirs:
    - name: data
      type: persistentVolumeClaim
      size: 500Gi
      maxVolumes: 0

filer:
  replicas: 2
  data:
    type: persistentVolumeClaim
    size: 20Gi

s3:
  enabled: true
  replicas: 2
  enableAuth: true
  credentials:
    admin:
      accessKey: admin
      secretKey: change-me
  createBuckets:
    - name: app-storage
```

### Other K8s Options
- **SeaweedFS Operator**: helm repo add seaweedfs-operator https://seaweedfs.github.io/seaweedfs-operator/
- **CSI Driver**: Dynamic PV provisioning
- **Bitnami Helm chart**: helm install my-release oci://registry-1.docker.io/bitnamicharts/seaweedfs

---

## Comparison vs Other Systems

### vs HDFS
- HDFS: ideal for large files, chunk approach
- SeaweedFS: ideal for smaller files, concurrent access. Can store extra large files by splitting into manageable chunks.

### vs GlusterFS, Ceph
| Feature | SeaweedFS | GlusterFS | Ceph |
|---|---|---|---|
| File Metadata | Lookup volume id (cacheable) | Hashing | Hashing + rules |
| File Content Read | O(1) disk seek | — | — |
| POSIX | Via Filer | FUSE, NFS | FUSE |
| REST API | Yes | No | Yes |
| Optimized for small files | Yes | No | No |

### vs MinIO, RustFS
MinIO/RustFS weaknesses:
- Metadata in separate meta files per drive per file → write amplification
- No optimization for lots of small files
- Multiple disk IOs needed to read one file (vs SeaweedFS O(1))
- Erasure coding is full-time (vs SeaweedFS: hot=replicated, warm=EC)
- No POSIX-like API
- Storage layout requirements make scaling harder

### vs Ceph
- SeaweedFS: centralized master for volume lookup (simpler to code/manage)
- Ceph: CRUSH hashing (efficient but wrong config = data loss, topology changes = high IO migration)
- SeaweedFS: assigns data to any writable volumes (simple, flexible)
- SeaweedFS Filer uses off-the-shelf stores (MySQL, Postgres, Redis, etc.)

---

## Enterprise Edition

Available at seaweedfs.com with:
- Advanced data recovery
- Self-healing storage
- Customizable erasure coding
- EC vacuum and repair
- Priority support
- Free for dev/test under 25TB
- Enterprise licensing: $2/TB/month or $20/TB/year

---

## Rust Volume Server (Experimental)

The repo has a `VOLUME_SERVER_RUST_PLAN.md` and 8% Rust code. The Rust volume server is positioned as:
- Drop-in replacement for higher throughput
- Lower tail latency
- Same on-disk format as Go volume server

This is different from RustFS — this is SeaweedFS's own Rust optimization for the volume server component.

---

## Key Design Decisions

1. **Append-only volume files** — no fragmentation, SSD-friendly, writes never pay EC cost
2. **16-byte in-memory index per blob** — O(1) lookup, works even for billions of files
3. **Master not in read path** — clients cache volume mapping, master scales easily
4. **Configurable metadata store** — use whatever you already run
5. **Hot/warm data tiering** — replication for speed, EC for cost, background migration
6. **Single binary (`weed`)** — serves S3, POSIX, Iceberg tables, WebDAV, etc.
7. **Each bucket = own collection** — instant delete, clean isolation
8. **Iceberg REST catalog built-in** — no separate catalog service needed
9. **Stateless filer/S3 gateways** — scale linearly behind load balancer
10. **No data reshuffle on scale-out** — add a volume server and it just works

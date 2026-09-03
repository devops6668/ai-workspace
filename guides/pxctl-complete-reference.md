# Portworx pxctl Complete CLI Reference

> **Version:** Portworx Enterprise 3.6+
> **Source:** [Official Docs](https://docs.portworx.com/portworx-enterprise/reference/cli/pxctl-reference)

---

## Table of Contents

- [1. Basics](#1-basics)
- [2. Volume Management](#2-volume-management)
  - [2.1 Create Volume](#21-create-volume)
  - [2.2 List Volumes](#22-list-volumes)
  - [2.3 Inspect Volume](#23-inspect-volume)
  - [2.4 Delete Volume](#24-delete-volume)
  - [2.5 Update Volume](#25-update-volume)
  - [2.6 Update Replication (HA)](#26-update-replication-ha)
  - [2.7 Snapshots](#27-snapshots)
  - [2.8 Clone](#28-clone)
  - [2.9 Import](#29-import)
  - [2.10 Stats & Usage](#210-stats--usage)
  - [2.11 Locate](#211-locate)
  - [2.12 Volume Access Rules](#212-volume-access-rules)
  - [2.13 Filesystem Check](#213-filesystem-check)
  - [2.14 Trim / Auto-fstrim](#214-trim--auto-fstrim)
  - [2.15 Checksum Verification](#215-checksum-verification)
  - [2.16 Attach / Mount (Docker mode)](#216-attach--mount-docker-mode)
- [3. Cluster Management](#3-cluster-management)
  - [3.1 List Nodes](#31-list-nodes)
  - [3.2 Inspect Node](#32-inspect-node)
  - [3.3 Delete Node](#33-delete-node)
  - [3.4 Cluster Domains (Metro DR)](#34-cluster-domains-metro-dr)
  - [3.5 Provision Status](#35-provision-status)
  - [3.6 Token Management](#36-token-management)
  - [3.7 Cluster Pair](#37-cluster-pair)
  - [3.8 Cluster Options (Global Settings)](#38-cluster-options-global-settings)
  - [3.9 Defrag Schedule](#39-defrag-schedule)
- [4. CloudSnap Backup / Restore](#4-cloudsnap-backup--restore)
  - [4.1 Backup to Cloud](#41-backup-to-cloud)
  - [4.2 Group Backup](#42-group-backup)
  - [4.3 Restore from Cloud](#43-restore-from-cloud)
  - [4.4 List Cloud Backups](#44-list-cloud-backups)
  - [4.5 Backup Status](#45-backup-status)
  - [4.6 Backup History](#46-backup-history)
  - [4.7 Stop Backup](#47-stop-backup)
  - [4.8 Delete Cloud Backup](#48-delete-cloud-backup)
  - [4.9 Backup Catalog](#49-backup-catalog)
  - [4.10 Backup Schedules](#410-backup-schedules)
- [5. Cloud Credentials](#5-cloud-credentials)
- [6. Alerts](#6-alerts)
- [7. Secrets](#7-secrets)
- [8. Auth & Role](#8-auth--role)
- [9. CloudDrive](#9-clouddrive)
- [10. CloudMigrate](#10-cloudmigrate)
- [11. Scheduling Policy](#11-scheduling-policy)
- [12. Storage Policy](#12-storage-policy)
- [13. Upgrade](#13-upgrade)
- [14. License](#14-license)
- [15. Context](#15-context)
- [16. Kubedatastore](#16-kubedatastore)
- [17. Service](#17-service)
- [18. EULA](#18-eula)
- [Quick Reference: Common Scenarios](#quick-reference-common-scenarios)

---

## 1. Basics

Run `pxctl` commands from any worker node or via `kubectl exec`:

```bash
# From worker node
pxctl --version
pxctl --help
pxctl status

# Via kubectl (from anywhere with cluster access)
PX_POD=$(kubectl get pods -l name=portworx -n <namespace> -o jsonpath='{.items[0].metadata.name}')
kubectl exec $PX_POD -n <namespace> -- /opt/pwx/bin/pxctl <command>
```

> **Note:** Default binary path is `/opt/pwx/bin/pxctl`. All commands support `--json` flag for machine-parsable output.

---

## 2. Volume Management

### 2.1 Create Volume

```bash
# Basic
pxctl volume create <name>

# With size and replication
pxctl volume create -s 100 -r 3 myVol

# High IO priority
pxctl volume create -s 10 -r 3 --io_priority high myVol

# Specific filesystem with formatting options
pxctl volume create -s 10 --fs ext4 --fs_format_options "-i 8192" myVol
pxctl volume create -s 10 --fs xfs --fs_format_options "-q -i size=1024" myVol

# Place replica on local node
pxctl volume create --nodes=LocalNode localVol

# Shared volume (global namespace)
pxctl volume create --shared myVol

# Sharedv4 volume
pxctl volume create --sharedv4 myVol

# Encrypted volume
pxctl volume create --secure --secret_key mykey myVol

# With labels
pxctl volume create -s 10 -r 3 --label "app=mysql,env=prod" myVol

# With snapshot schedule
pxctl volume create -s 10 --periodic 60,5 --daily 00:00,7 myVol
```

**Key Flags:**

| Flag | Description | Default |
|------|-------------|---------|
| `-s, --size` | Volume size in GB | `1` |
| `-r, --repl` | Replication factor (1-3) | `1` |
| `--io_priority` | `high` / `medium` / `low` | `low` |
| `--io_profile` | `db_remote` / `auto` / `none` / `journal` / `auto_journal` / `use_cluster_default` | `use_cluster_default` |
| `--fs` | Filesystem: `ext4` or `xfs` | `ext4` |
| `--shared` | Global shared namespace volume | `false` |
| `--sharedv4` | Export via Sharedv4 | `false` |
| `--sharedv4_service_type` | `ClusterIP` or empty | - |
| `--secure` | AES-256 encryption | `false` |
| `--secret_key` | Encryption secret key name | - |
| `--use_cluster_secret` | Use cluster-wide secret | `false` |
| `--journal` | Enable journal data | `false` |
| `--early_ack` | Async write ack after shared mem copy | `false` |
| `--async_io` | Async IO to backing storage | `false` |
| `--nodiscard` | Disable discard support | `false` |
| `--fastpath` | Enable fastpath IO | `false` |
| `--sticky` | Prevent deletion until disabled | `false` |
| `--nodes` | Comma-separated Node IDs or Pool UUIDs | - |
| `--zones` | Comma-separated Zone names | - |
| `--racks` | Comma-separated Rack names | - |
| `-l, --label` | Key=value labels | - |
| `-a, --aggregation_level` | `1` / `2` / `3` / `auto` | `1` |
| `-b, --block_size` | Block size in bytes | `4096` |
| `-q, --queue_depth` | Queue depth (1-256) | `128` |
| `--scale` | Auto-scale max (1-1024) | `1` |
| `-p, --periodic` | Periodic snapshot `mins,k` | - |
| `-d, --daily` | Daily snapshot `hh:mm,k` | - |
| `-w, --weekly` | Weekly snapshot `weekday@hh:mm,k` | - |
| `-m, --monthly` | Monthly snapshot `day@hh:mm,k` | - |
| `--mount_options` | Mount options key=value | - |
| `--storagepolicy` | Storage policy name | - |
| `--max_iops` | Max IOPS `ReadIOPS,WriteIOPS` | - |
| `--max_bandwidth` | Max bandwidth MB/s `ReadBW,WriteBW` | - |
| `--readahead` | Enable readahead | `false` |
| `--cow_ondemand` | On-demand COW | `true` |
| `--direct_io` | Enable Direct IO | `false` |
| `--policy` | Policy names (comma-separated) | - |
| `--proxy_endpoint` | Proxy endpoint `protocol://endpoint` | - |

---

### 2.2 List Volumes

```bash
pxctl volume list                                    # All volumes
pxctl volume list --all                              # Include snapshots
pxctl volume list --name myVol                       # Filter by name
pxctl volume list --node <nodeID>                    # Filter by node
pxctl volume list --snapshot                         # Snapshots only
pxctl volume list --volumes                          # Volumes only (no snapshots)
pxctl volume list --group <groupID>                  # Filter by group
pxctl volume list --label color=blue                 # Filter by label
pxctl volume list --trashcan                         # Trash can volumes
pxctl volume list --time                             # Sort by creation time
pxctl volume list --cloud-drive-id <id>              # Filter by cloud drive
pxctl volume list --pool-uid <uid>                   # Filter by storage pool
pxctl volume list --parent <volID>                   # Snapshots of a volume
pxctl volume list --snapshot-schedule                # Scheduled snapshots
pxctl volume list --sched-policy <policy>            # Filter by sched policy
```

---

### 2.3 Inspect Volume

```bash
pxctl volume inspect <volID/name>
```

---

### 2.4 Delete Volume

```bash
pxctl volume delete <volID/name>                     # Prompts Y/N confirmation
```

---

### 2.5 Update Volume

```bash
# Resize (must attach first)
pxctl host attach <volName>
pxctl host mount --path /mnt/vol <volName>
pxctl volume update <volName> --size=5

# Enable/disable sharedv4
pxctl volume update <volName> --sharedv4=on
pxctl volume update <volName> --sharedv4=off

# Sticky (prevent deletion)
pxctl volume update <volName> --sticky=on
pxctl volume update <volName> --sticky=off

# IO settings
pxctl volume update <volName> --io_priority high
pxctl volume update <volName> --io_profile db
pxctl volume update <volName> --max_iops 1000,1000
pxctl volume update <volName> --max_bandwidth 200,200

# Labels and groups
pxctl volume update <volName> --label "color=red"
pxctl volume update <volName> --group <groupName>

# Other options
pxctl volume update <volName> --sharedv4_failover_strategy=normal
pxctl volume update <volName> --readahead on
pxctl volume update <volName> --fastpath
pxctl volume update <volName> --cow_ondemand on
pxctl volume update <volName> --async_io on
pxctl volume update <volName> --nodiscard on
pxctl volume update <volName> --journal on
pxctl volume update <volName> --queue_depth 256
pxctl volume update <volName> --sharedv4_mount_options "ro"
```

---

### 2.6 Update Replication (HA)

> **Note:** Maximum replication factor is 3. New repl = current + 1 (increase) or current - 1 (decrease).

```bash
# Increase replication
pxctl volume ha-update --repl=2 --node <nodeID/poolUUID/nodeIP> <volName>

# Decrease replication
pxctl volume ha-update --repl=1 --node <nodeID/poolUUID/nodeIP> <volName>

# Cancel operation
pxctl volume ha-update --cancel <volName>

# With source node
pxctl volume ha-update --repl=2 --node <target> --sources <source> <volName>

# By zone/rack
pxctl volume ha-update --repl=2 --zones zone1 <volName>
pxctl volume ha-update --repl=2 --racks rack1 <volName>

# Best effort
pxctl volume ha-update --repl=2 --node <node> --best_effort_location_provisioning <volName>
```

---

### 2.7 Snapshots

```bash
# Create snapshot
pxctl volume snapshot create --name mysnap --label color=blue <volName>

# Restore from snapshot (volume must be detached)
pxctl volume restore --snapshot mysnap <volName>

# Restore from trash can
pxctl volume restore --trashcan trashedvol <volName>

# Update snapshot schedule
pxctl volume snap-interval-update --periodic 60,5 <volName>    # Every 60 mins, keep 5
pxctl volume snap-interval-update --daily 00:00,7 <volName>     # Daily at midnight, keep 7
pxctl volume snap-interval-update --weekly Sunday@00:00,4 <volName>
pxctl volume snap-interval-update --monthly 1@00:00,12 <volName>
pxctl volume snap-interval-update --periodic 0 <volName>        # Disable all scheduled snaps
```

> **Limit:** 64 snapshots per volume. Snapshots are read-only.

---

### 2.8 Clone

```bash
pxctl volume clone -name myvol_clone myvol
```

---

### 2.9 Import

```bash
pxctl volume import --src /path/to/files myVol
```

---

### 2.10 Stats & Usage

```bash
pxctl volume stats <volName>                          # Real-time IO throughput
pxctl volume usage <volName>                          # Space usage
```

---

### 2.11 Locate

```bash
pxctl volume locate <volID>                           # Mount locations in containers
```

---

### 2.12 Volume Access Rules

```bash
pxctl volume access show <volName>
pxctl volume access add <volName> --group group1:r
pxctl volume access add <volName> --collaborator user1Id:w
pxctl volume access add <volName> --public r
pxctl volume access remove <volName> --collaborator user1Id
pxctl volume access remove <volName> --public
pxctl volume access update <volName> --groups group1:r,group2:w --collaborators user1Id:a
```

---

### 2.13 Filesystem Check

```bash
pxctl volume check start --mode fix_safe <volName>
pxctl volume check start --mode check_health <volName>
pxctl volume check start --mode fix_all <volName>
pxctl volume check stop <volName>
pxctl volume check status <volName>
```

**Modes:**

| Mode | Description |
|------|-------------|
| `check_health` | Read-only health check |
| `fix_safe` | Fix only safe issues |
| `fix_all` | Fix all issues (may cause data loss) |

---

### 2.14 Trim / Auto-fstrim

```bash
# Manual trim
pxctl volume trim start <volName>
pxctl volume trim stop <volName>
pxctl volume trim status
pxctl volume trim usage

# Auto fstrim
pxctl volume autofstrim status <volName>
pxctl volume autofstrim usage
pxctl volume autofstrim push <volName>
pxctl volume autofstrim pop <volName>
```

---

### 2.15 Checksum Verification

```bash
pxctl volume verify-checksum start <volName>
pxctl volume verify-checksum stop <volName>
pxctl volume verify-checksum status <volName>
```

---

### 2.16 Attach / Mount (Docker mode)

```bash
pxctl host attach <volName>
pxctl host detach <volName>
pxctl host mount --path /mount/path <volName>
pxctl host unmount /mount/path
```

---

## 3. Cluster Management

### 3.1 List Nodes

```bash
pxctl cluster list
```

---

### 3.2 Inspect Node

```bash
pxctl cluster inspect <nodeID>
```

---

### 3.3 Delete Node

```bash
pxctl cluster delete <nodeID>
pxctl cluster delete --force <nodeID>                 # May cause data loss
```

---

### 3.4 Cluster Domains (Metro DR)

```bash
pxctl cluster domains show
pxctl cluster domains activate --name <domain>
pxctl cluster domains deactivate --name <domain>
```

---

### 3.5 Provision Status

```bash
pxctl cluster provision-status
```

---

### 3.6 Token Management

```bash
pxctl cluster token show
pxctl cluster token reset
```

---

### 3.7 Cluster Pair

```bash
# Create pair
pxctl cluster pair create --ip <remoteIP> --token <token> --default
pxctl cluster pair create --ip <remoteIP> --token <token> --dr-mode

# Manage pairs
pxctl cluster pair list
pxctl cluster pair validate --id <pairID>
pxctl cluster pair delete --id <pairID>
```

---

### 3.8 Cluster Options (Global Settings)

```bash
pxctl cluster options list                            # List all options
pxctl cluster options update --<option> <value>       # Update option
```

**Common Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--auto-decommission-timeout` | Auto-decommission timeout (minutes) | `20` |
| `--internal-snapshot-interval` | Internal snapshot interval (minutes) | `30` |
| `--snapshot-create-timeout` | Snapshot creation timeout (minutes) | `20` |
| `--default-rpc-timeout` | Default RPC timeout (minutes) | `5` |
| `--repl-move-timeout` | Replica move timeout (minutes) | `1440` |
| `--license-expiry-check` | License expiry alert (days), 0=disable | `7` |
| `--license-expiry-check-interval` | License check interval | `6h` |
| `--cloudsnap-max-threads` | Cloudsnap thread count (2-16) | `16` |
| `--cloudsnap-err-retry-limit` | Cloudsnap retry limit (1-15) | `3` |
| `--sharedv4-threads` | Sharedv4 initial threads | `128` |
| `--max-sharedv4-threads` | Sharedv4 max threads | `2048` |
| `--sharedv4-mount-timeout-sec` | Sharedv4 mount timeout (seconds) | `120` |
| `--sharedv4-attachment-limit` | Sharedv4 max attachments per node | `256` |
| `--cache-flush` | Periodic cache flush `enabled`/`disabled` | `disabled` |
| `--cache-flush-seconds` | Cache flush interval (seconds) | `30` |
| `--auto-fstrim` | Auto fstrim `on`/`off` | `off` |
| `--fstrim-schedule-start` | Fstrim schedule `daily=hh:mm` | - |
| `--fstrim-schedule-duration` | Fstrim duration (hours) | - |
| `--fstrim-max-io-rate` | Fstrim max IO rate | `32MiB` |
| `--fstrim-min-io-rate` | Fstrim min IO rate | `1MiB` |
| `--defrag-schedule-chunk-size` | Defrag chunk size (MB, 10-1024) | `32` |
| `--skinnysnap` | SkinnySnaps `on`/`off` | `off` |
| `--skinnysnap-num-repls` | SkinnySnap repl factor (1-3) | `1` |
| `--cloud-drive-locking` | Cloud drive locking `true`/`false` | - |
| `--pause-pool-failovers` | Pause pool failovers `true`/`false` | - |
| `--pause-dynamic-pool-rebalance` | Pause dynamic rebalance `true`/`false` | - |
| `--volume-expiration-minutes` | Trash can expiration (minutes) | - |
| `--concurrent-api-limit` | Max concurrent API calls | `20` |
| `--cloudsnap-catalog` | Cloudsnap catalog `on`/`off` | `off` |
| `--cloudsnap-full-backup-frequency` | Full backup frequency (1-120) | `7` |
| `--cloudsnap-nw-interface` | Network interface for cloudsnap | - |
| `--diag-redaction-enabled` | Secret redaction in diags `true`/`false` | `true` |
| `--optimized-restores` | Optimized restores `on`/`off` | `off` |
| `--default-io-profile` | Default IO profile `auto`/`none` | `none` |
| `--domain-policy` | Domain policy `strict`/`eventual` | `strict` |
| `--stats-dump-interval-seconds` | Stats dump interval (30-3600) | `120` |
| `--readahead` | Readahead `on`/`off` | `on` |
| `--poolcache` | Pool cache `disabled` or `on,min,max` | `disabled` |

---

### 3.9 Defrag Schedule

```bash
# Create schedule
pxctl cluster defrag schedule create \
  --start-time daily=19:15 \
  --max-duration-minutes 90

# With node/volume filters
pxctl cluster defrag schedule create \
  --start-time weekly=Sunday@19:15 \
  --max-duration-minutes 120 \
  --max-nodes-in-parallel 2 \
  --node-selector "rack=rack1" \
  --exclude-volumes "vol1,vol2"

# One-shot (auto-deletes after one iteration)
pxctl cluster defrag schedule create \
  --start-time daily=19:15 \
  --max-duration-minutes 60 \
  --one-iteration-only

# Manage schedules
pxctl cluster defrag schedule show
pxctl cluster defrag schedule show --schedule-id <id>
pxctl cluster defrag schedule delete <scheduleID>
pxctl cluster defrag schedule clean-up
pxctl cluster defrag status --node <nodeUUID>
```

**Schedule Flags:**

| Flag | Description | Default |
|------|-------------|---------|
| `--start-time` | `daily=hh:mm` / `weekly=weekday@hh:mm` / `monthly=day@hh:mm` | **Required** |
| `--max-duration-minutes` | Duration per job | **Required** |
| `--max-nodes-in-parallel` | Max parallel nodes | `1` |
| `--include-nodes` | Specific node UUIDs | - |
| `--exclude-nodes` | Exclude node UUIDs | - |
| `--node-selector` | Label selectors `label1=val1,label2=val2` | - |
| `--one-iteration-only` | Auto-delete after one run | `false` |
| `--include-volumes` | Specific volume IDs | - |
| `--exclude-volumes` | Exclude volume IDs | - |

---

## 4. CloudSnap Backup / Restore

### 4.1 Backup to Cloud

```bash
pxctl cloudsnap backup <volName>
pxctl cloudsnap backup --full <volName>               # Force full backup
pxctl cloudsnap backup --delete-local <volName>       # Delete local snap after backup
pxctl cloudsnap backup --cred-id <credID> <volName>
pxctl cloudsnap backup --label "env=prod" <volName>
pxctl cloudsnap backup --frequency 7 <volName>        # Full after 7 incrementals
```

---

### 4.2 Group Backup

```bash
pxctl cloudsnap backup-group --volume_ids "vol1,vol2,vol3"
pxctl cloudsnap backup-group --group <groupID>
pxctl cloudsnap backup-group --label "env=prod"
pxctl cloudsnap backup-group --full --cred-id <credID> --volume_ids "vol1,vol2"
```

---

### 4.3 Restore from Cloud

```bash
# Basic restore
pxctl cloudsnap restore --volume <newVolName> --snap <cloudsnapID>

# With options
pxctl cloudsnap restore --repl 3 --io_priority high --volume <vol> --snap <snapID>
pxctl cloudsnap restore --cred-id <credID> --volume <vol> --snap <snapID>

# Location constraints
pxctl cloudsnap restore --nodes <nodeID> --zones <zone> --racks <rack> --volume <vol> --snap <snapID>

# Match source provisioning
pxctl cloudsnap restore --match_src_vol_provisioning --volume <vol> --snap <snapID>

# Sharedv4
pxctl cloudsnap restore --sharedv4 --volume <vol> --snap <snapID>

# Encrypted volume
pxctl cloudsnap restore --secret_key <key> --volume <vol> --snap <snapID>

# With snapshot schedule
pxctl cloudsnap restore --periodic 60,5 --daily 00:00,7 --volume <vol> --snap <snapID>
```

**Restore Flags:**

| Flag | Description | Default |
|------|-------------|---------|
| `-v, --volume` | New volume name | **Required** |
| `-s, --snap` | Cloudsnap ID | **Required** |
| `--cred-id` | Cloud credentials ID | - |
| `-r, --repl` | Replication factor (1-3) | `1` |
| `--io_priority` | `high` / `medium` / `low` | `low` |
| `-l, --label` | Key=value labels | - |
| `-q, --queue_depth` | Queue depth (1-256) | `128` |
| `-a, --aggregation_level` | `1` / `2` / `3` / `auto` | `1` |
| `--nodes` | Node/Pool IDs | - |
| `--zones` | Zone names | - |
| `--racks` | Rack names | - |
| `--match_src_vol_provisioning` | Match source pool | `false` |
| `--best_effort_location_provisioning` | Optional location constraints | `false` |
| `--storagepolicy` | Storage policy name | - |
| `--journal` | Enable journal | - |
| `--nodiscard` | Disable discard | - |
| `--io_profile` | `sequential` / `db` / `db_remote` | `sequential` |
| `--sticky` | Sticky volume | - |
| `-g, --group` | Group ID | - |
| `--enforce_cg` | Enforce consistency group | `false` |
| `--shared` | Shared volume | - |
| `--sharedv4` | Sharedv4 volume | - |
| `--fastpath` | Enable fastpath | - |
| `--secret_key` | Decryption key | - |

---

### 4.4 List Cloud Backups

```bash
pxctl cloudsnap list                                     # All backups
pxctl cloudsnap list --src <volName>                     # For specific volume
pxctl cloudsnap list --all                               # All clusters
pxctl cloudsnap list --deleted-source-vol                # Deleted source volumes
pxctl cloudsnap list --status failed                     # Failed backups
pxctl cloudsnap list --status aborted                    # Aborted backups
pxctl cloudsnap list --paginate                          # Paginated output
pxctl cloudsnap list --max 10                            # Limit per page
pxctl cloudsnap list --cloudsnap-id <id>                 # Single backup
pxctl cloudsnap list --label "env=prod"                  # Filter by label
pxctl cloudsnap list --cred-id <credID>                  # Filter by credential
pxctl cloudsnap list --migration                         # Migration backups
pxctl cloudsnap list --cluster <clusterID>               # Specific cluster
```

---

### 4.5 Backup Status

```bash
pxctl cloudsnap status                                    # All active tasks
pxctl cloudsnap status --name <taskName>                  # Specific task
pxctl cloudsnap status --src <volName>                    # For specific volume
pxctl cloudsnap status --local                            # Node-local only
```

---

### 4.6 Backup History

```bash
pxctl cloudsnap history
pxctl cloudsnap history --src <volName>
```

---

### 4.7 Stop Backup

```bash
pxctl cloudsnap stop --name <taskName>
```

---

### 4.8 Delete Cloud Backup

```bash
pxctl cloudsnap delete --snap <cloudsnapID>
pxctl cloudsnap delete --snap <id> --cred-id <credID>
```

---

### 4.9 Backup Catalog

```bash
pxctl cloudsnap catalog --snap <cloudsnapID>
```

---

### 4.10 Backup Schedules

```bash
# Create schedule
pxctl cloudsnap schedules create \
  --periodic 60 --max 7 --retention 30 \
  --cred-id <credID> <volName>

# With daily/weekly/monthly
pxctl cloudsnap schedules create \
  --daily 00:00 --weekly Sunday@00:00 --monthly 1@00:00 <volName>

# Full backup always
pxctl cloudsnap schedules create --full --periodic 60 <volName>

# List schedules
pxctl cloudsnap schedules list

# Update schedule
pxctl cloudsnap schedules update -i <uuid> --periodic 120 --max 14

# Delete schedule
pxctl cloudsnap schedules delete --uuid <uuid>
```

**Schedule Flags:**

| Flag | Description | Default |
|------|-------------|---------|
| `-x, --max` | Max cloudsnaps to maintain | `7` |
| `-r, --retention` | Retention period (days) | - |
| `-f, --full` | Force full backups | `false` |
| `-p, --periodic` | Interval in minutes | - |
| `-d, --daily` | `hh:mm` (UTC) | - |
| `-w, --weekly` | `weekday@hh:mm` (UTC) | - |
| `-m, --monthly` | `day@hh:mm` (UTC) | - |
| `--cred-id` | Cloud credentials ID | - |

---

## 5. Cloud Credentials

```bash
# List credentials
pxctl credentials list

# Validate
pxctl credentials validate <uuid/name>

# Delete
pxctl credentials delete <uuid/name>

# Clean up pending KVDB refs
pxctl credentials delete-refs <name>
```

### AWS S3 (Access Key)

```bash
pxctl credentials create \
  --provider s3 \
  --s3-access-key <YOUR-SECRET-ACCESS-KEY> \
  --s3-secret-key <YOUR-ACCESS-KEY-ID> \
  --s3-region us-east-1 \
  --s3-endpoint s3.amazonaws.com \
  --s3-storage-class STANDARD \
  --bucket <BUCKET-NAME> \
  <NAME>
```

### AWS S3 (IAM)

```bash
pxctl credentials create \
  --provider s3 \
  --s3-region us-east-1 \
  --s3-storage-class STANDARD \
  --use-iam \
  <NAME>
```

### AWS S3 (SSE Encryption)

```bash
pxctl credentials create \
  --provider s3 \
  --s3-access-key <KEY> \
  --s3-secret-key <SECRET> \
  --s3-region us-east-1 \
  --s3-sse AES256 \
  <NAME>

# Or with aws:kms
pxctl credentials create \
  --provider s3 \
  --s3-access-key <KEY> \
  --s3-secret-key <SECRET> \
  --s3-region us-east-1 \
  --s3-sse aws:kms \
  <NAME>
```

### Azure

```bash
pxctl credentials create \
  --provider azure \
  --azure-account-name <STORAGE-ACCOUNT> \
  --azure-account-key <KEY> \
  <NAME>
```

### Google Cloud

```bash
pxctl credentials create \
  --provider google \
  --google-project-id <PROJECT-ID> \
  --google-json-key-file /path/to/gcloud.json \
  --bucket <BUCKET-NAME> \
  <NAME>
```

### Workload Identity (v3.4+)

```bash
pxctl credentials create <name> \
  --provider <provider> \
  --use-workload-identity

# Azure (v3.6.1+)
pxctl cred create <name> \
  --provider <provider> \
  --azure-account-name <account> \
  --use-workload-identity

# GCP (v3.6.2+)
pxctl cred create <name> \
  --provider <provider> \
  --google-project-id <project-id> \
  --use-workload-identity
```

---

## 6. Alerts

```bash
# Show alerts
pxctl alerts show                                           # All
pxctl alerts show --type volume                             # Volume type
pxctl alerts show --type node                               # Node type
pxctl alerts show --type cluster                            # Cluster type
pxctl alerts show --type drive                              # Drive type
pxctl alerts show --type pool                               # Pool type
pxctl alerts show --type all                                # All types
pxctl alerts show --severity alarm                          # Alarm and above
pxctl alerts show --severity warn                           # Warning and above
pxctl alerts show --severity notify                         # Notify and above
pxctl alerts show --id <alertID>                            # By alert ID
pxctl alerts show --resource <name>                         # By resource
pxctl alerts show --is-cleared false                        # Uncleared only
pxctl alerts show --start-time 2024-01-01T00:00:00Z         # From time
pxctl alerts show --end-time 2024-01-31T23:59:59Z           # Until time
pxctl alerts show --out alerts.csv                          # Export to CSV

# Purge alerts (same filters as show)
pxctl alerts purge --type all -y                            # Auto-confirm
pxctl alerts purge --type volume --severity warn

# Alert info
pxctl alerts info
```

---

## 7. Secrets

### Vault

```bash
pxctl secrets vault login \
  --vault-address http://myvault.myorg.com \
  --vault-token <myvaulttoken>
```

### AWS KMS

```bash
pxctl secrets aws login
# Interactive prompts:
#   Enter AWS_ACCESS_KEY_ID
#   Enter AWS_SECRET_ACCESS_KEY
#   Enter AWS_SECRET_TOKEN_KEY
#   Enter AWS_CMK
#   Enter AWS_REGION
```

### KVDB (Default)

```bash
pxctl secrets kvdb login
```

---

## 8. Auth & Role

```bash
# Login
pxctl auth login --cred <credID>

# Role management
pxctl role create <roleName>
pxctl role delete <roleName>
pxctl role list
pxctl role inspect <roleName>
```

---

## 9. CloudDrive

```bash
pxctl clouddrive list                                       # List cloud drives
pxctl clouddrive inspect <driveID>                          # Drive details
```

---

## 10. CloudMigrate

```bash
# Start migration
pxctl cloudmigrate start --volume <volID> --target-cluster <clusterID>
pxctl cloudmigrate start --volume <volID> --target-cred <credID>

# Status
pxctl cloudmigrate status
pxctl cloudmigrate status --volume <volID>

# Stop migration
pxctl cloudmigrate stop --volume <volID>
```

---

## 11. Scheduling Policy

```bash
pxctl sched-policy list
pxctl sched-policy inspect <policyName>
```

---

## 12. Storage Policy

```bash
pxctl storage-policy list
pxctl storage-policy inspect <policyName>
```

---

## 13. Upgrade

```bash
pxctl upgrade --tag <version> <containerName>

# Example
pxctl upgrade --tag 2.13.0 my-px-enterprise
```

> **Warning:** Upgrade nodes in a **staggered manner** to maintain quorum and IO continuity.

---

## 14. License

```bash
pxctl license show                                          # Show current license
pxctl license update <licenseKey>                           # Update license
```

---

## 15. Context

```bash
pxctl context list                                          # List contexts
pxctl context set <contextName>                             # Switch context
pxctl context delete <contextName>                          # Delete context
```

---

## 16. Kubedatastore

```bash
pxctl kubedatastore set
pxctl kubedatastore status
```

---

## 17. Service

```bash
pxctl service restart                                       # Restart PX service
pxctl service status                                        # Service status
```

---

## 18. EULA

```bash
pxctl eula                                                  # Show EULA link
```

---

## Quick Reference: Common Scenarios

### Daily Health Check

```bash
pxctl status                          # Overall health
pxctl cluster list                    # Node status
pxctl volume list                     # Volume status
pxctl alerts show --type all          # Alerts
pxctl cloudsnap status                # Backup progress
```

### Create Encrypted HA Volume

```bash
pxctl volume create -s 100 -r 3 \
  --io_priority high \
  --secure \
  --secret_key mykey \
  --fs ext4 \
  --label "app=mysql,env=prod" \
  mysql-data
```

### Auto Backup Schedule

```bash
pxctl cloudsnap schedules create \
  --periodic 60,5 \
  --daily 00:00,7 \
  --weekly Sunday@00:00,4 \
  --monthly 1@00:00,12 \
  --cred-id <credID> \
  mysql-data
```

### Cross-Cluster Migration

```bash
# 1. Pair clusters
pxctl cluster pair create --ip <remoteIP> --token <token> --default

# 2. Start migration
pxctl cloudmigrate start --volume <volID> --target-cluster <clusterID>

# 3. Monitor
pxctl cloudmigrate status
```

### Troubleshooting

```bash
pxctl alerts show --type all --severity warn       # Check warnings
pxctl volume inspect <problemVol>                  # Volume details
pxctl volume stats <problemVol>                    # IO stats
pxctl cluster inspect <nodeID>                     # Node details
```

---

> **Official Docs:** https://docs.portworx.com/portworx-enterprise/reference/cli/pxctl-reference

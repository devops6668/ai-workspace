# K3s Backup & Restore Guide

> K3s v1.33.0+k3s1 | SQLite Datastore | NFS Backup Storage

## Overview

K3s backup strategy depends on the datastore type:

| Datastore | Backup Method |
|-----------|--------------|
| SQLite (default) | Copy DB files directly |
| Embedded etcd | `k3s etcd-snapshot` commands |
| External (PostgreSQL/MySQL) | Database-level backup |

This guide covers **SQLite** and **Embedded etcd** scenarios.

---

## Environment

| Item | Value |
|------|-------|
| K3s Version | v1.33.0+k3s1 |
| Node | rancher (192.168.89.61) |
| Datastore | SQLite (default) |
| Backup Storage | NFS 192.168.89.188:/volume1/NFS/k3s-backup |
| Mount Point | /mnt/k3s-backup |

---

## 1. NFS Setup

### Mount NFS Share

```bash
# Create mount point
sudo mkdir -p /mnt/k3s-backup

# Mount NFS
sudo mount -t nfs 192.168.89.188:/volume1/NFS/k3s-backup /mnt/k3s-backup

# Verify
df -h /mnt/k3s-backup
```

### Auto-mount on Boot (fstab)

```bash
echo 'nfs-server:/volume1/NFS/k3s-backup /mnt/k3s-backup nfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab
```

> **Note:** NFS export path on NAS is `/volume1/NFS`, not `/NFS`.
> Use `showmount -e 192.168.89.188` to verify exports.

---

## 2. Backup — SQLite Datastore

### Critical Files to Backup

| File | Purpose |
|------|---------|
| `/var/lib/rancher/k3s/server/db/state.db` | Main SQLite database |
| `/var/lib/rancher/k3s/server/db/state.db-shm` | Shared memory file |
| `/var/lib/rancher/k3s/server/db/state.db-wal` | Write-ahead log |
| `/var/lib/rancher/k3s/server/token` | Server token (used for encryption) |

> ⚠️ **The token file is critical.** It derives the AES-256 key used to encrypt
> sensitive data in the datastore. Without the same token, a restored snapshot
> will be unusable.

### Manual Backup

```bash
BACKUP_DIR="/mnt/k3s-backup/$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p "$BACKUP_DIR"

# Copy SQLite DB
sudo cp /var/lib/rancher/k3s/server/db/state.db "$BACKUP_DIR/"
sudo cp /var/lib/rancher/k3s/server/db/state.db-shm "$BACKUP_DIR/"
sudo cp /var/lib/rancher/k3s/server/db/state.db-wal "$BACKUP_DIR/"

# Copy token
sudo cp /var/lib/rancher/k3s/server/token "$BACKUP_DIR/"

# Verify
ls -lh "$BACKUP_DIR/"
```

### Automated Backup Script

Script installed at `/usr/local/bin/k3s-backup.sh`:

```bash
#!/bin/bash
# k3s SQLite backup to NFS
# Usage: k3s-backup.sh [backup_dir]
# Default backup dir: /mnt/k3s-backup

set -euo pipefail

BACKUP_ROOT="${1:-/mnt/k3s-backup}"
K3S_DB="/var/lib/rancher/k3s/server/db"
K3S_TOKEN="/var/lib/rancher/k3s/server/token"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION=7  # 保留最近幾日備份

# 檢查 NFS mount
if ! mountpoint -q "$BACKUP_ROOT"; then
    echo "ERROR: $BACKUP_ROOT is not mounted"
    exit 1
fi

# 建立備份目錄
mkdir -p "$BACKUP_DIR"

# 複製 DB（用 cp 避免 SQLite lock 問題）
cp "${K3S_DB}/state.db" "$BACKUP_DIR/"
cp "${K3S_DB}/state.db-shm" "$BACKUP_DIR/"
cp "${K3S_DB}/state.db-wal" "$BACKUP_DIR/"

# 複製 token
cp "$K3S_TOKEN" "$BACKUP_DIR/"

# 寫備份資訊
cat > "$BACKUP_DIR/backup-info.txt" << EOF
k3s Backup
==========
Date:        $(date '+%Y-%m-%d %H:%M:%S')
Hostname:    $(hostname)
K3s Version: $(k3s --version 2>/dev/null || echo "unknown")
DB Type:     SQLite
EOF

# 清理舊備份（保留最近 RETENTION 日）
find "$BACKUP_ROOT" -maxdepth 1 -type d -name '20*' -mtime +$RETENTION -exec rm -rf {} \;

echo "Backup completed: $BACKUP_DIR"
ls -lh "$BACKUP_DIR/"
```

### Cron Schedule

```bash
# Daily at 3:00 AM
0 3 * * * /usr/local/bin/k3s-backup.sh >> /var/log/k3s-backup.log 2>&1
```

Check logs:

```bash
tail -f /var/log/k3s-backup.log
```

---

## 3. Backup — Embedded etcd Datastore

If `--etcd` is enabled, use `k3s etcd-snapshot` instead.

### Auto Snapshots (Default)

K3s takes snapshots every 12 hours (00:00, 12:00), retaining 5 by default.

| Flag | Description | Default |
|------|-------------|---------|
| `--etcd-snapshot-schedule-cron` | Cron schedule | `0 */12 * * *` |
| `--etcd-snapshot-retention` | Snapshots to keep | 5 |
| `--etcd-snapshot-dir` | Storage path | `${data-dir}/db/snapshots` |
| `--etcd-snapshot-compress` | Enable compression | false |

### Manual Snapshot

```bash
# Create snapshot
k3s etcd-snapshot save --name manual-$(date +%Y%m%d-%H%M%S)

# List snapshots
k3s etcd-snapshot ls

# Delete specific snapshot
k3s etcd-snapshot delete <snapshot-name>

# Prune old snapshots (keep 3)
k3s etcd-snapshot prune --snapshot-retention 3
```

### S3 Backup (Disaster Recovery)

```bash
k3s etcd-snapshot save \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --etcd-s3-access-key=AKIA... \
  --etcd-s3-secret-key=*** \
  --etcd-s3-region=us-east-1
```

### S3 via Secret (Recommended)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: k3s-etcd-snapshot-s3-config
  namespace: kube-system
type: etcd.k3s.cattle.io/s3-config-secret
stringData:
  etcd-s3-access-key: "AKIA..."
  etcd-s3-secret-key: "***"
  etcd-s3-bucket: "my-k3s-backups"
  etcd-s3-region: "us-east-1"
```

Start K3s with:

```bash
k3s server --etcd-s3 --etcd-s3-config-secret=k3s-etcd-snapshot-s3-config
```

> **Note:** S3 Config Secret cannot be used during restore (apiserver not available).

### View Snapshots Remotely

```bash
kubectl get etcdsnapshotfile
kubectl describe etcdsnapshotfile <name>
```

---

## 4. Restore — SQLite Datastore

### Steps

```bash
# 1. Stop k3s
sudo systemctl stop k3s

# 2. Backup current DB (just in case)
sudo mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.old.$(date +%Y%m%d-%H%M%S)

# 3. Restore from backup
BACKUP_DIR="/mnt/k3s-backup/<timestamp>"
sudo cp "$BACKUP_DIR/state.db" /var/lib/rancher/k3s/server/db/
sudo cp "$BACKUP_DIR/state.db-shm" /var/lib/rancher/k3s/server/db/
sudo cp "$BACKUP_DIR/state.db-wal" /var/lib/rancher/k3s/server/db/

# 4. Restore token
sudo cp "$BACKUP_DIR/token" /var/lib/rancher/k3s/server/token
sudo chmod 600 /var/lib/rancher/k3s/server/token

# 5. Start k3s
sudo systemctl start k3s

# 6. Verify
sudo systemctl status k3s
kubectl get nodes
kubectl get pods -A
```

### Cross-node Restore (New Server)

```bash
# On new node:
# 1. Copy snapshot + token from old node
scp old-node:/mnt/k3s-backup/<timestamp>/* /tmp/k3s-restore/

# 2. Stop k3s if running
sudo systemctl stop k3s

# 3. Restore
sudo cp /tmp/k3s-restore/state.db* /var/lib/rancher/k3s/server/db/
sudo cp /tmp/k3s-restore/token /var/lib/rancher/k3s/server/token

# 4. Start k3s
sudo systemctl start k3s
```

---

## 5. Restore — Embedded etcd Datastore

### Steps

```bash
# 1. Stop k3s
sudo systemctl stop k3s

# 2. Restore from local snapshot
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>

# 3. Start k3s
sudo systemctl start k3s
```

### Restore from S3

```bash
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<snapshot-filename> \
  --etcd-s3 \
  --etcd-s3-bucket=my-k3s-backups \
  --etcd-s3-access-key=AKIA... \
  --etcd-s3-secret-key=***
```

> **Note:** Version compatibility — restore with equal or higher minor version is OK.

---

## 6. Security Considerations

Snapshots contain:

- ✗ Complete etcd/SQLite datastore
- ✗ Cluster CA certificates and private keys
- ✗ Secrets encryption keys (if enabled)

All sensitive data is encrypted with AES-256 key derived from the server token via PBKDF2.

**Recommendations:**

1. Store snapshots on S3 with server-side encryption
2. Restrict access via filesystem permissions and bucket policies
3. Keep token file secure — it's the encryption key
4. Validate backup integrity periodically

---

## 7. Quick Reference

| Action | SQLite | etcd |
|--------|--------|------|
| Manual backup | Copy DB files | `k3s etcd-snapshot save` |
| List backups | `ls /mnt/k3s-backup/` | `k3s etcd-snapshot ls` |
| Delete backup | `rm -rf /path/to/backup` | `k3s etcd-snapshot delete <name>` |
| Restore | Copy files back, restart k3s | `k3s server --cluster-reset --cluster-reset-restore-path=...` |
| Auto backup | Cron + script | Built-in scheduler |

---

## References

- [K3s Backup & Restore](https://docs.k3s.io/datastore/backup-restore)
- [k3s etcd-snapshot CLI](https://docs.k3s.io/cli/etcd-snapshot)

# NodeDiskIOSaturation 故障排查指南

## Alert 背景

`NodeDiskIOSaturation` 是 Prometheus 常見告警，表示某個磁碟的 I/O 利用率接近 100%。
典型來源：`node_disk_io_time_seconds_total` 或類似指標。

## 排查流程（通用公式）

```
Alert 觸發
    ↓
iostat    →  邊個碟好忙？
    ↓
iotop     →  邊個進程搞事？
    ↓
pidstat   →  交叉驗證（confirm）
    ↓
/proc/PID →  佢做緊咩？（配置）
    ↓
mount/ls  →  數據喺邊？（存儲）
    ↓
結論
```

---

## 第一步：快速睇整體 I/O 狀態

```bash
iostat -x 1 3
```

**參數解釋：**

| 參數 | 作用 |
|------|------|
| `-x` | extended stats，顯示 %util、r_await 等關鍵指標 |
| `1` | 每 1 秒採樣一次 |
| `3` | 顯示 3 次 |

**點睇結果：**

```
Device    r/s    rkB/s    w/s    wkB/s   %util
sda       0.00   0.00     0.00   0.00    0.00%     ← 內置碟，冇事
sdb       1589   426596   65     628     95.40%    ← 外置 SSD，爆咗
```

**關鍵欄位：**

| 欄位 | 意義 | 正常範圍 |
|------|------|----------|
| `%util` | 碟嘅繁忙程度 | < 80% 正常，> 90% 警告 |
| `r/s` | 每秒讀操作次數 | 視乎碟 |
| `rkB/s` | 每秒讀幾多 KB | 視乎碟 |
| `w/s` | 每秒寫操作次數 | 視乎碟 |
| `wkB/s` | 每秒寫幾多 KB | 視乎碟 |
| `r_await` | 每次讀要等幾耐 (ms) | < 5ms 正常，> 30ms 有問題 |
| `w_await` | 每次寫要等幾耐 (ms) | < 5ms 正常，> 30ms 有問題 |
| `aqu-sz` | I/O 排隊深度 | < 1 正常，> 2 有瓶頸 |

---

## 第二步：搵邊個進程食 I/O

### 方法 A：iotop（推薦）

```bash
iotop -b -o -n 3
```

**參數解釋：**

| 參數 | 作用 |
|------|------|
| `-b` | batch mode，非互動式，適合腳本 |
| `-o` | 只顯示有 I/O 嘅進程（唔 show 冇 I/O 嘅） |
| `3` | 採樣 3 次 |

**輸出範例：**

```
Total DISK READ:       377.29 M/s | Total DISK WRITE:         658.09 K/s
    TID  PRIO  USER   DISK READ   DISK WRITE  COMMAND
 151083 be/4  paul   377.29 MB/s  509.84 KB/s prometheus   ← 罪魁禍首
   3403 be/4  root   0.00 B/s     516.00 KB/s k3s-server
   921  be/3  root   0.00 B/s     148.00 KB/s jbd2/sdb1-8
```

### 方法 B：pidstat

```bash
pidstat -d 1 5
```

**參數解釋：**

| 參數 | 作用 |
|------|------|
| `-d` | 顯示 I/O 統計 |
| `1` | 每 1 秒採樣 |
| `5` | 採樣 5 次 |

**輸出範例：**

```
Average: UID   PID      kB_rd/s    kB_wr/s   Command
1000     151083 384350.79    24.60    prometheus   ← 確認咗
0        3403   12.70        299.21   k3s-server
```

**為什麼要交叉驗證？**

iotop 和 pidstat 係獨立採樣嘅兩個工具，如果佢哋顯示嘅數字一致，就表示結果可靠。如果唔一致，可能係採樣時間差或者工具版本問題。

---

## 第三步：追溯數據來源

搵到進程後，就要問：佢讀緊咩數據？點解要讀？

### 查看進程配置

```bash
cat /proc/<PID>/cmdline | tr '\0' ' '
```

**範例：**

```
prometheus --storage.tsdb.path=/prometheus \
           --storage.tsdb.retention.time=3d \
           --storage.tsdb.retention.size=10GiB \
           --storage.tsdb.wal-compression
```

### 理解 I/O 類型

| 操作類型 | 說明 | I/O 特性 |
|----------|------|----------|
| TSDB Compaction | 合併舊數據塊 | 大量讀取 + 寫入 |
| Query | 查詢歷史數據 | 隨機讀取 |
| WAL Recovery | 崩潰後恢復 | 大量讀取 |
| Scrape | 每次抓取 metrics | 頻繁小量寫入 |

---

## 第四步：確認數據喺邊個碟

### 查看掛載點

```bash
mount | grep <設備名>
```

**範例：**

```bash
mount | grep sdb
# /dev/sdb1 on /media/paul/ext-256G-SSD type ext4 (rw,relatime)
# /dev/sdb1 on /var/lib/kubelet/pods/.../pvc-xxx type ext4 (rw,relatime)
```

### 查看數據大小

```bash
du -sh /path/to/data/
ls -la /path/to/data/
```

### K8s Local Volume 對應

```bash
# 查看 PVC 對應嘅 local volume
ls /media/paul/ext-256G-SSD/k3s/storage/
# → 見到 pvc-xxx_cattle-monitoring-system_prometheus-rancher-monitoring-prometheus-0
```

---

## 實戰案例：Prometheus TSDB on External SSD

### Alert 觸發

- Alert: `NodeDiskIOSaturation`
- 磟: sdb (外置 256GB SSD)
- %util: 95.40%

### 排查過程

1. **iostat** → sdb %util=95%，rkB/s=426,596 (~417 MB/s)
2. **iotop** → prometheus 佔 384 MB/s (90%+)
3. **pidstat** → 確認 PID 151083 (prometheus) 384 MB/s
4. **/proc/PID/cmdline** → TSDB compaction, retention 3d/10GB
5. **mount + du** → 4.8GB TSDB data 喺外置 SSD

### 根因

Prometheus TSDB compaction 讀取所有舊 block → 合併 → 寫回。
外置 SSD 讀取速度受限，導致 %util 飆升。

### 解決方案

| 方案 | 優點 | 缺點 |
|------|------|------|
| 移 TSDB 到內置碟 | 效能好 | 需要重新部署 |
| 減少 scrape interval | 減少數據量 | 可能 miss metrics |
| 增加 block 打包大小 | 減少 compaction 頻率 | 需要修改配置 |
| 接受 compaction 峰值 | 零改動 | Alert 可能重複觸發 |

---

## 常見 I/O 瓶頸場景

| 場景 | 特徵 | 處理 |
|------|------|------|
| TSDB compaction | 定期高讀取，幾分鐘後恢復 | 正常行為，考慮調整 retention |
| WAL recovery | 崩潰後大量讀取 | 檢查 pod 為何崩潰 |
| Log flooding | 持續高寫入 | 檢查 logging level |
| Backup/restore | 批次高 I/O | 排到低峰時段 |
| DB migration | 大量讀寫 | 監控進度，考慮 throttle |

---

## 參考命令速查

```bash
# 快速診斷
iostat -x 1 3                    # 碟級別
iotop -b -o -n 3                  # 進程級別
pidstat -d 1 5                    # 交叉驗證

# 詳細檢查
cat /proc/<PID>/cmdline | tr '\0' ' '   # 進程配置
mount | grep <設備>                      # 掛載點
du -sh /path/to/data/                    # 數據大小
ls -la /path/to/data/                    # 目錄結構

# K8s 環境
kubectl get pods -o wide          # 查看 pod 分佈
kubectl describe pod <pod>        # 查看 pod 詳情
kubectl get pvc                  # 查看 PVC 狀態
```

---

## 參考

- [node-exporter: Disk I/O](https://prometheus.io/docs/guides/node-exporter/)
- [Linux I/O Monitoring with iostat](https://www.tecmint.com/linux-iostat-command-examples/)
- [Prometheus TSDB Compaction](https://prometheus.io/docs/practices/storage/)

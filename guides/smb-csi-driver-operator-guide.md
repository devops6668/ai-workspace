# SMB CSI Driver Operator - OCP 使用指南

> 適用於 OpenShift Container Platform 4.x

> 架構圖: [smb-csi-architecture.html](smb-csi-architecture.html) (用瀏覽器打開)

## Table of Contents

- [架構圖](#架構圖)
- [概述](#概述)
- [前置條件](#前置條件)
- [安裝 Operator](#安裝-operator)
- [建立 ClusterCSIDriver CR](#建立-clustercsidriver-cr)
- [動態 Provisioning (推薦)](#動態-provisioning-推薦)
  - [Step 1: 建立 Secret](#step-1-建立-secret)
  - [Step 2: 建立 StorageClass](#step-2-建立-storageclass)
  - [Step 3: 建立 PVC](#step-3-建立-pvc)
  - [Step 4: 使用 PVC (Deployment 範例)](#step-4-使用-pvc-deployment-範例)
- [靜態 Provisioning (掛載已有 SMB Share)](#靜態-provisioning-掛載已有-smb-share)
  - [建立 PV](#建立-pv)
  - [建立 PVC](#建立-pvc-1)
- [StorageClass 參數參考](#storageclass-參數參考)
- [Network 不穩定最佳實踐](#network-不穩定最佳實踐)
  - [問題](#問題)
  - [SMB CSI Driver 嘅 mountOptions 限制](#smb-csi-driver-嘅-mountoptions-限制)
  - [解決方案（SMB CSI 支援範圍內）](#解決方案smb-csi-支援範圍內)
  - [推薦 StorageClass (SMB CSI 支援版)](#推薦-storageclass-smb-csi-支援版)
  - [Deployment 完整範例 (Network 不穩定版)](#deployment-完整範例-network-不穩定版)
  - [Node Stage 說明](#node-stage-說明)
- [限制](#限制)
- [Troubleshooting](#troubleshooting)
- [參考資料](#參考資料)

---

## 架構圖

> 用瀏覽器打開: [smb-csi-architecture.html](smb-csi-architecture.html)

架構包含以下組件：

- **Application Pod** — 你嘅 workload，透過 PVC 掛載 SMB share
- **PersistentVolumeClaim** — 動態 provisioning 時由 StorageClass 自動建立
- **StorageClass (smb)** — 定義 SMB server source + Secret 認證
- **Secret (smbcreds)** — SMB 帳號密碼，provisioner 同 node stage 都會用
- **Controller Deployment** — 包含 csi-provisioner, csi-resizer, liveness-probe, kube-rbac-proxy
- **Node DaemonSet** — 每個 node 一個 pod，負責 CIFS mount
- **SMB Server** — 外部 Samba/Windows Server，提供 CIFS/SMB share
- **ClusterCSIDriver CR** — Operator 嘅入口，定義 `smb.csi.k8s.io`

### 流量說明

1. Application Pod 透過 PVC 請求 storage
2. Provisioner 根據 StorageClass 嘅 `source` 參數喺 SMB server 上建立 subdirectory
3. Node DaemonSet 喺每個 node 上做 CIFS mount
4. Provisioner 同 node stage 都會用 Secret 做認證
5. Operator 監聽 ClusterCSIDriver CR，自動 reconcile 所有資源

---

## 概述

CIFS/SMB CSI Driver Operator 提供對 SMB/CIFS 網路共享嘅動態及靜態 provision。安裝後會喺 `openshift-cluster-csi-drivers` namespace 部署 controller 同 node driver。

**重要：Operator 安裝後唔會自動建立 StorageClass，你要自己建。**

### Operator 會建立嘅資源

| 資源類型 | Namespace | 說明 |
|---------|-----------|------|
| Deployment (controller) | openshift-cluster-csi-drivers | provisioner + resizer + liveness probe |
| DaemonSet (node) | openshift-cluster-csi-drivers | node-driver-registrar + liveness probe |
| ClusterCSIDriver | cluster-wide | smb.csi.k8s.io driver registration |
| RBAC (ServiceAccount, ClusterRole, Binding) | openshift-cluster-csi-drivers | operator + driver 所需權限 |

---

## 前置條件

- OCP 4.15+ (Operator 版本 >= 5.0.0)
- 已有 SMB Server (Samba v4.21+ 或 Windows Server 2019/2022)
- SMB Server 可從 OCP cluster 內部連接 (hostname 或 IP 可解析)
- 已有 SMB share 同對應嘅認證帳戶

---

## 安裝 Operator

### 方法 1: Web Console

1. 去 **Ecosystem → Software Catalog**
2. 搜尋 **CIFS/SMB CSI**
3. 點擊 **CIFS/SMB CSI Driver Operator**
4. 點擊 **Install**
5. 設定：
   - **All namespaces on the cluster (default)** ✅
   - **Installed Namespace**: `openshift-cluster-csi-drivers`
6. 點擊 **Install**

### 方法 2: CLI

```bash
# 建立 OperatorGroup (如果冇嘅話)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers
  namespace: openshift-cluster-csi-drivers
spec:
  targetNamespaces:
  - openshift-cluster-csi-drivers
EOF

# 建立 Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: smb-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  name: smb-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# 等待 operator pod 起嚟
oc get pods -n openshift-cluster-csi-drivers -w
# 應該見到 smb-csi-driver-operator-xxxxx 變成 Running
```

---

## 建立 ClusterCSIDriver CR

安裝完 operator 之後，要建立 ClusterCSIDriver CR 先可以啟用：

```bash
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: smb.csi.k8s.io
spec:
  managementState: Managed
EOF
```

### 驗證

```bash
# 確認 controller deployment 已建立
oc get deployment -n openshift-cluster-csi-drivers | grep smb
# smb-csi-driver-controller   1/1     1            1           60s

# 確認 node daemonset 已建立
oc get daemonset -n openshift-cluster-csi-drivers | grep smb
# smb-csi-driver-node   3         3         3       3            3           <none>          60s

# 確認 CSI driver 已註冊
oc get csidriver | grep smb
# smb.csi.k8s.io   true            true            false       60s
```

---

## 動態 Provisioning (推薦)

動態 provisioning 會自動喺 SMB server 上建立 subdirectory 作為 PV。

### Step 1: 建立 Secret

建立一個 Secret 儲存 SMB 帳號密碼：

```bash
oc create secret generic smbcreds \
  --from-literal=username=<SMB帳號> \
  --from-literal=password='<SMB密碼>' \
  -n <target-namespace>
```

範例：

```bash
oc create secret generic smbcreds \
  --from-literal=username=admin \
  --from-literal=password='P@ssw0rd!' \
  -n default
```

### Step 2: 建立 StorageClass

```yaml
# smb-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb
provisioner: smb.csi.k8s.io
parameters:
  # SMB server UNC path: //<hostname>/<share>
  source: //smb-server.example.com/share
  # Provisioner 認證
  csi.storage.k8s.io/provisioner-secret-name: smbcreds
  csi.storage.k8s.io/provisioner-secret-namespace: default
  # Node Stage 認證 (每個 node mount 時用)
  csi.storage.k8s.io/node-stage-secret-name: smbcreds
  csi.storage.k8s.io/node-stage-secret-namespace: default
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1001
  - gid=1001
  - noperm
  - mfsymlinks
  - cache=strict
  - noserverino
```

```bash
oc apply -f smb-storageclass.yaml
```

### Step 3: 建立 PVC

```yaml
# pvc-smb.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-smb
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: smb
```

```bash
oc apply -f pvc-smb.yaml

# 確認 PVC 已 Bound
oc get pvc pvc-smb
# NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# pvc-smb   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   10Gi       RWX            smb            10s
```

### Step 4: 使用 PVC (Deployment 範例)

```yaml
# deployment-smb.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-smb
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-smb
  template:
    metadata:
      labels:
        app: nginx-smb
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: nginx
        image: quay.io/centos/centos:stream8
        command:
          - "/bin/bash"
          - "-c"
          - |
            set -euo pipefail
            while true; do
              echo "$(date) - test from nginx-smb" >> /mnt/smb/outfile
              sleep 1
            done
        volumeMounts:
          - name: smb-volume
            mountPath: /mnt/smb
            readOnly: false
      volumes:
        - name: smb-volume
          persistentVolumeClaim:
            claimName: pvc-smb
```

```bash
oc apply -f deployment-smb.yaml

# 驗證掛載
oc exec -it <pod_name> -- df -h | grep smb
# //smb-server.example.com/share   97G   21G   77G  22% /mnt/smb

# 驗證寫入
oc exec -it <pod_name> -- cat /mnt/smb/outfile
```

---

## 靜態 Provisioning (掛載已有 SMB Share)

如果你已經有一個 SMB share，唔想用動態 provision，可以手動建 PV。

### 建立 PV

```yaml
# pv-smb-static.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: smb.csi.k8s.io
  name: pv-smb-static
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - dir_mode=0777
    - file_mode=0777
  csi:
    driver: smb.csi.k8s.io
    # volumeHandle 格式: {server-address}#{sub-dir}#{share-name}
    # 必須喺整個 cluster 入面唯一
    volumeHandle: smb-server.default.svc.cluster.local/share
    volumeAttributes:
      source: //smb-server.example.com/share
    nodeStageSecretRef:
      name: smbcreds
      namespace: default
```

```bash
oc apply -f pv-smb-static.yaml
```

### 建立 PVC

```yaml
# pvc-smb-static.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-smb-static
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  storageClassName: ""
  volumeName: pv-smb-static
```

```bash
oc apply -f pvc-smb-static.yaml

# 確認 Bound
oc get pvc pvc-smb-static
```

---

## StorageClass 參數參考

| 參數 | 說明 | 範例 |
|------|------|------|
| `source` | SMB server UNC path | `//smb-server/share` |
| `csi.storage.k8s.io/provisioner-secret-name` | Secret name (provisioner 用) | `smbcreds` |
| `csi.storage.k8s.io/provisioner-secret-namespace` | Secret namespace | `default` |
| `csi.storage.k8s.io/node-stage-secret-name` | Secret name (node stage 用) | `smbcreds` |
| `csi.storage.k8s.io/node-stage-secret-namespace` | Secret namespace | `default` |

### mountOptions 常用設定

| Option | 說明 |
|--------|------|
| `dir_mode=0777` | 目錄權限 |
| `file_mode=0777` | 檔案權限 |
| `uid=1001` | 掛載後嘅 UID |
| `gid=1001` | 掛載後嘅 GID |
| `noperm` | 關閉 client 端權限檢查 |
| `mfsymlinks` | SMB 符號連結支援 |
| `cache=strict` | 嚴格 cache 模式 |
| `noserverino` | **必須加**，防止 inode 重複導致資料損壞 |

### reclaimPolicy

| 值 | 行為 |
|----|------|
| `Delete` | PVC 刪除後，自動刪除 SMB server 上嘅 subdirectory |
| `Retain` | PVC 刪除後保留 share，需手動清理 |

---

## Network 不穩定最佳實踐

> SMB server 本身穩定，但中間 network 唔穩定（時斷時連）。呢個 section 解決 kernel SMB mount hang 住 Pod / node 嘅問題。

### 問題

Network 斷線時，kernel 嘅 CIFS mount 會 block 住 Pod 嘅 I/O。預設 `hard` mount 會等好耐（`timeo` 預設 700 = 70 秒）先 timeout，期間 Pod 嘅 process 完全 hang，可能影響 node 上面其他 workload。

### SMB CSI Driver 嘅 mountOptions 限制

> **重要：** SMB CSI driver (`smb.csi.k8s.io`) 嘅 StorageClass `mountOptions` **只接受 CIFS mount flags**，唔接受 `mount.cifs` 層面嘅選項。
>
> 呢個意味住 `soft`, `timeo`, `reconnect`, `actimeo` **全部唔可以用**——放咗入去會導致 PVC pending，因為 driver reject 咗呢啲 options。

支援嘅 mountOptions 類型：

| 類型 | 範例 | 狀態 |
|------|------|------|
| CIFS mount flags | `dir_mode`, `file_mode`, `uid`, `gid`, `vers`, `nounix`, `noserverino` | ✅ 支援 |
| mount.cifs 選項 | `soft`, `timeo`, `reconnect`, `actimeo`, `hard` | ❌ 唔支援，PVC pending |

> 你實測確認咗 `timeo=50` 同 `reconnect` 會導致 PVC pending。呢個係 driver 嘅已知限制，唔係 StorageClass 設定問題。

### 解決方案（SMB CSI 支援範圍內）

既然 `soft`/`timeo` 唔可以用，你要靠 **Application 層面** 同 **Pod 層面** 嚟保護：

**1. Pod liveness probe 偵測 I/O 卡死**

Network 斷線時 I/O hang，liveness probe 偵測到並自動重啟 Pod：

```yaml
livenessProbe:
  exec:
    command:
      - /bin/bash
      - -c
      - "touch /mnt/smb/liveness-check && rm -f /mnt/smb/liveness-check"
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  exec:
    command:
      - /bin/bash
      - -c
      - "test -w /mnt/smb"
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 2
```

> **liveness probe** 用 `touch + rm` 測試 mount 是否可寫。`timeoutSeconds: 5` 確保 probe 唔會 hang。`failureThreshold: 3` 即連續 3 次失敗先重啟。
>
> **readiness probe** 用 `test -w` 測試 mount 是否可寫。斷線時 Pod 會先被移出 Service，避免流量打到 hang 嘅 Pod。

**2. Application 加 timeout / retry**

你嘅 application 自己要做 I/O timeout 處理，例如：
- 寫入操作加 timeout
- 讀取操作加 retry logic
- 用 `O_NONBLOCK` 或 async I/O

**3. 隔離 workload**

SMB workload 只 scheduling 到 worker node，唔好影響 control plane：

```yaml
nodeSelector:
  node-role.kubernetes.io/workload: ""
tolerations:
  - key: "node-role.kubernetes.io/worker"
    operator: "Exists"
    effect: "NoSchedule"
resources:
  limits:
    memory: 128Mi
    cpu: 250m
  requests:
    memory: 64Mi
    cpu: 50m
```

Resource limits 確保即使 I/O hang，Pod 都唔會耗盡 node 資源。

**4. 如果需要 `soft`/`timeo` 控制**

如果真係需要控制 kernel SMB mount timeout，有兩個選擇：

- **Static provisioning (PV)**：喺 PV 嘅 `spec.mountOptions` 加，因為 PV 不經過 CSI driver 嘅 validation
- **Node 級別設定**：喺 OCP node 上面設 `/etc/samba/smb.conf` 全局 mount options（但呢個影響所有 SMB mount）

> **Static PV 範例（可以加 soft/timeo）：**
>
> ```yaml
> apiVersion: v1
> kind: PersistentVolume
> metadata:
>   name: pv-smb-static
> spec:
>   mountOptions:
>     - soft
>     - timeo=50
>     - dir_mode=0777
>     - file_mode=0777
>   csi:
>     driver: smb.csi.k8s.io
>     # ... 其他參數
> ```
>
> Static PV 嘅 `mountOptions` 由 kubelet 直接使用，唔經 CSI driver validation，所以可以加 `soft`/`timeo`。但你就要自己管理 PV lifecycle，冇動態 provisioning 嘅便利。

### 推薦 StorageClass (SMB CSI 支援版)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb
provisioner: smb.csi.k8s.io
parameters:
  source: //smb-server.example.com/share
  csi.storage.k8s.io/provisioner-secret-name: smbcreds
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-stage-secret-name: smbcreds
  csi.storage.k8s.io/node-stage-secret-namespace: default
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1001
  - gid=1001
  - noperm
  - mfsymlinks
  - cache=strict
  - noserverino
```

> 注意：冇 `soft`, `timeo`, `reconnect`, `actimeo`——呢啲喺 SMB CSI driver 嘅動態 provisioning 唔支援。

### Deployment 完整範例 (Network 不穩定版)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-smb
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-smb
  template:
    metadata:
      labels:
        app: nginx-smb
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - key: "node-role.kubernetes.io/worker"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
      - name: nginx
        image: quay.io/centos/centos:stream8
        command:
          - "/bin/bash"
          - "-c"
          - |
            set -euo pipefail
            while true; do
              echo "$(date) - test from nginx-smb" >> /mnt/smb/outfile
              sleep 1
            done
        volumeMounts:
          - name: smb-volume
            mountPath: /mnt/smb
            readOnly: false
        livenessProbe:
          exec:
            command:
              - /bin/bash
              - -c
              - "touch /mnt/smb/liveness-check && rm -f /mnt/smb/liveness-check"
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
              - /bin/bash
              - -c
              - "test -w /mnt/smb"
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
        resources:
          limits:
            memory: 128Mi
            cpu: 250m
          requests:
            memory: 64Mi
            cpu: 50m
      volumes:
        - name: smb-volume
          persistentVolumeClaim:
            claimName: pvc-smb
```

### Node Stage 說明

Node stage 係 CSI driver 喺**每個 node 上面**做嘅 mount 步驟：

```
Pod mount 請求
    ↓
Node Stage (staging dir)
  1. 用 node-stage-secret 認證
  2. 執行 mount -t cifs //server/share /var/lib/kubelet/.../mount
    ↓
Pod mount point
  3. bind mount staging dir → Pod /mnt/smb
```

- **Node Stage** — 做真正嘅 CIFS mount（需要 `node-stage-secret`）
- **Node Publish** — 只係 bind mount staging dir → Pod mount point（冇額外認證）
- 如果 Pod 刪除但 staging dir 仲 mount 緊，CSI driver 可以**重用**呢個 mount，唔使每次重新 CIFS connect

> **必須加 `node-stage-secret`：** 呢個唔係 default 會自動帶嘅。你唔寫嘅話 Node stage 冇認證資訊，CIFS mount 會 fail。StorageClass 入面要同時寫 `provisioner-secret`（建 share 用）同 `node-stage-secret`（mount 用）。

---

## 限制

- 唔支援 Kerberos 認證
- 只支援 standalone cluster（唔支援 HyperShift）
- 已測試：Samba v4.21.2, Windows Server 2019, Windows Server 2022
- 安裝後唔會自動建立 StorageClass

---

## Troubleshooting

### Operator pod 未起嚟

```bash
# 睇 operator log
oc logs deployment/smb-csi-driver-operator -n openshift-cluster-csi-drivers

# 睇 Subscription 狀態
oc get subscription smb-csi-driver-operator -n openshift-cluster-csi-drivers -o yaml

# 睇 InstallPlan
oc get installplan -n openshift-cluster-csi-drivers
```

### PVC 未 Bound

```bash
# 睇 PVC events
oc describe pvc <pvc-name>

# 常見原因：
# 1. Secret 不存在或帳號密碼錯
# 2. SMB server 從 cluster 內連唔到
# 3. StorageClass 參數錯

# 確認 Secret 存在
oc get secret smbcreds -n <namespace>

# 從 cluster 內測試 SMB 連接 (用 debug pod)
oc run smb-test --rm -it --image=registry.access.redhat.com/ubi8/ubi -- \
  bash -c "yum install -y samba-client && smbclient //<smb-server>/<share> -U <user> --password=<pass>"
```

### Node driver 問題

```bash
# 睇 node pod log
oc logs daemonset/smb-csi-driver-node -n openshift-cluster-csi-drivers

# 睇某個 node 上面嘅 pod
oc get pods -n openshift-cluster-csi-drivers -o wide | grep smb-csi-driver-node
oc logs <pod-name-on-specific-node> -n openshift-cluster-csi-drivers
```

### 一般 Debug 步驟

```bash
# 睇所有 events
oc get events -n openshift-cluster-csi-drivers --sort-by='.lastTimestamp' | tail -20

# 睇 CSI driver 狀態
oc get csidriver smb.csi.k8s.io -o yaml

# 睇 PV 狀態
oc get pv | grep smb

# 睇 PVC 狀態
oc get pvc -A | grep smb
```

---

## 參考資料

- [OKD 官方文檔 - CIFS/SMB CSI Driver Operator](https://docs.okd.io/latest/storage/container_storage_interface/persistent-storage-csi-smb-cifs.html)
- [Red Hat 官方文檔 - OCP 4.16 CSI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/storage/using-container-storage-interface-csi)
- [CSI Operator GitHub](https://github.com/openshift/csi-operator)
- [SMB CSI Driver (upstream)](https://github.com/kubernetes-csi/csi-driver-smb)

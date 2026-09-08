# SMB CSI Driver Operator - OCP 使用指南

> 適用於 OpenShift Container Platform 4.x

## Table of Contents

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
- [限制](#限制)
- [Troubleshooting](#troubleshooting)
- [參考資料](#參考資料)

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

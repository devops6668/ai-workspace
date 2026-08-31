# StarRocks on Kubernetes — Operator 安裝指南

> 參考文件：[StarRocks Kubernetes Operator Docs (v4.1)](https://docs.starrocks.io/docs/deployment/sr_operator/)
> Operator GitHub：[StarRocks/starrocks-kubernetes-operator](https://github.com/StarRocks/starrocks-kubernetes-operator)

**目標**：在 K8s cluster 上透過 Operator 自動化部署 StarRocks 集群。
**不涉及部署到 Paul 的 cluster。**

---

## 1. 環境準備

- 一個可用的 Kubernetes cluster（EKS / GKE / k3s / 自建）
- `kubectl` 已配置並可訪問 cluster
- 建議 cluster 版本 ≥ 1.20

---

## 2. 安裝 StarRocks Operator

### 2.1 創建 CRD

```bash
kubectl apply -f https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/starrocks.com_starrocksclusters.yaml
```

> **注意**：首次安裝 CRD 時若遇到 annotation 超限錯誤（`Too long: must have at most 262144 bytes`），改用：
> ```bash
> kubectl create -f https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/starrocks.com_starrocksclusters.yaml
> ```
> 更新 CRD 則用 `kubectl replace -f`。

### 2.2 部署 Operator

**預設配置**（安裝到 `starrocks` namespace，管理所有 namespace 的 StarRocks 集群）：

```bash
kubectl apply -f https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/operator.yaml
```

**自訂配置**（可修改後再部署）：

```bash
curl -O https://raw.githubusercontent.com/StarRocks/starrocks-kubernetes-operator/main/deploy/operator.yaml
# 編輯 operator.yaml 調整設定
kubectl apply -f operator.yaml
```

### 2.3 驗證 Operator

```bash
kubectl -n starrocks get pods
```

預期輸出（所有 container READY、STATUS Running）：

```
NAME                                           READY   STATUS    RESTARTS   AGE
starrocks-controller-65bb8679-jkbtg            1/1     Running   0          5m
```

如果 Pod 無法啟動，使用以下命令排查：

```bash
kubectl logs -n starrocks <pod_name>
kubectl -n starrocks describe pod <pod_name>
```

---

## 3. 部署 StarRocks 集群

### 3.1 最簡安裝（FE + BE）

使用 StarRocks 官方範例：

```bash
kubectl apply -f https://raw.githubusercontent.com/Starrocks/starrocks-kubernetes-operator/main/examples/starrocks/starrocks-fe-and-be.yaml
```

這會創建一個包含 3 個 FE + 3 個 BE 的集群。

### 3.2 完整資源文件解析

以下是 `starrocks-fe-and-be.yaml` 的結構說明：

```yaml
apiVersion: starrocks.com/v1
kind: StarRocksCluster
metadata:
  name: starrockscluster-sample       # 集群名稱（自訂）
  namespace: starrocks                # 命名空間
spec:
  starRocksFeSpec:                     # FE（Frontend）配置
    image: starrocks/fe-ubuntu:latest  # 容器鏡像
    replicas: 3                        # 副本數（建議奇數 ≥ 3）
    limits:
      cpu: 4
      memory: 8Gi
    requests:
      cpu: 4
      memory: 8Gi
    storageVolumes:                    # 可選存儲卷
    - name: fe-meta
      storageSize: 10Gi
      mountPath: /opt/starrocks/fe/meta   # FE Meta 目錄
    - name: fe-log
      storageSize: 5Gi
      mountPath: /opt/starrocks/fe/log    # FE 日誌目錄

  starRocksBeSpec:                     # BE（Backend）配置
    image: starrocks/be-ubuntu:latest
    replicas: 3
    limits:
      cpu: 4
      memory: 8Gi
    requests:
      cpu: 4
      memory: 8Gi
    storageVolumes:
    - name: be-data
      storageSize: 1Ti
      mountPath: /opt/starrocks/be/storage  # BE 數據存儲
    - name: be-log
      storageSize: 1Gi
      mountPath: /opt/starrocks/be/log
```

**核心字段說明：**

| 字段 | 說明 |
|------|------|
| `kind` | 必須為 `StarRocksCluster` |
| `metadata.name` | 集群唯一名稱 |
| `metadata.namespace` | 命名空間 |
| `spec.starRocksFeSpec` | FE 組件配置 |
| `spec.starRocksBeSpec` | BE 組件配置 |
| `spec.starRocksCnSpec` | CN（Compute Node）組件配置（可選） |
| `image` | 容器鏡像（如 `starrocks/fe-ubuntu:latest`） |
| `replicas` | 副本數量 |
| `storageVolumes` | 持久化存儲（省略則使用 emptyDir，重啟丟失數據） |

### 3.3 驗證集群部署

```bash
kubectl -n starrocks get pods
```

預期：

```
NAME                                           READY   STATUS    RESTARTS   AGE
starrocks-controller-65bb8679-jkbtg            1/1     Running   0          22h
starrockscluster-sample-be-0                   1/1     Running   0          23h
starrockscluster-sample-be-1                   1/1     Running   0          23h
starrockscluster-sample-be-2                   1/1     Running   0          23h
starrockscluster-sample-fe-0                   1/1     Running   0          21h
starrockscluster-sample-fe-1                   1/1     Running   0          21h
starrockscluster-sample-fe-2                   1/1     Running   0          22h
```

---

## 4. 訪問 StarRocks 集群

### 4.1 從 Cluster 內部訪問

```bash
# 查看 Service
kubectl -n starrocks get svc
```

```
NAME                                 TYPE        CLUSTER-IP       PORT(S)
starrockscluster-sample-fe-service   ClusterIP   10.100.162.xxx   8030,9020,9030,9010/TCP
```

```bash
# 使用 MySQL 客戶端連接
mysql -h <CLUSTER-IP> -P 9030 -uroot
```

### 4.2 從 Cluster 外部訪問

通過修改 Service 類型為 `LoadBalancer` 或 `NodePort`：

```bash
kubectl -n starrocks edit src starrockscluster-sample
```

在 `starRocksFeSpec` 中添加：

```yaml
starRocksFeSpec:
  service:
    type: LoadBalancer   # 或 NodePort
```

然後用EXTERNAL-IP 或 NodePort 連接。

---

## 5. 管理操作

### 5.1 升級 BE

```bash
kubectl -n starrocks patch starrockscluster starrockscluster-sample \
  --type='merge' \
  -p '{"spec":{"starRocksBeSpec":{"image":"starrocks/be-ubuntu:latest"}}}'
```

### 5.2 升級 FE

```bash
kubectl -n starrocks patch starrockscluster starrockscluster-sample \
  --type='merge' \
  -p '{"spec":{"starRocksFeSpec":{"image":"starrocks/fe-ubuntu:latest"}}}'
```

### 5.3 擴容 BE

```bash
kubectl -n starrocks patch starrockscluster starrockscluster-sample \
  --type='merge' \
  -p '{"spec":{"starRocksBeSpec":{"replicas":9}}}'
```

### 5.4 縮容 BE

縮容需逐節點進行，等待 tablet 重新分佈後再繼續：

```bash
kubectl -n starrocks patch starrockscluster starrockscluster-sample \
  --type='merge' \
  -p '{"spec":{"starRocksBeSpec":{"replicas":9}}}'
```

縮容後手動刪除 `alive=false` 的節點：

```sql
SHOW PROC '/statistic';
```

### 5.5 擴容 FE

```bash
kubectl -n starrocks patch starrockscluster starrockscluster-sample \
  --type='merge' \
  -p '{"spec":{"starRocksFeSpec":{"replicas":4}}}'
```

### 5.6 CN 自動伸縮（可選）

新增 `starRocksCnSpec` 與 `autoScalingPolicy`：

```yaml
spec:
  starRocksCnSpec:
    image: starrocks/cn-ubuntu:latest
    limits:
      cpu: 16
      memory: 64Gi
    requests:
      cpu: 16
      memory: 64Gi
    autoScalingPolicy:
      maxReplicas: 10
      minReplicas: 1
      hpaPolicy:
        metrics:
          - type: Resource
            resource:
              name: memory
              target:
                averageUtilization: 60
                type: Utilization
          - type: Resource
            resource:
              name: cpu
              target:
                averageUtilization: 60
                type: Utilization
        behavior:
          scaleUp:
            policies:
              - type: Pods
                value: 1
                periodSeconds: 10
          scaleDown:
            selectPolicy: Disabled
```

> 啟用自動伸縮後，需從 `starRocksCnSpec` 中移除 `replicas` 字段。

---

## 6. FAQ

### CRD 安裝失敗：annotation 超限

```
The CustomResourceDefinition 'starrocksclusters.starrocks.com' is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

**解法**：
- 首次安裝：使用 `kubectl create -f <file>`
- 更新已有 CRD：使用 `kubectl replace -f <file>`

### Pod 長時間無法啟動

```bash
kubectl logs -n starrocks <pod_name>
kubectl -n starrocks describe pod <pod_name>
```

---

## 附錄：資源清單

| 資源 | 說明 |
|------|------|
| `StarRocksCluster` CRD | 自訂資源定義 |
| `StarRocksCluster` CR | 集群實例 |
| `starrocks-controller-*` | Operator 控制平面 Pod |
| `<cluster>-fe-*` | FE Pod |
| `<cluster>-be-*` | BE Pod |
| `<cluster>-cn-*` | CN Pod（可選） |
| `<cluster>-fe-service` | FE Service（ClusterIP / LoadBalancer） |
| `fe-domain-search` | FE Headless Service（DNS） |
| `be-domain-search` | BE Headless Service（DNS） |

**API 參考**：[github.com/StarRocks/starrocks-kubernetes-operator/doc/api.md](https://github.com/StarRocks/starrocks-kubernetes-operator/blob/main/doc/api.md)

# LiteLLM 生產環境部署指南 (k3s)

官方 Helm 部署方式，適用於 k3s 單節點叢集。

基於 [docs.litellm.ai/docs/proxy/deploy](https://docs.litellm.ai/docs/proxy/deploy)。

**目標環境：** k3s 單節點 (192.168.89.61)

---

## 架構

```
┌─────────────────────────────────────────────────────────┐
│  k3s 節點 (192.168.89.61)                               │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ NS: litellm                                      │    │
│  │                                                  │    │
│  │  ┌─────────────┐    ┌──────────────────────┐    │    │
│  │  │ LiteLLM     │───▶│ PostgreSQL            │    │    │
│  │  │ (monolith)  │    │ (bitnami subchart)    │    │    │
│  │  │ Port: 4000  │    │ Port: 5432            │    │    │
│  │  │ NodePort:   │    │ PVC: 10Gi             │    │    │
│  │  │   31275     │    └──────────────────────┘    │    │
│  │  └──────┬──────┘                                │    │
│  │         │                                       │    │
│  │         ▼                                       │    │
│  │  ┌──────────────┐                               │    │
│  │  │ Redis        │                               │    │
│  │  │ (bitnami)    │                               │    │
│  │  │ Port: 6379   │                               │    │
│  │  └──────────────┘                               │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## 部署模式

本指南使用 **Monolithic** 模式 — 單一 `litellm` image 同時提供 LLM 流量、管理 API 和 UI。這是最簡單的運作方式，對應 `litellm-helm` chart。

微服務模式（gateway + backend + ui 獨立服務）請參閱官方文件。

---

## 前置條件

| 元件 | 需要 | 你的環境 |
|------|------|---------|
| Kubernetes | 1.24+ | k3s v1.33.0 |
| Helm | 3.x | 已安裝 |
| PostgreSQL | 14+ | litellm NS 內的 bitnami subchart |
| Redis | 6+ | 待安裝 |
| StorageClass | ReadWriteOnce | local-path, nfs-csi |

---

## 步驟 1：建立 Secrets（官方模式）

官方 chart 需要三個 secret：

```bash
# 1. Master key — proxy 的管理員金鑰
kubectl create secret generic litellm-masterkey \
  --from-literal=masterkey="sk-$(openssl rand -hex 24)" \
  -n litellm

# 2. Database credentials — PostgreSQL 連線凭證
kubectl create secret generic litellm-db \
  --from-literal=username=litellm \
  --from-literal=password="<your-database-password>" \
  -n litellm

# 3. Environment secrets — SALT_KEY、provider API keys、Redis 密碼
kubectl create secret generic litellm-env \
  --from-literal=LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=REDIS_PASSWORD="<your-redis-password>" \
  --from-literal=OPENAI_API_KEY="<your-provider-key>" \
  -n litellm
```

> **重要：** `LITELLM_SALT_KEY` 用於加密資料庫中的 provider 憑證。一旦設定並新增模型後，請勿更改 — 否则凭證將無法讀取。請產生強隨機值並妥善保管。

---

## 步驟 2：安裝 Redis

LiteLLM 需要 Redis 用於速率限制、路由器狀態和快取。

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis \
  --namespace litellm \
  --set architecture=standalone \
  --set auth.enabled=true \
  --set auth.existingSecret=litellm-env \
  --set auth.secretKeys.redisPasswordKey=REDIS_PASSWORD \
  --set master.persistence.size=1Gi \
  --set master.persistence.storageClass=local-path
```

驗證 Redis 正在運行：

```bash
kubectl get pods -n litellm | grep redis
```

---

## 步驟 3：安裝 PostgreSQL（如尚未安裝）

如果已有 PostgreSQL，請跳過此步驟。

```bash
helm install postgres bitnami/postgresql \
  --namespace litellm \
  --set auth.database=litellm \
  --set auth.username=litellm \
  --set auth.password="<your-database-password>" \
  --set primary.persistence.size=10Gi \
  --set primary.persistence.storageClass=local-path
```

---

## 步驟 4：使用 Helm 部署 LiteLLM

### values.yaml

```yaml
# LiteLLM Helm values — 官方 monolithic 部署
# 參考: https://docs.litellm.ai/docs/proxy/deploy#deploy-with-helm

replicaCount: 1  # 單節點；HA 時使用 3+

image:
  repository: ghcr.io/berriai/litellm-database
  tag: "v1.85.1"  # 鎖定版本，請勿使用 :latest

# Master key from existing secret
masterkeySecretName: litellm-masterkey
masterkeySecretKey: masterkey

# PostgreSQL — 使用現有的 bitnami subchart
db:
  useExisting: true
  deployStandalone: false
  endpoint: "postgres-postgresql.litellm.svc.cluster.local"
  database: litellm
  secret:
    name: litellm-db
    usernameKey: username
    passwordKey: password

# 環境 secrets（SALT_KEY, provider keys, Redis 密碼）
environmentSecrets:
  - litellm-env

# LiteLLM proxy 設定
proxy_config:
  general_settings:
    master_key: os.environ/PROXY_MASTER_KEY
    store_model_in_db: true

  model_list:
    - model_name: ornith
      litellm_params:
        model: custom_openai/Ornith-1.0-35B-GGUF:Q4_K_M
        api_base: http://100.89.119.5:8016/v1
        api_key: "dummy"
    - model_name: agnes
      litellm_params:
        model: custom_openai/agnes-2.0-flash
        api_base: https://apihub.agnes-ai.com/v1
        api_key: "sk-P9n...smiC"

  router_settings:
    redis_host: "redis-master.litellm.svc.cluster.local"
    redis_port: 6379
    redis_password: os.environ/REDIS_PASSWORD

  litellm_settings:
    DISABLE_SCHEMA_UPDATE: true
    LITELLM_SALT_KEY: os.environ/LITELLM_SALT_KEY
```

### 安裝

```bash
helm install litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm \
  -f values.yaml
```

### 升級

```bash
# 先在 values.yaml 中更新 image.tag，然後：
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm \
  -f values.yaml
```

---

## 步驟 5：驗證部署

```bash
# 檢查所有 pods
kubectl get pods -n litellm

# Health check（叢集內部）
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/health/liveliness

# Health check（NodePort）
curl -s http://192.168.89.61:31275/health/liveliness

# 檢查 logs
kubectl logs -n litellm deployment/litellm --tail=50

# 列出可用模型
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer <master-key>"
```

---

## 步驟 6：連接 JupyterHub

### 選項 A：預先設定 env vars（Helm values）

```yaml
singleuser:
  extraEnv:
    OPENAI_API_KEY: "<master-key>"
    OPENAI_API_BASE: "http://192.168.89.61:31275/v1"
```

```bash
helm upgrade jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub -f values.yaml
```

### 選項 B：Secret 注入（更安全）

```yaml
hub:
  extraConfig:
    litellm-env: |
      c.KubeSpawner.env_from = [
          {"secretRef": {"name": "litellm-client-creds"}}
      ]
```

```bash
kubectl create secret generic litellm-client-creds \
  --from-literal=OPENAI_API_KEY="<master-key>" \
  --from-literal=OPENAI_API_BASE="http://192.168.89.61:31275/v1" \
  -n jupyterhub
```

---

## 步驟 7：從 Notebook 使用

```python
%load_ext jupyter_ai_magic_commands

import os
os.environ["OPENAI_API_KEY"] = "<master-key>"
os.environ["OPENAI_API_BASE"] = "http://192.168.89.61:31275/v1"

%ai alias ornith custom_openai/ornith
%ai alias agnes custom_openai/agnes
```

```python
%%ai ornith
你好，你能做什麼？
```

---

## Secrets 參考

| Secret 名稱 | Keys | 用途 |
|-------------|------|------|
| litellm-masterkey | `masterkey` | Proxy 的管理員金鑰 |
| litellm-db | `username`, `password` | PostgreSQL 憑證 |
| litellm-env | `LITELLM_SALT_KEY`, `REDIS_PASSWORD`, `OPENAI_API_KEY` | 加密、快取、provider 存取 |

---

## 環境變數

| 變數 | 來源 | 說明 |
|------|------|------|
| `PROXY_MASTER_KEY` | litellm-masterkey | Proxy 的管理員存取 |
| `LITELLM_SALT_KEY` | litellm-env | 加密資料庫中的 provider 憑證 |
| `DATABASE_URL` | litellm-db + db endpoint | PostgreSQL 連線字串 |
| `REDIS_PASSWORD` | litellm-env | Redis 認證 |
| `STORE_MODEL_IN_DB` | config | 從 Admin UI 管理模型 |
| `DISABLE_SCHEMA_UPDATE` | config | Proxy pods 跳過 migrations |

---

## 生產環境檢查清單

| 項目 | 建議 | 狀態 |
|------|------|------|
| 鎖定 image 版本 | 使用特定 tag，非 :latest | OK (v1.85.1) |
| PostgreSQL | 外部或 subchart | OK (bitnami subchart) |
| Redis | 速率限制、快取必需 | 已安裝 |
| SALT_KEY | 產生，勿輪替 | 已建立 |
| DISABLE_SCHEMA_UPDATE | proxy pods 上為 true | 設定在 config |
| Replicas | 生產環境 3+ | 1（單節點） |
| Health probes | /health/liveliness, /health/readiness | 已設定 |
| Secrets | K8s secrets 或雲端 secret manager | K8s secrets |
| Ingress | 雲端 LB 或 NodePort | NodePort 31275 |

---

## 升級路徑

```bash
# 1. 檢查目前版本
helm list -n litellm

# 2. 在 values.yaml 中更新 image.tag
#    image.tag: "v1.90.2"

# 3. 升級
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm -f values.yaml

# 4. 驗證
kubectl rollout status deployment/litellm -n litellm
kubectl exec -n litellm <pod> -- curl -s http://localhost:4000/health/liveliness
```

---

## 疑難排解

### Redis connection refused

```bash
kubectl get pods -n litellm | grep redis
kubectl get svc -n litellm | grep redis
kubectl exec -n litellm <litellm-pod> -- \
  redis-cli -h redis-master.litellm.svc.cluster.local \
  -a <password> ping
```

### LITELLM_SALT_KEY not set

```bash
kubectl patch secret litellm-env -n litellm \
  -p '{"data":{"LITELLM_SALT_KEY":"'$(echo -n 'sk-your-salt-key' | base64)'"}}'
kubectl rollout restart deployment/litellm -n litellm
```

### Schema migration errors

```bash
# 檢查是否設定 DISABLE_SCHEMA_UPDATE
kubectl get deployment litellm -n litellm \
  -o jsonpath='{.spec.template.spec.containers[0].env}'

# 如果未設定，新增它
kubectl set env deployment/litellm -n litellm DISABLE_SCHEMA_UPDATE=true
```

### Model not found in Admin UI

```bash
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer <master-key>"
```

---

## 常用指令

```bash
# 狀態
kubectl get all -n litellm

# Logs
kubectl logs -n litellm deployment/litellm -f

# 重啟
kubectl rollout restart deployment/litellm -n litellm

# Helm
helm list -n litellm

# Secrets
kubectl get secrets -n litellm

# Config
kubectl get configmap litellm-config -n litellm -o yaml
```

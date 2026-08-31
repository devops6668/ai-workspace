# Jupyter AI + LiteLLM 安裝說明

將 JupyterHub notebook 連接到 LiteLLM proxy，透過 magic commands 進行 AI 對話。

**目標環境：** k3s 單節點叢集 (192.168.89.61)，Helm 管理的 JupyterHub + LiteLLM

---

## 架構概覽

```
┌─────────────────────────────────────────────────────┐
│  k3s 節點 (192.168.89.61)                            │
│                                                     │
│  ┌──────────────┐    ┌──────────────────────────┐   │
│  │ JupyterHub   │    │ LiteLLM                   │   │
│  │ (NS: jupyter │───▶│ (NS: litellm)             │   │
│  │  hub)        │    │ NodePort: 31275           │   │
│  │ Helm rev: 71 │    │ Helm rev: 2               │   │
│  └──────────────┘    └──────────┬───────────────┘   │
│       │                         │                   │
│       ▼                         ▼                   │
│  ┌──────────┐          ┌─────────────────┐          │
│  │ Single-  │          │ PostgreSQL       │          │
│  │ user Pod │          │ (litellm NS)     │          │
│  │ jupyter_ │          │ PVC: 10Gi        │          │
│  │ ai magic │          │ local-path SC    │          │
│  │ cmds     │          └─────────────────┘          │
│  └──────────┘                                       │
│       │                                             │
│       ▼                                             │
│  ┌──────────────────────────────┐                   │
│  │ 後端模型                      │                   │
│  │ - ornith (Tailscale:100.x)  │                   │
│  │ - agnes  (apihub.agnes-ai)  │                   │
│  └──────────────────────────────┘                   │
└─────────────────────────────────────────────────────┘
```

---

## 前置條件

| 元件 | 版本 | Namespace | 存取方式 |
|------|------|-----------|----------|
| k3s | v1.33.0 | - | 192.168.89.61 |
| JupyterHub (Helm) | jupyterhub-4.2.0 (app 5.3.0) | jupyterhub | NodePort 31929 |
| LiteLLM (Helm) | litellm-helm-1.10 (v1.85.1) | litellm | NodePort 31275 |
| PostgreSQL (Helm) | postgresql-18.7.13 (bitnami) | litellm | ClusterIP |
| NFS CSI | v4.7.0 | kube-system | - |

---

## 步驟 1：確認 LiteLLM 正在運行

```bash
# 檢查 litellm pod 狀態
kubectl get pods -n litellm

# 驗證 health endpoint
kubectl exec -n litellm litellm-798df8b5c6-sscl7 -- curl -s http://localhost:4000/health/liveliness

# 查看 litellm config 中的可用模型
kubectl get configmap litellm-config -n litellm -o yaml
```

litellm config 預期內容：

```yaml
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
```

---

## 步驟 2：確認 JupyterHub 正在運行

```bash
# 檢查 hub 和 proxy pods
kubectl get pods -n jupyterhub

# 檢查 helm release
helm list -n jupyterhub

# 查看 singleuser image profiles
helm get values jupyterhub -n jupyterhub | grep -A5 "profileList"
```

---

## 步驟 3：選擇 Singleuser Image

JupyterHub 提供多個 image profile。要使用 AI magic commands，請選擇 **AI Coding (Agnes)**：

| Profile | Image | 用途 |
|---------|-------|------|
| AI Coding (Agnes) | `quay.io/paulwong6668/jupyter-ai-agnes:1.30-patched-final` | AI 對話連接 litellm |
| Minimal environment | `quay.io/paulwong6668/jupyter-dagster:1.0` | 基本 Python（預設） |
| Datascience environment | `quay.io/cen_ku/data-science:1.13` | Python + R + Julia |
| Spark environment | `jupyter/all-spark-notebook:x86_64-python-3.11.6` | Apache Spark |

建立 notebook server 時，從 profile list 選擇 **"AI Coding (Agnes)"**。

---

## 步驟 4：連接 Notebook 到 LiteLLM

### 4.1 載入 Magic Commands 擴充套件

```python
%load_ext jupyter_ai_magic_commands
```

### 4.2 設定 API Key 和 Endpoint

```python
import os

# LiteLLM proxy 設定
# API key = litellm master key（來自 secret litellm-masterkey）
os.environ["OPENAI_API_KEY"] = "sk-your-litellm-master-key"

# LiteLLM NodePort endpoint
os.environ["OPENAI_API_BASE"] = "http://192.168.89.61:31275/v1"
```

### 4.3 驗證設定

```python
import os
print("API Key:", os.environ.get("OPENAI_API_KEY", "NOT SET")[:10] + "...")
print("API Base:", os.environ.get("OPENAI_API_BASE", "NOT SET"))
```

### 4.4 註冊模型別名

```python
# 註冊 ornith 模型（連接到 litellm -> Tailscale ornith server）
%ai alias ornith custom_openai/ornith

# 註冊 agnes 模型（連接到 litellm -> agnes API）
%ai alias agnes custom_openai/agnes
```

### 4.5 開始對話

```python
%%ai ornith
法國的首都是哪裡？
```

```python
%%ai agnes
寫一個 Python 函數來計算階乘
```

---

## 步驟 5：為所有使用者預先設定（可選）

避免使用者手動設定 env vars，可在 JupyterHub Helm values 中加入：

```yaml
# helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub -f values.yaml
singleuser:
  extraEnv:
    OPENAI_API_KEY: "sk-your-litellm-master-key"
    OPENAI_API_BASE: "http://192.168.89.61:31275/v1"
```

或在 singleuser image 中建立 `ipython_config.py` 設定預設別名：

```python
# /etc/ipython/ipython_config.py
c.AiMagics.aliases = {
    "ornith": "custom_openai/ornith",
    "agnes": "custom_openai/agnes"
}
c.AiMagics.initial_language_model = "custom_openai/ornith"
```

---

## 疑難排解

### "ModuleNotFoundError: No module named 'jupyter_ai_magic_commands'"

Magic commands 套件未安裝在 singleuser image 中。

```python
# 在 notebook cell 中安裝
%pip install jupyter-ai-magic-commands
```

### 連接 litellm 時出現 "Connection refused"

```bash
# 確認 litellm 正在運行
kubectl get pods -n litellm

# 檢查 NodePort 是否可存取
curl -s http://192.168.89.61:31275/health/liveliness

# 查看 litellm logs
kubectl logs -n litellm deployment/litellm --tail=50
```

### litellm 回傳 "AuthenticationError"

API key 必須與 litellm master key 匹配：

```bash
# 取得 master key
kubectl get secret litellm-masterkey -n litellm -o jsonpath='{.data.masterkey}' | base64 -d
```

### litellm 中找不到模型

檢查 litellm config 是否包含你的模型：

```bash
kubectl get configmap litellm-config -n litellm -o yaml
```

### litellm 版本不相容

`jupyter-ai-litellm` 鎖定 `litellm<=1.82.6`，但你的叢集運行 v1.85.1。若遇到問題：

```python
# 檢查已安裝的 litellm 版本
import litellm
print(litellm.__version__)

# 如有需要，鎖定到相容版本
%pip install litellm==1.82.6
```

---

## 常用指令

```bash
# JupyterHub 狀態
kubectl get all -n jupyterhub

# LiteLLM 狀態
kubectl get all -n litellm

# LiteLLM logs
kubectl logs -n litellm deployment/litellm -f

# JupyterHub logs
kubectl logs -n jupyterhub deployment/hub -f

# Helm releases
helm list -A | grep -E "jupyter|litellm"

# 重啟 litellm（修改 config 後）
kubectl rollout restart deployment/litellm -n litellm

# 重啟 JupyterHub hub（修改 values 後）
kubectl rollout restart deployment/hub -n jupyterhub
```

---

## Magic Commands 快速參考

| 指令 | 說明 |
|------|------|
| `%load_ext jupyter_ai_magic_commands` | 載入擴充套件 |
| `%ai list` | 列出所有可用模型 |
| `%ai alias NAME MODEL` | 建立模型別名 |
| `%ai dealias NAME` | 刪除模型別名 |
| `%%ai MODEL` | 使用模型回應 prompt |
| `%%ai MODEL -f code` | 輸出格式為程式碼 |
| `%%ai MODEL -f markdown` | 輸出格式為 markdown |
| `%config AiMagics.max_history = 4` | 設定上下文對話數 |

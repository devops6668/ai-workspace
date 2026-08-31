# Jupyter AI v3.x + JupyterHub on K3s 指南

## 目錄

1. [概述](#概述)
2. [v3.x 新架構](#v3x-新架構)
3. [前置需求](#前置需求)
4. [快速安裝](#快速安裝)
5. [K3s + JupyterHub 部署](#k3s--jupyterhub-部署)
6. [模型配置](#模型配置)
7. [使用方法](#使用方法)
8. [支持嘅 Agents](#支持嘅-agents)
9. [MCP Server 配置](#mcp-server-配置)
10. [Docker Image 構建](#docker-image-構建)
11. [Helm 部署](#helm-部署)
12. [故障排除](#故障排除)
13. [參考資源](#參考資源)

---

## 概述

Jupyter AI v3.x 係 JupyterLab 嘅 agentic AI 擴展，提供：

- **Chat UI** - 原生 JupyterLab sidebar chat panel
- **AI Personas** - 每個 agent 以 persona 形式出現
- **ACP (Agent Client Protocol)** - 標準化 agent 通信
- **MCP (Model Context Protocol)** - 工具/資源整合
- **Permission System** - agent 操作需用戶批准
- **Multi-chat** - 同時多個 chat session
- **Real-time Collaboration** - 多用戶共享

### 組件說明

| 組件 | 用途 | 來源 |
|------|------|------|
| `jupyter-ai` | 主套件 (metapackage) | PyPI |
| `jupyterlab-chat` | Chat UI 框架 | PyPI |
| `jupyter-ai-persona-manager` | Persona 管理 | jupyter-ai-contrib |
| `jupyter-ai-litellm` | LiteLLM 模型抽象 | jupyter-ai-contrib |
| `jupyter-ai-acp-client` | ACP agent 客戶端 | jupyter-ai-contrib |
| `jupyter-server-mcp` | MCP server 整合 | jupyter-ai-contrib |
| `jupyter-ai-jupyternaut` | 預設 persona | jupyter-ai-contrib |

---

## v3.x 新架構

v3.x 係模組化架構，唔再係 monorepo。核心代碼分散喺 `jupyter-ai-contrib` org 嘅各個 repo：

```
┌─────────────────────────────────────────────────────────────────┐
│                    JupyterLab (Chat UI)                         │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Chat Sidebar  │  AI Settings  │  Permission Dialog       │  │
│  └───────────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ACP / MCP
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Persona Manager                                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐│
│  │ Jupyternaut  │  │ Claude Code │  │ Codex / Copilot / ...   ││
│  │ (LiteLLM)   │  │ (ACP)       │  │ (ACP)                   ││
│  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘│
└─────────┼────────────────┼───────────────────────┼─────────────┘
          │                │                       │
          ▼                ▼                       ▼
   ┌────────────┐  ┌────────────┐         ┌────────────┐
   │ LiteLLM    │  │ Claude     │         │ OpenAI     │
   │ (OpenAI    │  │ Code CLI   │         │ Codex CLI  │
   │  compat)   │  │            │         │            │
   └────────────┘  └────────────┘         └────────────┘
```

---

## 前置需求

- Python 3.9+
- JupyterLab 4.x
- Kubernetes cluster (K3s/RKE2)
- Helm 3.x
- 至少一個 AI API key

---

## 快速安裝

### 本地安裝 (pip)

```bash
# 安裝 jupyter-ai 主套件
pip install jupyter-ai

# 安裝 Jupyternaut persona (預設)
pip install jupyter-ai[jupyternaut]

# 或安裝 magic commands (舊版兼容)
pip install jupyter-ai[magics]

# 驗證安裝
jupyter server extension list
# 應該看到 jupyter_ai, jupyter_ai_litellm, jupyter_ai_jupyternaut 等
```

### 安裝 Agents (可選)

jupyter-ai v3.x 唔內建 agent，需另外安裝：

```bash
# Claude Code
npm install -g @agentclientprotocol/claude-agent-acp

# Codex CLI
npm install -g @agentclientprotocol/codex-acp

# Mistral Vibe
pip install mistral-vibe
# 或
uv tool install mistral-vibe

# 其他 agents 參考官方文檔
```

---

## K3s + JupyterHub 部署

### 架構

```
┌─────────────────────────────────────────────┐
│  K3s Cluster                                │
│  ┌─────────────────────────────────────────┐│
│  │  jupyterhub namespace                   ││
│  │  ┌──────────┐  ┌──────────────────────┐ ││
│  │  │ Hub Pod  │  │ User Pod (per user)  │ ││
│  │  │ (Helm)   │  │ jupyter-ai + agent   │ ││
│  │  └──────────┘  └──────────────────────┘ ││
│  │  ┌──────────┐  ┌──────────────────────┐ ││
│  │  │ Proxy    │  │ User Scheduler       │ ││
│  │  └──────────┘  └──────────────────────┘ ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

### 步驟

#### 1. 建立 API Key Secret

```bash
# Agnes AI (或你嘅 OpenAI-compatible API)
kubectl create secret generic agnes-api-key \
  -n jupyterhub \
  --from-literal=OPENAI_API_KEY=sk-your-key-here

# 或通用 API keys
kubectl create secret generic jupyterhub-api-keys \
  -n jupyterhub \
  --from-literal=OPENAI_API_KEY=sk-your-openai-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-your-key
```

#### 2. Helm Values 關鍵配置

```yaml
# singleuser.extraEnv - 注入 API 配置到 user pod
singleuser:
  extraEnv:
    OPENAI_API_BASE: "https://apihub.agnes-ai.com/v1"
    OPENAI_API_KEY: "sk-your-key"  # 或引用 Secret

# profileList - 定義可用嘅 notebook image
profileList:
  - description: Jupyter AI with Agnes model
    display_name: AI Coding (Agnes)
    kubespawner_override:
      image: your-registry/jupyter-ai:latest
  - default: true
    description: Minimal environment
    display_name: Minimal environment
```

#### 3. 安裝/升級 JupyterHub

```bash
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f values.yaml \
  --wait --timeout 10m
```

---

## 模型配置

### Jupyternaut 模型設定

Jupyternaut 使用 LiteLLM 連接 OpenAI-compatible API。配置方式：

#### 方法 1: AI Settings UI (推薦)

1. 開 JupyterLab
2. 去 **Settings > AI Settings**
3. 揀 **Chat Model** → 選擇 `openai/agnes-2.0-flash` (或其他 model)
4. 設定 API Key (如需要)

#### 方法 2: 直接改 config file

```bash
# 進入 user pod
kubectl exec -n jupyterhub <pod-name> -- bash

# 編輯 config
cat > /home/jovyan/.local/share/jupyter/jupyter_ai/config.json << 'EOF'
{
    "model_provider_id": "openai/agnes-2.0-flash",
    "embeddings_provider_id": null,
    "completions_model_provider_id": null,
    "api_keys": {},
    "send_with_shift_enter": false,
    "fields": {},
    "embeddings_fields": {},
    "completions_fields": {}
}
EOF
```

#### Model ID 格式

LiteLLM 使用 `{provider}/{model}` 格式：

| Provider | Model ID 格式 | 範例 |
|----------|--------------|------|
| OpenAI | `openai/{model}` | `openai/gpt-4o` |
| Agnes AI | `openai/{model}` | `openai/agnes-2.0-flash` |
| Anthropic | `anthropic/{model}` | `anthropic/claude-3-opus` |
| 本地 Ollama | `ollama/{model}` | `ollama/llama3` |

### Agnes AI 可用 Models

```
agnes-2.0-flash          # 基礎模型
agnes-2.5-flash          # 進階模型
agnes-2.5-pro            # 專業版
agnes-2.5-pro-alpha      # 測試版
agnes-2.5-pro-beta       # Beta 版
agnes-image-2.0-flash    # 圖像生成
agnes-image-2.1-flash    # 圖像生成 v2
agnes-video-2.5-flash    # 影片生成
agnes-video-2.5          # 影片生成
agnes-video-v2.0         # 影片生成 v2
```

---

## 使用方法

### Chat UI

1. 開 JupyterLab
2. 左邊 sidebar 點擊 **Chat** icon
3. 建立 new chat
4. 揀 persona (Jupyternaut / Claude Code / etc.)
5. 輸入 prompt 並發送

### Agent 操作

Agent 可以：
- 讀寫文件
- 執行 terminal 命令
- 操作 notebook (透過 MCP server)
- 拖放文件/cell 作為 context

### Permission System

Agent 執行危險操作前會要求批准：
- 寫入文件
- 執行 shell 命令
- 修改 notebook

可喺 input toolbar 設定 auto-approve。

---

## 支持嘅 Agents

| Agent | 類型 | 安裝方式 |
|-------|------|---------|
| Jupyternaut | LiteLLM | `pip install jupyter-ai[jupyternaut]` |
| Claude Code | ACP | `npm install -g @agentclientprotocol/claude-agent-acp` |
| Codex CLI | ACP | `npm install -g @agentclientprotocol/codex-acp` |
| GitHub Copilot CLI | ACP | 官方安裝 |
| Goose | ACP | 官方安裝 |
| Kilo CLI | ACP | 官方安裝 |
| Kiro CLI | ACP | 官方安裝 |
| Mistral Vibe | ACP | `pip install mistral-vibe` |
| OpenCode | ACP | 官方安裝 |

---

## MCP Server 配置

### 內建 MCP Server

jupyter-ai 內建 Jupyter MCP Server，提供：
- Notebook 讀寫
- Cell 操作
- Kernel 管理

### 自定義 MCP Server

```yaml
# 在 JupyterLab Settings > AI Settings > MCP Servers 新增
mcpServers:
  my-tools:
    command: "python"
    args: ["-m", "my_mcp_server"]
    env:
      MY_API_KEY: "xxx"
```

---

## Docker Image 構建

### 文件結構

```
jupyter-ai/
├── Dockerfile              # JupyterHub 基礎 image
├── Dockerfile.k8s          # K8s 優化版本
├── requirements.txt        # Python 依賴
├── litellm-config/
│   └── config.yaml         # LiteLLM 配置模板
├── helm/
│   ├── values.yaml         # Helm chart values
│   └── deploy.sh           # 部署腳本
└── docker-compose.yml      # 本地測試用
```

### 構建 Image

```bash
# 基礎版本
docker build -t jupyter-ai:latest .

# K8s 版本
docker build -f Dockerfile.k8s -t jupyter-ai-k8s:latest .

# 推送到 Harbor
docker tag jupyter-ai:latest harbor.devops.local/jupyter/jupyter-ai:latest
docker push harbor.devops.local/jupyter/jupyter-ai:latest
```

### Dockerfile 範例 (v3.x)

```dockerfile
FROM quay.io/jupyterhub/k8s-hub:4.1.0

LABEL maintainer="Paul Wong"
LABEL description="JupyterHub with jupyter-ai v3.x"

USER root

# 安裝系統依賴
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 安裝 jupyter-ai + Jupyternaut
RUN pip install --no-cache-dir \
    jupyter-ai[jupyternaut] \
    litellm

# 安裝 Node.js (for ACP agents)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER ${NB_UID}
```

---

## Helm 部署

### values.yaml 關鍵配置

```yaml
# Hub 配置
hub:
  config:
    JupyterHub:
      authenticator_class: "dummy"  # 測試用
      admin_access: true

# Single User 配置
singleuser:
  image:
    name: harbor.devops.local/jupyter/jupyter-ai
    tag: latest
  extraEnv:
    OPENAI_API_BASE: "https://apihub.agnes-ai.com/v1"
    OPENAI_API_KEY: "sk-your-key"
  storage:
    capacity: 10Gi
    storageClass: nfs-csi

# Profile List (多 image 選擇)
profileList:
  - description: Jupyter AI with Agnes model
    display_name: AI Coding (Agnes)
    kubespawner_override:
      image: harbor.devops.local/jupyter/jupyter-ai:latest
  - default: true
    description: Minimal environment
    display_name: Minimal environment
```

### 部署命令

```bash
# 新安裝
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub --create-namespace \
  -f values.yaml --wait --timeout 10m

# 升級 (保留現有 values)
helm get values jupyterhub -n jupyterhub -o yaml > current-values.yaml
# 修改 current-values.yaml
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub -f current-values.yaml --wait --timeout 10m

# 查看狀態
helm list -n jupyterhub
kubectl get pods -n jupyterhub
```

---

## 故障排除

### Q1: "No chat model is configured"

**原因**: `model_provider_id` 未設定

**解決**:
```bash
# 進入 pod
kubectl exec -n jupyterhub <pod-name> -- bash

# 檢查 config
cat /home/jovyan/.local/share/jupyter/jupyter_ai/config.json

# 修改 model_provider_id
python3 -c "
import json
path = '/home/jovyan/.local/share/jupyter/jupyter_ai/config.json'
with open(path) as f: config = json.load(f)
config['model_provider_id'] = 'openai/agnes-2.0-flash'
with open(path, 'w') as f: json.dump(config, f, indent=2)
"
```

### Q2: API Key 無效

**原因**: Secret 入面係 placeholder 或過期

**解決**:
```bash
# 更新 Secret
kubectl create secret generic agnes-api-key \
  -n jupyterhub \
  --from-literal=OPENAI_API_KEY=sk-your-real-key \
  --dry-run=client -o yaml | kubectl apply -f -

# 更新 Helm values
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  --reuse-values \
  --set singleuser.extraEnv.OPENAI_API_KEY=sk-your-real-key \
  --wait

# 重啟 user pod
kubectl delete pod -n jupyterhub <pod-name>
```

### Q3: Helm upgrade schema 錯誤

**原因**: 舊 values 格式唔兼容新版 chart

**解決**:
```bash
# 匯出 current values
helm get values jupyterhub -n jupyterhub -o yaml > values.yaml

# 修復 schema 問題
# GenericOAuthenticator: [] → GenericOAuthenticator: {}
# extraPodConfig: null → extraPodConfig: {}

# 重新 apply
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub -f values.yaml --wait
```

### Q4: JupyterLab 見唔到 Chat panel

**原因**: jupyter-ai extension 未正確載入

**解決**:
```bash
# 檢查 extensions
kubectl exec -n jupyterhub <pod-name> -- jupyter server extension list

# 確認 jupyter_ai 已 enabled
# 如果冇，手動 enable
kubectl exec -n jupyterhub <pod-name> -- jupyter server extension enable jupyter_ai
```

### Q5: Agent 冇回應

**原因**: Agent 未安裝或未登入

**解決**:
```bash
# 檢查 agent 是否安裝
kubectl exec -n jupyterhub <pod-name> -- which claude  # Claude Code
kubectl exec -n jupyterhub <pod-name> -- which codex   # Codex CLI

# 登入 agent (需要喺 terminal 執行)
kubectl exec -n jupyterhub <pod-name> -- claude auth login
```

---

## 參考資源

### 官方文檔

- **Jupyter AI**: https://jupyter-ai.readthedocs.io/
- **Jupyter AI GitHub**: https://github.com/jupyterlab/jupyter-ai
- **jupyter-ai-contrib**: https://github.com/jupyter-ai-contrib
- **JupyterHub Helm**: https://z2jh.jupyter.org/
- **ACP (Agent Client Protocol)**: https://agentclientprotocol.com
- **MCP (Model Context Protocol)**: https://modelcontextprotocol.io

### LiteLLM

- **LiteLLM 文檔**: https://docs.litellm.ai/
- **LiteLLM Providers**: https://docs.litellm.ai/docs/providers
- **LiteLLM Proxy**: https://docs.litellm.ai/docs/proxy

### 相關工具

- **Langfuse** (成本追蹤): https://langfuse.com/

---

## 版本資訊

- **指南版本**: 2.0
- **建立日期**: 2026-07-21
- **更新日期**: 2026-08-28
- **作者**: Paul Wong (via Hermes Agent)
- **基於**: jupyter-ai v3.0.1, JupyterHub 4.2.0 (Helm chart), K3s
- **更新**: 全面重寫 for v3.x 架構 (ACP + Chat UI + Jupyternaut)

---

## 授權

此指南僅供內部使用。

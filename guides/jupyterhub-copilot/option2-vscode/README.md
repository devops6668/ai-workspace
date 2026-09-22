# JupyterHub + VS Code (code-server) + Jupyter AI

## 目录

1. [概述](#概述)
2. [架构](#架构)
3. [組件說明](#組件說明)
4. [文件結構](#文件結構)
5. [構建 Image](#構建-image)
6. [Helm 部署](#helm-部署)
7. [使用方法](#使用方法)
8. [已知問題與修復](#已知問題與修復)
9. [故障排除](#故障排除)

---

## 概述

將 datascience-notebook、jupyter-ai v3.x、VS Code (code-server) 同 notebook-intelligence 合併喺一個 image 入面。用戶可以喺 JupyterLab 入面直接用 VS Code，唔需要額外部署。

### 功能一覽

| 功能 | 來源 |
|------|------|
| JupyterLab Chat (AI) | jupyter-ai v3.x + Jupyternaut |
| VS Code (in browser) | code-server + jupyter-server-proxy |
| Copilot / OpenAI / Ollama | notebook-intelligence |
| Data Science | datascience-notebook (Python, R, Julia) |
| ACP Agents | Node.js 20 (Claude Code, Codex 等) |

---

## 架構

```
JupyterHub (K3s)
  └─ User Pod
       ├─ JupyterLab (port 8888)
       │    ├─ Chat Sidebar ← jupyter-ai + LiteLLM
       │    ├─ notebook-intelligence (Copilot/OpenAI)
       │    └─ Launcher: "VS Code" tile
       │         └─ jupyter-server-proxy
       │              └─ code-server (127.0.0.1:{random_port})
       │                   ├─ Python extension
       │                   ├─ Ruff extension
       │                   └─ Jupyter extension
       └─ PVC: /home/jovyan
```

---

## 組件說明

| 組件 | 版本 | 用途 |
|------|------|------|
| datascience-notebook | latest (quay.io) | Base image (Python 3.13, R, Julia) |
| jupyter-ai | >=3.1.0 | AI Chat in JupyterLab |
| litellm | >=1.0.0 | LLM model abstraction |
| code-server | 4.x | VS Code in browser |
| jupyter-server-proxy | 4.x | Proxy code-server through JupyterLab |
| notebook-intelligence | latest | Copilot/OpenAI/Ollama in JupyterLab |

---

## 文件結構

```
option2-vscode/
├── Dockerfile              # 建構 image
├── code_server_proxy.py    # jupyter-server-proxy 入口 (code-server 路由)
├── entry_points.txt        # Python entry point for proxy package
├── METADATA                # dist-info metadata
├── top_level.txt           # dist-info top-level
├── docker-compose.yml      # 本地測試用
└── README.md               # 本文件
```

---

## 構建 Image

```bash
cd /path/to/option2-vscode

# 構建
docker build -t quay.io/rke2/jupyter-datascience:v1.0-ai .

# 推送到 Harbor
docker push quay.io/rke2/jupyter-datascience:v1.0-ai
```

### Dockerfile 說明

Dockerfile 分 8 層：

1. **System deps** — Node.js 20 (ACP agents + code-server)
2. **code-server** — VS Code in browser (root install)
3. **pip install** — jupyter-ai, notebook-intelligence, jupyter-server-proxy
4. **code-server proxy package** — 註冊 code-server 做 JupyterLab launcher tile
5. **VS Code extensions** — Python, Ruff, Jupyter
6. **Environment** — OPENAI_API_BASE, OPENAI_API_KEY
7. **Health check** — curl localhost:8888/api
8. **CMD** — start-notebook.sh

> **注意**: datascience-notebook:latest 用 Python **3.13**，COPY 路徑要用
> `/opt/conda/lib/python3.13/site-packages/`，唔係 3.12。

---

## Helm 部署

### 新增 profile 到 values.yaml

```yaml
singleuser:
  profileList:
    - display_name: "Jupyter AI + VS Code (datascience)"
      description: "datascience + jupyter-ai v3.x + VS Code + Copilot"
      default: true
      kubespawner_override:
        image: quay.io/rke2/jupyter-datascience:v1.0-ai
```

### 部署命令

```bash
cd /home/paul/jupyterhub
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f values.yaml \
  --version 4.2.0 \
  --wait --timeout 10m
```

---

## 使用方法

### JupyterLab

1. 登入 JupyterHub，揀 "Jupyter AI + VS Code (datascience)" profile
2. 等待 pod 啟動

### VS Code (in browser)

1. 喺 JupyterLab launcher 點擊 **VS Code** tile
2. 新 browser tab 會打開 VS Code
3. 已預裝 Python、Ruff、Jupyter extensions
4. 可喺 Extensions sidebar (Ctrl+Shift+X) 安裝更多

### Jupyter AI Chat

1. 喺 JupyterLab 左邊 sidebar 點擊 **Chat** icon
2. 揀 persona (Jupyternaut)
3. 設定模型：Settings > AI Settings > Chat Model

### notebook-intelligence

1. 喺 JupyterLab Settings > AI Settings 設定 Copilot / OpenAI / Ollama

---

## 已知問題與修復

### 1. code_server_proxy.py 回傳格式 Bug

**問題**: `_jupyter_server_proxy_servers()` 回傳嵌套 dict `{"vscode": {"command": [...]}}`，但 `jupyter_server_proxy` 嘅 `get_entrypoint_server_processes` 用 `ServerProcess(name="vscode", **result)` 建立 handler，結果 `command` 為空，code-server 唔會啟動，`/vscode/` 返回 500。

**修復**: 回傳 flat dict（唔要外層 `"vscode"` key）：

```python
# 正確 ✅
def _jupyter_server_proxy_servers():
    return {
        "command": ["code-server", ...],
        "timeout": 30,
        ...
    }

# 錯誤 ❌
def _jupyter_server_proxy_servers():
    return {
        "vscode": {
            "command": ["code-server", ...],
            ...
        }
    }
```

### 2. Python 版本路徑

**問題**: `datascience-notebook:latest` 用 Python **3.13**（唔係 3.12）。COPY 路徑必須用 `python3.13/site-packages/`。

**修復**: Dockerfile 入面所有 `python3.12` 改做 `python3.13`。

### 3. jupyternaut.patch 路徑

**問題**: Helm values 嘅 `extraFiles` patch 路徑指向 `python3.12`，但 image 用 `python3.13`。

**修復**: 更新 `extraFiles` mountPath：
```yaml
mountPath: /opt/conda/lib/python3.13/site-packages/jupyter_ai_jupyternaut/jupyternaut/jupyternaut.py
```

---

## 故障排除

### VS Code tile 唔出現

```bash
# 檢查 entry point 有冇正確註冊
kubectl exec -n jupyterhub <pod> -- python3 -c "
from importlib.metadata import entry_points
for ep in entry_points(group='jupyter_serverproxy_servers'):
    print(ep.name, ep.value)
"
# 應該見到: vscode jupyter_code_server_proxy:_jupyter_server_proxy_servers
```

### /vscode/ 返回 500

```bash
# 檢查 command 有冇正確載入（唔應該係空 list）
kubectl exec -n jupyterhub <pod> -- python3 -c "
from importlib.metadata import entry_points
for ep in entry_points(group='jupyter_serverproxy_servers'):
    if ep.name == 'vscode':
        result = ep.load()()
        print('command:', result.get('command'))
"
# 應該見到: ['code-server', '--bind-addr=127.0.0.1:{port}', ...]
```

### /vscode/ 返回 404

```bash
# 檢查 code-server 有冇安裝
kubectl exec -n jupyterhub <pod> -- which code-server

# 手動啟動 code-server 測試
kubectl exec -n jupyterhub <pod> -- code-server --bind-addr=127.0.0.1:9999 --auth=none /home/jovyan
```

### code-server 啟動失敗

```bash
# 檢查 code-server log
kubectl exec -n jupyterhub <pod> -- cat ~/.local/share/code-server/logs/**/code-server.log
```

---

## 版本資訊

| 項目 | 內容 |
|------|------|
| 版本 | 1.0 |
| 建立日期 | 2026-09-22 |
| Base image | quay.io/jupyter/datascience-notebook:latest (Python 3.13) |
| Image tag | quay.io/rke2/jupyter-datascience:v1.0-ai |
| JupyterLab | 4.6.x |
| jupyter-ai | >=3.1.0 |
| code-server | 4.138.0 |
| jupyter-server-proxy | 4.5.0 |

---

## 授權

此指南僅供內部使用。

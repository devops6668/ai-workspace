# Jupyter-AI Docker 部署指南 v3.2.0-v1.5

## 目录

- [版本信息](#版本信息)
- [已修复的问题](#已修复的问题)
- [Dockerfile](#dockerfile)
- [Chat History 控制](#chat-history-控制)
  - [方法一：JupyterLab UI 设置（推荐）](#方法一jupyterlab-ui-设置推荐)
  - [方法二：config.json 直接编辑](#方法二configjson-直接编辑)
  - [方法三：Token-aware jupyternaut patch（最有效）](#方法三token-aware-jupyternaut-patch最有效)
- [Helm Values 配置](#helm-values-配置)
  - [JupyterHub Helm Chart 4.x 注意事项](#jupyterhub-helm-chart-4x-注意事项)
  - [注入 API Key](#注入-api-key)
  - [Chat History 配置 via extraFiles](#chat-history-配置-via-extrafiles)
- [版本兼容性矩阵](#版本兼容性矩阵)
- [常见问题排查](#常见问题排查)

---

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| jupyter-ai | 3.0.1 | 最后稳定版本 |
| jupyter-ai-jupyternaut | 0.0.11 | 默认 AI persona |
| jupyter-ai-persona-manager | 0.0.11+ | persona 管理器（已 patch send_message） |
| jupyter-ai-litellm | 0.0.2+ | LiteLLM 模型抽象层 |
| jupyterlab-chat | 0.22.1 | Chat UI 前端 |
| litellm | >=1.0.0 | 模型调用后端 |
| aiosqlite | >=0.20.0 | SQLite 异步接口 |
| langgraph-checkpoint-sqlite | >=3.0.0 | LangGraph 对话历史存储 |

---

## 已修复的问题

### 1. send_message 两参数 Bug（上游 Bug）

**问题**：所有版本的 `jupyter-ai-jupyternaut`（0.0.8 - 0.0.11）调用 `send_message(body, subtitle)` 两个参数，但 `jupyter-ai-persona-manager` 的 `send_message` 只接受一个参数。

```
TypeError: BasePersona.send_message() takes 2 positional arguments but 3 were given
```

**修复**：Dockerfile 中用 `python3 -c` 直接 patch `base_persona.py`，给 `send_message` 加上 `subtitle` 可选参数。

### 2. 缺少 Node.js

jupyter-ai v3.x 的 prebuilt extension 构建需要 Node.js。

### 3. 缺少依赖包

- `aiosqlite`：jupyter-ai-jupyternaut 的隐式依赖
- `langgraph-checkpoint-sqlite`：LangGraph SQLite checkpointer，jupyternaut 用来存储对话历史
- `litellm`：模型调用后端

### 4. 不能用 jupyter-ai 3.2.0+

3.2.0 拉取 `jupyter-ai-jupyternaut >= 0.1.0rc0` + `jupyter-ai-persona-manager >= 0.2.0`，这些预发布版本之间 API 不兼容（send_message 两参数 bug 尚未修复）。

---

## Dockerfile

```dockerfile
# 使用指定的 base image
FROM quay.io/jupyter/datascience-notebook:python-3.12.11

# 切换到 root 用户以安装软件
USER root

# 安装 Node.js 20（jupyter-ai v3.x 扩展构建需要）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl build-essential && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 更新 pip 并安装 Jupyter AI 3.0.1（稳定版本）
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    "jupyterlab>=4.4.0,<5.0.0" \
    "jupyter-ai[jupyternaut]==3.0.1" \
    "jupyter-ai-persona-manager>=0.0.11,<0.1.0" \
    "jupyter-ai-jupyternaut>=0.0.11,<0.1.0" \
    "jupyter-ai-litellm>=0.0.2,<0.1.0" \
    "litellm>=1.0.0" \
    "aiosqlite>=0.20.0" \
    "langgraph-checkpoint-sqlite>=3.0.0"

# 修补 persona-manager 的 send_message 方法
# jupyternaut 调用 send_message(body, subtitle) 两个参数，
# 但 persona-manager 只接受一个参数，是上游 bug。
RUN python3 -c "import pathlib; import jupyter_ai_persona_manager; bp=pathlib.Path(jupyter_ai_persona_manager.__file__).parent/'base_persona.py'; s=bp.read_text(); s=s.replace('def send_message(self, body: str) -> None:', 'def send_message(self, body: str, subtitle: str = \\\"\\\") -> None:'); bp.write_text(s); print('Patched send_message')"

# 切换回默认用户
USER ${NB_UID}

# 设置工作目录
WORKDIR /home/${NB_USER}/work

# 暴露 Jupyter Lab 端口
EXPOSE 8888

# 启动 Jupyter Lab
CMD ["start-notebook.sh"]
```

Build：

```bash
docker build -t quay.io/paulwong6668/jupyter-ai-agnes:v3.2.0-v1.5 \
  -f /tmp/jupyter-ai-dockerfile .
```

---

## Chat History 控制

jupyter-ai v3.x 使用 **LangGraph + SQLite checkpointer** 存储所有对话历史。每条消息都保存在 `/home/<user>/.local/share/jupyter/jupyter_ai/memory.sqlite`，每次对话时加载全部历史作为 context。**没有任何内置机制限制对话历史数量。**

> **核心问题**：对话越长，context 越大，最终超出模型 context window 导致错误。

### 方法一：JupyterLab UI 设置（推荐）

在 JupyterLab 中：

1. **Settings > AI Settings > 选择模型 > "+ Add Parameter"**
2. 添加 `max_tokens` 参数
3. 设定值（控制模型输出长度，间接减少 context 压力）

| 模型 | Context Window | 建议 max_tokens |
|------|---------------|-----------------|
| 本地小模型 (Llama 3 8K) | 8,192 | 256 |
| 中型模型 (Mistral 32K) | 32,768 | 2,048 |
| agnes-2.0-flash | 524,288 | 8,192 |
| 大模型 (Qwen 2.5 128K) | 131,072 | 4,096 |

> **⚠️ max_tokens 设太大会更糟！** 它保留 token 给输出，留给输入的就少了。
> 经验法则：max_tokens ≤ context window 的 25%。

### 方法二：config.json 直接编辑

```python
import json

config_path = '/home/jovyan/.local/share/jupyter/jupyter_ai/config.json'
with open(config_path, 'r') as f:
    config = json.load(f)

model_id = config['model_provider_id']
config['fields'] = config.get('fields', {})
config['fields'][model_id] = {'max_tokens': 2048}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
```

> **注意**：Pod 重启后 config.json 的修改会丢失。

### 方法三：Token-aware jupyternaut patch（最有效）

Patch `jupyternaut.py`，在调用 agent 之前自动截断历史：

- 使用 `tiktoken` 计算真实 token 数
- 保留最近的消息直到 token 数达到阈值
- 操作的是 LangGraph 的 `AsyncSqliteSaver`（msgpack 格式，不能用 json.loads）

**详细代码**：参考 `references/v3-chat-history-patch.md`

**持久化方式**：通过 Helm `extraFiles` 或 bake 进 Dockerfile。

### 手动方式

在 Chat 面板输入 `/clear` 重置历史，或新建一个 `.chat` 文件。

---

## Helm Values 配置

### JupyterHub Helm Chart 4.x 注意事项

> **⚠️ `singleuser.extraArgs`、`singleuser.extraVolumes`、`singleuser.extraVolumeMounts` 在 Helm chart 4.x 中不存在！**

可用的 singleuser 配置项：

| 配置项 | 状态 |
|--------|------|
| `singleuser.extraEnv` | ✅ 可用 |
| `singleuser.extraFiles` | ✅ 可用 |
| `singleuser.storage.extraVolumes` | ✅ 可用（在 storage 子键下） |
| `singleuser.storage.extraVolumeMounts` | ✅ 可用（在 storage 子键下） |
| `singleuser.extraArgs` | ❌ 不存在 |
| `singleuser.extraVolumes` | ❌ 不存在 |
| `singleuser.extraVolumeMounts` | ❌ 不存在 |

### 注入 API Key

```yaml
singleuser:
  extraEnv:
    OPENAI_API_BASE: "https://apihub.agnes-ai.com/v1"
    OPENAI_API_KEY: "sk-xxxxx"
```

或使用 Kubernetes Secret：

```yaml
singleuser:
  extraEnv:
    OPENAI_API_BASE: "https://apihub.agnes-ai.com/v1"
    OPENAI_API_KEY:
      valueFrom:
        secretKeyRef:
          name: agnes-api-key
          key: OPENAI_API_KEY
```

> **注意**：`config.json` 没有 `api_base` 字段。API base URL 必须通过环境变量 `OPENAI_API_BASE` 或 `.env` 文件设置。

### Chat History 配置 via extraFiles

**jupyter-ai 3.0.x 不支持** `AiExtension.default_max_chat_history`（只在 3.2.0+ 才有，但 3.2.0 有 send_message bug）。

因此 3.0.1 的 chat history 控制方式：

**方式 A**：JupyterLab UI 设 max_tokens（见上方方法一）

**方式 B**：注入 token-aware patch（推荐用于本地小模型）

```yaml
singleuser:
  extraFiles:
    jupyternaut-patch:
      mountPath: /opt/conda/lib/python3.12/site-packages/jupyter_ai_jupyternaut/jupyternaut/jupyternaut.py
      stringData: |
        # 完整的已 patch 的 jupyternaut.py 文件内容
        # 先从运行中的 pod 复制出来：
        # kubectl cp <pod>:/opt/conda/lib/python3.12/site-packages/jupyter_ai_jupyternaut/jupyternaut/jupyternaut.py ./jupyternaut_patched.py
```

**方式 C**：通过 Helm values 注入 `.env` 文件

```yaml
singleuser:
  extraFiles:
    ai-env:
      mountPath: /home/jovyan/.env
      stringData: |
        OPENAI_API_BASE=https://apihub.agnes-ai.com/v1
        OPENAI_API_KEY=sk-xxxxx
```

### 完整示例 Helm Values

```yaml
singleuser:
  image:
    name: quay.io/paulwong6668/jupyter-ai-agnes
    tag: v3.2.0-v1.5

  extraEnv:
    OPENAI_API_BASE: "https://apihub.agnes-ai.com/v1"
    OPENAI_API_KEY: "sk-xxxxx"

  extraFiles:
    ai-env:
      mountPath: /home/jovyan/.env
      stringData: |
        OPENAI_API_BASE=https://apihub.agnes-ai.com/v1
        OPENAI_API_KEY=sk-xxxxx
```

---

## 版本兼容性矩阵

| jupyter-ai | jupyterlab-chat | 需要 JupyterLab | send_message bug |
|---|---|---|---|
| 3.0.1 | 0.22.1 | >=4.4.0 | ⚠️ 有（需 patch） |
| 3.1.x | 0.23.x | >=4.4.0 | ⚠️ 有 + labextension 失败 |
| 3.2.0 | 0.25.0 | >=4.5.0 | ⚠️ 有 + 依赖预发布版 |

> **结论**：目前唯一可用的稳定组合是 **jupyter-ai 3.0.1 + patch send_message**。
> 等上游修复 send_message bug 后才能升级到 3.2.0+。

---

## 常见问题排查

### "No chat model is configured"

`model_provider_id` 为 null。在 JupyterLab UI 的 **Settings > AI Settings** 中选择模型。

### Chat 面板无响应

```bash
kubectl exec -n jupyterhub <pod> -- jupyter labextension list 2>&1 | grep chat
```

显示 `X` 而非 `OK` 表示版本不兼容。

### "is not in root static directory" (403)

JupyterHub 5.x 阻止扩展静态文件。修复：

```yaml
# 通过 ConfigMap 注入 jupyter_server_config.py
c.ServerApp.extra_static_paths = [
    '/opt/conda/share/jupyter/labextensions/jupyterlab-chat-extension/static',
]
```

### Secret 挂载的 .py 文件阻止 pip 升级

```bash
# 先移除 extraFiles 中的条目
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub -f values.yaml
kubectl delete pod -n jupyterhub <user-pod>
# 在新 pod 中 pip install
# 重新添加 extraFiles
```

### "Invalid token" from agnes-ai

API key 过期。更新 Secret 并重启 pod：

```bash
kubectl create secret generic agnes-api-key -n jupyterhub \
  --from-literal=OPENAI_API_KEY=sk-real-key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete pod -n jupyterhub <user-pod>
```

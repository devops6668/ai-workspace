# JupyterHub GitHub Copilot Integration Guide / JupyterHub GitHub Copilot 集成指南

## Overview / 概述

This guide covers two approaches to add AI-powered coding assistance to JupyterHub on Kubernetes:

本指南介绍两种在 Kubernetes 上的 JupyterHub 中添加 AI 编码辅助的方法：

| Option | Image | Description |
|--------|-------|-------------|
| Option 1 | `quay.io/paulwong6668/jupyter-copilot:1.0` | JupyterLab + GitHub Copilot (lightweight) |
| Option 2 | `quay.io/paulwong6668/jupyter-vscode-copilot:1.4` | VS Code + Notebook Intelligence (multi-provider) |

---

## Option 1: JupyterLab Copilot (Lightweight)

### Features / 功能
- Inline code completions via GitHub Copilot
- Native GitHub authentication
- Lightweight image (~1.5GB)

### Prerequisites / 前提条件
- Individual GitHub Copilot subscription per user
- Network access to `api.github.com` and `copilot-proxy.githubusercontent.com`

### Usage / 使用方法

1. **Spawn notebook** with profile `jupyter-copilot`
2. **Authenticate**: Open Command Palette (`Ctrl+Shift+C`) → "Sign In With GitHub"
3. **Start coding**: Copilot provides inline suggestions automatically

### Dockerfile / Dockerfile

```dockerfile
FROM jupyter/minimal-notebook:python-3.11

# Install GitHub Copilot extension for JupyterLab
# https://pypi.org/project/jupyter-copilot/
RUN pip install --no-cache-dir jupyter_copilot

LABEL maintainer="paulwong6668"
LABEL description="JupyterHub singleuser with GitHub Copilot"
LABEL version="1.0"

CMD ["jupyterhub-singleuser"]
```

### Build & Push / 构建和推送

```bash
cd /home/paul/Documents/ai-workspace/jupyterhub-copilot/option1-copilot

# Build
docker build -t quay.io/paulwong6668/jupyter-copilot:1.0 .

# Push
docker push quay.io/paulwong6668/jupyter-copilot:1.0
```

---

## Option 2: VS Code + Notebook Intelligence (Recommended)

### Features / 功能
- Full VS Code experience in browser via code-server
- Notebook Intelligence supports multiple AI providers:
  - GitHub Copilot
  - OpenAI-compatible endpoints
  - Ollama (local models)
  - Anthropic Claude
- Pre-installed Python extensions (Ruff, Jupyter)

### Prerequisites / 前提条件
- GitHub Copilot subscription (or other AI provider)
- Network access to AI provider APIs

### Usage / 使用方法

1. **Spawn notebook** with profile `jupyter-vscode-copilot`
2. **Open VS Code**: Click the "VSCode Web IDE" icon in JupyterLab launcher
3. **Connect AI provider**: Notebook Intelligence settings in JupyterLab
   - For GitHub Copilot: Settings → Notebook Intelligence → Provider → GitHub Copilot
4. **Start coding**: AI assistance available in VS Code

### Dockerfile / Dockerfile

```dockerfile
FROM jupyter/minimal-notebook:python-3.11

# Upgrade JupyterLab to 4.2+ (required by notebook-intelligence)
RUN pip install --no-cache-dir "jupyterlab>=4.2.0,<4.3.0"

# Install Notebook Intelligence (multi-provider AI assistant)
# Supports: GitHub Copilot, OpenAI, Ollama, Anthropic Claude
# https://github.com/plmbr/notebook-intelligence
RUN pip install --no-cache-dir notebook-intelligence

# Install code-server (VS Code in browser)
USER root
RUN curl -fsSL https://code-server.dev/install.sh | sh
USER ${NB_UID}

# Install JupyterLab code-server integration
# https://github.com/pc2/jupyter-code-server
RUN pip install --no-cache-dir jupyter-code-server

# Install VS Code extensions for Python development
RUN code-server --install-extension ms-python.python && \
    code-server --install-extension charliermarsh.ruff && \
    code-server --install-extension ms-toolsai.jupyter

LABEL maintainer="paulwong6668"
LABEL description="JupyterHub singleuser with VS Code + Notebook Intelligence"
LABEL version="1.1"

CMD ["jupyterhub-singleuser"]
```

### Build & Push / 构建和推送

```bash
cd /home/paul/Documents/ai-workspace/jupyterhub-copilot/option2-vscode

# Build
docker build -t quay.io/paulwong6668/jupyter-vscode-copilot:1.4 .

# Push
docker push quay.io/paulwong6668/jupyter-vscode-copilot:1.4
```

---

## Helm Configuration / Helm 配置

Add to your JupyterHub values:

```yaml
singleuser:
  profileList:
    - display_name: "Jupyter Copilot"
      description: "JupyterLab with GitHub Copilot"
      kubespawner_override:
        image: quay.io/paulwong6668/jupyter-copilot:1.0

    - display_name: "VS Code + AI"
      description: "VS Code with Notebook Intelligence (Copilot/OpenAI/Ollama)"
      kubespawner_override:
        image: quay.io/paulwong6668/jupyter-vscode-copilot:1.4
```

Or upgrade via CLI:

```bash
# Option 1
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub \
  --kubeconfig /home/paul/.kube/k3s.yaml \
  --set 'singleuser.profileList[3].kubespawner_override.image=quay.io/paulwong6668/jupyter-copilot:1.0'

# Option 2
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub \
  --kubeconfig /home/paul/.kube/k3s.yaml \
  --set 'singleuser.profileList[3].kubespawner_override.image=quay.io/paulwong6668/jupyter-vscode-copilot:1.4'
```

---

## HTTP Proxy Configuration / HTTP 代理配置

If you need to configure HTTP proxy for the singleuser pods:

```yaml
singleuser:
  extraEnv:
    http_proxy: http://your-proxy:8080
    https_proxy: http://your-proxy:8080
    no_proxy: localhost,127.0.0.1,10.42.0.0/16,192.168.0.0/16,.svc,.cluster.local
```

---

## Troubleshooting / 故障排除

### VS Code icon not showing / VS Code 图标不显示

1. Check JupyterLab version: `jupyter labextension list`
   - notebook-intelligence requires JupyterLab >=4.2.0
2. Check extension installed: `pip list | grep notebook-intelligence`
3. Check code-server installed: `which code-server`
4. Check proxy config: `cat /home/jovyan/.jupyter/jupyter_server_config.d/code-server.py`
5. Check server logs for proxy errors: `jupyter server log`

### GitHub Copilot authentication failed / GitHub Copilot 认证失败

1. Ensure user has active GitHub Copilot subscription
2. Check network access to GitHub APIs
3. Try re-authenticating via Command Palette → "Sign In With GitHub"

### Build errors / 构建错误

- `jupyterlab-copilot` does not exist on PyPI → use `jupyter_copilot`
- `jupyterlab-code-server` does not exist on PyPI → use `jupyter-code-server`
- Pylance not available for code-server → use Ruff extension instead
- `jupyter-code-server` entry point may fail with jupyter-server-proxy 4.5+ → use manual config in `jupyter_server_config.d/`

---

## References / 参考资料

- [jupyter_copilot](https://pypi.org/project/jupyter-copilot/)
- [Notebook Intelligence](https://github.com/plmbr/notebook-intelligence)
- [jupyter-code-server](https://github.com/pc2/jupyter-code-server)
- [code-server](https://github.com/coder/code-server)
- [Jupyter Docker Stacks](https://jupyter-docker-stacks.readthedocs.io/)

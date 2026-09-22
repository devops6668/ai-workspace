# =============================================================================
# Jupyter AI v3.x + VS Code (code-server) + notebook-intelligence
# Base: quay.io/jupyter/datascience-notebook:latest
# =============================================================================
# Combines:
#   - Dockerfile.datascience (jupyter-ai v3.x + LiteLLM + Node.js)
#   - option2-vscode (code-server + jupyter-server-proxy + VS Code extensions)
#   - notebook-intelligence (Copilot/OpenAI/Ollama/Claude inside JupyterLab)
# =============================================================================

FROM quay.io/jupyter/datascience-notebook:latest

LABEL maintainer="Paul Wong"
LABEL description="datascience-notebook + jupyter-ai v3.x + VS Code + notebook-intelligence"
LABEL version="1.0"

# =============================================================================
# 1. System Dependencies (Node.js for ACP agents + code-server prereqs)
# =============================================================================
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 2. Install code-server (VS Code in browser)
# =============================================================================
RUN curl -fsSL https://code-server.dev/install.sh | sh

# Switch back to non-root for pip installs
USER ${NB_UID}

# =============================================================================
# 3. Install jupyter-ai v3.x + notebook-intelligence + jupyter-server-proxy
# =============================================================================
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
    # jupyter-ai v3.x
    "jupyter-ai[jupyternaut]>=3.1.0" \
    litellm>=1.0.0 \
    # notebook-intelligence (Copilot/OpenAI/Ollama/Claude in JupyterLab)
    notebook-intelligence \
    # jupyter-server-proxy (expose code-server in JupyterLab launcher)
    jupyter-server-proxy

# =============================================================================
# 4. code-server proxy package
#    Registers code-server as a JupyterLab launcher tile via
#    jupyter-server-proxy entry points
# =============================================================================
COPY --chown=${NB_UID}:${NB_GID} code_server_proxy.py \
    /opt/conda/lib/python3.13/site-packages/jupyter_code_server_proxy/__init__.py
COPY --chown=${NB_UID}:${NB_GID} entry_points.txt \
    /opt/conda/lib/python3.13/site-packages/jupyter_code_server_proxy-1.0.dist-info/entry_points.txt
COPY --chown=${NB_UID}:${NB_GID} METADATA \
    /opt/conda/lib/python3.13/site-packages/jupyter_code_server_proxy-1.0.dist-info/METADATA
COPY --chown=${NB_UID}:${NB_GID} top_level.txt \
    /opt/conda/lib/python3.13/site-packages/jupyter_code_server_proxy-1.0.dist-info/top_level.txt

# =============================================================================
# 5. Install VS Code extensions for Python development
# =============================================================================
RUN code-server --install-extension ms-python.python \
    && code-server --install-extension charliermarsh.ruff \
    && code-server --install-extension ms-toolsai.jupyter

# =============================================================================
# 6. Environment Variables
# =============================================================================
ENV OPENAI_API_BASE="" \
    OPENAI_API_KEY="" \
    JUPYTER_ENABLE_LAB="yes"

# =============================================================================
# 7. Health Check
# =============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8888/api || exit 1

# =============================================================================
# 8. Default command
# =============================================================================
CMD ["start-notebook.sh"]

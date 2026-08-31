# Option 2: JupyterHub with VS Code (code-server) + Notebook Intelligence
# Base: Jupyter Docker Stacks minimal-notebook with JupyterLab 4.2+
FROM jupyter/minimal-notebook:python-3.11

# Upgrade JupyterLab to 4.2+ for notebook-intelligence compatibility
RUN pip install --no-cache-dir "jupyterlab>=4.2.0,<4.3.0"

# Install notebook-intelligence (comprehensive AI assistant for JupyterLab)
# Supports GitHub Copilot, OpenAI-compatible, Ollama, Anthropic Claude
# https://github.com/plmbr/notebook-intelligence
RUN pip install --no-cache-dir notebook-intelligence

# Install code-server (VS Code in browser) for full VS Code experience
USER root
RUN curl -fsSL https://code-server.dev/install.sh | sh
USER ${NB_UID}

# Install jupyter-server-proxy (includes Python package + JupyterLab extension)
RUN pip install --no-cache-dir jupyter-server-proxy

# Create code-server proxy package with _jupyter_server_proxy_servers entry point
COPY --chown=${NB_UID}:${NB_GID} code_server_proxy.py /opt/conda/lib/python3.11/site-packages/jupyter_code_server_proxy/__init__.py
COPY --chown=${NB_UID}:${NB_GID} entry_points.txt /opt/conda/lib/python3.11/site-packages/jupyter_code_server_proxy-1.0.dist-info/entry_points.txt
COPY --chown=${NB_UID}:${NB_GID} METADATA /opt/conda/lib/python3.11/site-packages/jupyter_code_server_proxy-1.0.dist-info/METADATA
COPY --chown=${NB_UID}:${NB_GID} top_level.txt /opt/conda/lib/python3.11/site-packages/jupyter_code_server_proxy-1.0.dist-info/top_level.txt

# Install VS Code extensions for Python development
RUN code-server --install-extension ms-python.python && \
    code-server --install-extension charliermarsh.ruff && \
    code-server --install-extension ms-toolsai.jupyter

# Labels
LABEL maintainer="paulwong6668"
LABEL description="JupyterHub singleuser with VS Code (code-server) + Notebook Intelligence (Copilot/OpenAI/Ollama)"
LABEL version="1.4"

# Default command
CMD ["jupyterhub-singleuser"]

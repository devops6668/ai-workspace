# ============================================================
# Jupyter AI + LiteLLM Magic Commands Image
# ============================================================
# Build:
#   docker build -t quay.io/paulwong6668/jupyter-ai:latest .
#   docker push quay.io/paulwong6668/jupyter-ai:latest
#
# Run:
#   docker run -p 8888:8888 quay.io/paulwong6668/jupyter-ai:latest
#
# Environment variables (set in JupyterHub Helm values):
#   OPENAI_API_KEY    - litellm master key
#   OPENAI_API_BASE   - litellm endpoint (e.g., http://192.168.89.61:31275/v1)
# ============================================================

FROM quay.io/jupyter/minimal-notebook:python-3.11

# Metadata
LABEL maintainer="Paul Wong <paul@devops6668>"
LABEL description="Jupyter AI with magic commands for LiteLLM proxy"
LABEL io.paulwong.version="1.0"

# Switch to root for system packages
USER root

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Switch back to notebook user
USER ${NB_UID}

# ============================================================
# Core Jupyter AI packages
# ============================================================

# jupyter-ai-magic-commands: %%ai cell magic, %ai line magic
#   depends on jupyter-ai-litellm (pins litellm<=1.82.6)
#   depends on: click, ipython, pydantic
RUN pip install --no-cache-dir \
    jupyter-ai-magic-commands==0.0.3

# ============================================================
# Useful Python packages (optional — add as needed)
# ============================================================

RUN pip install --no-cache-dir \
    pandas \
    numpy \
    matplotlib \
    seaborn \
    scikit-learn \
    requests \
    httpx

# ============================================================
# Pre-configure aliases (optional)
# ============================================================

# Create ipython_config.py with default aliases
RUN mkdir -p ~/.ipython/profile_default && \
    echo 'c.AiMagics.aliases = {\n\
    "ornith": "custom_openai/ornith",\n\
    "agnes": "custom_openai/agnes"\n\
}\n\
c.AiMagics.initial_language_model = "custom_openai/ornith"\n' \
    > ~/.ipython/profile_default/ipython_config.py

# ============================================================
# Verify installation
# ============================================================

RUN python -c "import jupyter_ai_magic_commands; print('jupyter-ai-magic-commands OK')" && \
    python -c "import litellm; print(f'litellm {litellm.__version__} OK')" && \
    python -c "import pandas; print(f'pandas {pandas.__version__} OK')" && \
    python -c "import numpy; print(f'numpy {numpy.__version__} OK')"

# ============================================================
# Healthcheck
# ============================================================

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8888/api/status || exit 1

# ============================================================
# Ports
# ============================================================

EXPOSE 8888

# JupyterHub singleuser entrypoint is set by the hub
# For standalone: jupyterhub-singleuser or jupyter-lab

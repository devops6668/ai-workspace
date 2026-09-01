# =============================================================================
# JupyterHub + jupyter-ai v3.x + LiteLLM + Data Science Stack
# Target: K8s (JupyterHub) for Data Science team
# =============================================================================

FROM quay.io/jupyterhub/k8s-hub:4.1.0

LABEL maintainer="Paul Wong <paul@devops.local>"
LABEL description="JupyterHub image with jupyter-ai v3.x, LiteLLM, and data science tools"

# =============================================================================
# 1. System Dependencies
# =============================================================================
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    build-essential \
    libpq-dev \
    default-libmysqlclient-dev \
    libffi-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    libjpeg-dev \
    libpng-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 2. Node.js (for ACP agents like Claude Code, Codex)
# =============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 3. Install Python Packages
# =============================================================================

# Data Science Core
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Data Science Libraries
RUN pip install --no-cache-dir \
    # Data manipulation
    pandas \
    numpy \
    scipy \
    polars \
    # Visualization
    matplotlib \
    seaborn \
    plotly \
    bokeh \
    altair \
    # Machine Learning
    scikit-learn \
    xgboost \
    lightgbm \
    catboost \
    # NLP
    nltk \
    spacy \
    transformers \
    tokenizers \
    # Data IO
    pyarrow \
    fastparquet \
    openpyxl \
    xlsxwriter \
    sqlalchemy \
    psycopg2-binary \
    pymysql \
    # HTTP/API
    requests \
    httpx \
    pydantic \
    # Utilities
    tqdm \
    joblib \
    python-dotenv \
    pyyaml \
    rich \
    black \
    ruff \
    # Jupyter ecosystem
    jupyterlab \
    ipywidgets \
    nbconvert \
    ipykernel

# =============================================================================
# 4. jupyter-ai v3.x (with Jupyternaut persona)
# =============================================================================
RUN pip install --no-cache-dir \
    "jupyter-ai[jupyternaut]>=3.1.0" \
    litellm

# =============================================================================
# 5. JupyterLab Extension Enable
# =============================================================================
# v3.x 係 prebuilt extension，pip install 即自動 enable，唔需要手動 enable
# 如果需要驗證，可以執行: jupyter server extension list

# =============================================================================
# 6. User Environment
# =============================================================================
USER ${NB_UID}

# Default environment variables
ENV OPENAI_API_BASE="" \
    OPENAI_API_KEY="" \
    JUPYTER_ENABLE_LAB="yes" \
    JUPYTER_TOKEN="" \
    NB_USER="jovyan" \
    NB_UID=1000 \
    NB_GID=100 \
    HOME=/home/jovyan

# =============================================================================
# 7. Health Check
# =============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8888/hub/api/ || exit 1

# =============================================================================
# 8. Expose Ports
# =============================================================================
# 8888: JupyterHub
EXPOSE 8888

# =============================================================================
# 9. Entrypoint
# =============================================================================
ENTRYPOINT ["tini", "--"]
CMD ["jupyterhub"]

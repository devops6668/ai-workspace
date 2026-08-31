# Option 1: JupyterHub with GitHub Copilot Extension
# Base: Jupyter Docker Stacks minimal-notebook
FROM jupyter/minimal-notebook:python-3.11

# Install jupyter_copilot extension (GitHub Copilot for JupyterLab)
# Package: https://pypi.org/project/jupyter-copilot/
RUN pip install --no-cache-dir jupyter_copilot

# Labels
LABEL maintainer="paulwong6668"
LABEL description="JupyterHub singleuser with GitHub Copilot extension"
LABEL version="1.0"

# Default command
CMD ["jupyterhub-singleuser"]

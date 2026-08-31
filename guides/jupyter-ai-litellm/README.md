# Jupyter AI + LiteLLM Installation Guide

Connecting JupyterHub notebooks to LiteLLM proxy for AI-powered chat via magic commands.

**Target environment:** k3s single-node cluster (192.168.89.61), Helm-managed JupyterHub + LiteLLM

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  k3s Node (192.168.89.61)                           │
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
│  │ Backend Models               │                   │
│  │ - ornith (Tailscale:100.x)  │                   │
│  │ - agnes  (apihub.agnes-ai)  │                   │
│  └──────────────────────────────┘                   │
└─────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Component | Version | Namespace | Access |
|-----------|---------|-----------|--------|
| k3s | v1.33.0 | - | 192.168.89.61 |
| JupyterHub (Helm) | jupyterhub-4.2.0 (app 5.3.0) | jupyterhub | NodePort 31929 |
| LiteLLM (Helm) | litellm-helm-1.1.0 (v1.85.1) | litellm | NodePort 31275 |
| PostgreSQL (Helm) | postgresql-18.7.13 (bitnami) | litellm | ClusterIP |
| NFS CSI | v4.7.0 | kube-system | - |

---

## Step 1: Verify LiteLLM is Running

```bash
# Check litellm pod status
kubectl get pods -n litellm

# Verify health endpoint
kubectl exec -n litellm litellm-798df8b5c6-sscl7 -- curl -s http://localhost:4000/health/liveliness

# Check available models in litellm config
kubectl get configmap litellm-config -n litellm -o yaml
```

Expected litellm config:

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

## Step 2: Verify JupyterHub is Running

```bash
# Check hub and proxy pods
kubectl get pods -n jupyterhub

# Check helm release
helm list -n jupyterhub

# Check singleuser image profiles
helm get values jupyterhub -n jupyterhub | grep -A5 "profileList"
```

---

## Step 3: Choose Singleuser Image

Your JupyterHub provides multiple image profiles. For AI magic commands, use the **AI Coding (Agnes)** profile:

| Profile | Image | Use Case |
|---------|-------|----------|
| AI Coding (Agnes) | `quay.io/paulwong6668/jupyter-ai-agnes:1.30-patched-final` | AI-powered chat with litellm |
| Minimal environment | `quay.io/paulwong6668/jupyter-dagster:1.0` | Basic Python (default) |
| Datascience environment | `quay.io/cen_ku/data-science:1.13` | Python + R + Julia |
| Spark environment | `jupyter/all-spark-notebook:x86_64-python-3.11.6` | Apache Spark |

When creating a notebook server, select **"AI Coding (Agnes)"** from the profile list.

---

## Step 4: Connect Notebook to LiteLLM

### 4.1 Load the Magic Commands Extension

```python
%load_ext jupyter_ai_magic_commands
```

### 4.2 Set API Key and Endpoint

```python
import os

# LiteLLM proxy settings
# API key = litellm master key (from secret litellm-masterkey)
os.environ["OPENAI_API_KEY"] = "sk-your-litellm-master-key"

# LiteLLM NodePort endpoint
os.environ["OPENAI_API_BASE"] = "http://192.168.89.61:31275/v1"
```

### 4.3 Verify Settings

```python
import os
print("API Key:", os.environ.get("OPENAI_API_KEY", "NOT SET")[:10] + "...")
print("API Base:", os.environ.get("OPENAI_API_BASE", "NOT SET"))
```

### 4.4 Register Model Aliases

```python
# Register ornith model (connects to litellm -> Tailscale ornith server)
%ai alias ornith custom_openai/ornith

# Register agnes model (connects to litellm -> agnes API)
%ai alias agnes custom_openai/agnes
```

### 4.5 Start Chatting

```python
%%ai ornith
What is the capital of France?
```

```python
%%ai agnes
Write a Python function to calculate factorial
```

---

## Step 5: Pre-configure for All Users (Optional)

To avoid requiring users to set env vars manually, add to JupyterHub Helm values:

```yaml
# helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub -f values.yaml
singleuser:
  extraEnv:
    OPENAI_API_KEY: "sk-your-litellm-master-key"
    OPENAI_API_BASE: "http://192.168.89.61:31275/v1"
```

Or create an `ipython_config.py` in the singleuser image with default aliases:

```python
# /etc/ipython/ipython_config.py
c.AiMagics.aliases = {
    "ornith": "custom_openai/ornith",
    "agnes": "custom_openai/agnes"
}
c.AiMagics.initial_language_model = "custom_openai/ornith"
```

---

## Troubleshooting

### "ModuleNotFoundError: No module named 'jupyter_ai_magic_commands'"

The magic commands package is not installed in the singleuser image.

```python
# Install in notebook cell
%pip install jupyter-ai-magic-commands
```

### "Connection refused" to litellm

```bash
# Verify litellm is running
kubectl get pods -n litellm

# Check NodePort is accessible
curl -s http://192.168.89.61:31275/health/liveliness

# Check litellm logs
kubectl logs -n litellm deployment/litellm --tail=50
```

### "AuthenticationError" from litellm

The API key must match the litellm master key:

```bash
# Get master key
kubectl get secret litellm-masterkey -n litellm -o jsonpath='{.data.masterkey}' | base64 -d
```

### Model not found in litellm

Check litellm config includes your model:

```bash
kubectl get configmap litellm-config -n litellm -o yaml
```

### litellm version mismatch

`jupyter-ai-litellm` pins `litellm<=1.82.6`, but your cluster runs v1.85.1. If you encounter issues:

```python
# Check installed litellm version
import litellm
print(litellm.__version__)

# If needed, pin to compatible version
%pip install litellm==1.82.6
```

---

## See Also

- [LiteLLM Production Deployment Guide](../litellm/litellm-production-deployment.md) — Official Helm deployment patterns, Redis setup, secrets management, production checklist
- [LiteLLM 生產環境部署指南](../litellm/litellm-production-deployment-zh.md) — 中文版

---

## Useful Commands

```bash
# JupyterHub status
kubectl get all -n jupyterhub

# LiteLLM status
kubectl get all -n litellm

# LiteLLM logs
kubectl logs -n litellm deployment/litellm -f

# JupyterHub logs
kubectl logs -n jupyterhub deployment/hub -f

# Helm releases
helm list -A | grep -E "jupyter|litellm"

# Restart litellm (after config changes)
kubectl rollout restart deployment/litellm -n litellm

# Restart JupyterHub hub (after values changes)
kubectl rollout restart deployment/hub -n jupyterhub
```

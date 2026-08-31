# LiteLLM Production Deployment Guide (k3s)

Official Helm deployment for LiteLLM proxy on k3s single-node cluster.

Based on [docs.litellm.ai/docs/proxy/deploy](https://docs.litellm.ai/docs/proxy/deploy).

**Target environment:** k3s single-node (192.168.89.61)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  k3s Node (192.168.89.61)                               │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ NS: litellm                                      │    │
│  │                                                  │    │
│  │  ┌─────────────┐    ┌──────────────────────┐    │    │
│  │  │ LiteLLM     │───▶│ PostgreSQL            │    │    │
│  │  │ (monolith)  │    │ (bitnami subchart)    │    │    │
│  │  │ Port: 4000  │    │ Port: 5432            │    │    │
│  │  │ NodePort:   │    │ PVC: 10Gi             │    │    │
│  │  │   31275     │    └──────────────────────┘    │    │
│  │  └──────┬──────┘                                │    │
│  │         │                                       │    │
│  │         ▼                                       │    │
│  │  ┌──────────────┐                               │    │
│  │  │ Redis        │                               │    │
│  │  │ (bitnami)    │                               │    │
│  │  │ Port: 6379   │                               │    │
│  │  └──────────────┘                               │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Deployment Mode

This guide uses **Monolithic** mode — one `litellm` image serves LLM traffic, management APIs, and the UI. This is the simplest to operate and matches the `litellm-helm` chart.

For microservices mode (gateway + backend + ui as separate services), see the official docs.

---

## Prerequisites

| Component | Required | Your Setup |
|-----------|----------|------------|
| Kubernetes | 1.24+ | k3s v1.33.0 |
| Helm | 3.x | Installed |
| PostgreSQL | 14+ | bitnami subchart in litellm NS |
| Redis | 6+ | To be installed |
| StorageClass | ReadWriteOnce | local-path, nfs-csi |

---

## Step 1: Create Secrets (Official Pattern)

The official chart expects three secrets:

```bash
# 1. Master key — admin key for the proxy
kubectl create secret generic litellm-masterkey \
  --from-literal=masterkey="sk-$(openssl rand -hex 24)" \
  -n litellm

# 2. Database credentials — PostgreSQL connection
kubectl create secret generic litellm-db \
  --from-literal=username=litellm \
  --from-literal=password="<your-database-password>" \
  -n litellm

# 3. Environment secrets — SALT_KEY, provider API keys, Redis password
kubectl create secret generic litellm-env \
  --from-literal=LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=REDIS_PASSWORD="<your-redis-password>" \
  --from-literal=OPENAI_API_KEY="<your-provider-key>" \
  -n litellm
```

> **Important:** `LITELLM_SALT_KEY` encrypts provider credentials stored in the database. Once set and models are added, DO NOT change it — credentials become unreadable. Generate a strong random value and store it safely.

---

## Step 2: Install Redis

LiteLLM requires Redis for rate limiting, router state, and caching.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis \
  --namespace litellm \
  --set architecture=standalone \
  --set auth.enabled=true \
  --set auth.existingSecret=litellm-env \
  --set auth.secretKeys.redisPasswordKey=REDIS_PASSWORD \
  --set master.persistence.size=1Gi \
  --set master.persistence.storageClass=local-path
```

Verify Redis is running:

```bash
kubectl get pods -n litellm | grep redis
```

---

## Step 3: Install PostgreSQL (if not present)

If you already have PostgreSQL from a previous install, skip this step.

```bash
helm install postgres bitnami/postgresql \
  --namespace litellm \
  --set auth.database=litellm \
  --set auth.username=litellm \
  --set auth.password="<your-database-password>" \
  --set primary.persistence.size=10Gi \
  --set primary.persistence.storageClass=local-path
```

---

## Step 4: Deploy LiteLLM with Helm

### values.yaml

```yaml
# LiteLLM Helm values — Official monolithic deployment
# Ref: https://docs.litellm.ai/docs/proxy/deploy#deploy-with-helm

replicaCount: 1  # Single node; use 3+ for HA

image:
  repository: ghcr.io/berriai/litellm-database
  tag: "v1.85.1"  # Pin version. Do NOT use :latest

# Master key from existing secret
masterkeySecretName: litellm-masterkey
masterkeySecretKey: masterkey

# PostgreSQL — use existing bitnami subchart
db:
  useExisting: true
  deployStandalone: false
  endpoint: "postgres-postgresql.litellm.svc.cluster.local"
  database: litellm
  secret:
    name: litellm-db
    usernameKey: username
    passwordKey: password

# Environment secrets (SALT_KEY, provider keys, Redis password)
environmentSecrets:
  - litellm-env

# LiteLLM proxy configuration
proxy_config:
  general_settings:
    master_key: os.environ/PROXY_MASTER_KEY
    store_model_in_db: true

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

  router_settings:
    redis_host: "redis-master.litellm.svc.cluster.local"
    redis_port: 6379
    redis_password: os.environ/REDIS_PASSWORD

  litellm_settings:
    DISABLE_SCHEMA_UPDATE: true
    LITELLM_SALT_KEY: os.environ/LITELLM_SALT_KEY
```

### Install

```bash
helm install litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm \
  -f values.yaml
```

### Upgrade

```bash
# Update image tag in values.yaml first, then:
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm \
  -f values.yaml
```

---

## Step 5: Verify Deployment

```bash
# Check all pods
kubectl get pods -n litellm

# Health check (from inside cluster)
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/health/liveliness

# Health check (from NodePort)
curl -s http://192.168.89.61:31275/health/liveliness

# Check logs
kubectl logs -n litellm deployment/litellm --tail=50

# List available models
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer <master-key>"
```

---

## Step 6: Connect JupyterHub

### Option A: Pre-configure env vars (Helm values)

```yaml
singleuser:
  extraEnv:
    OPENAI_API_KEY: "<master-key>"
    OPENAI_API_BASE: "http://192.168.89.61:31275/v1"
```

```bash
helm upgrade jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub -f values.yaml
```

### Option B: Secret injection (more secure)

```yaml
hub:
  extraConfig:
    litellm-env: |
      c.KubeSpawner.env_from = [
          {"secretRef": {"name": "litellm-client-creds"}}
      ]
```

```bash
kubectl create secret generic litellm-client-creds \
  --from-literal=OPENAI_API_KEY="<master-key>" \
  --from-literal=OPENAI_API_BASE="http://192.168.89.61:31275/v1" \
  -n jupyterhub
```

---

## Step 7: Use from Notebook

```python
%load_ext jupyter_ai_magic_commands

import os
os.environ["OPENAI_API_KEY"] = "<master-key>"
os.environ["OPENAI_API_BASE"] = "http://192.168.89.61:31275/v1"

%ai alias ornith custom_openai/ornith
%ai alias agnes custom_openai/agnes
```

```python
%%ai ornith
Hello, what can you do?
```

---

## Secrets Reference

| Secret Name | Keys | Purpose |
|-------------|------|---------|
| litellm-masterkey | `masterkey` | Admin key for proxy API |
| litellm-db | `username`, `password` | PostgreSQL credentials |
| litellm-env | `LITELLM_SALT_KEY`, `REDIS_PASSWORD`, `OPENAI_API_KEY` | Encryption, cache, provider access |

---

## Environment Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `PROXY_MASTER_KEY` | litellm-masterkey | Admin access to proxy |
| `LITELLM_SALT_KEY` | litellm-env | Encrypts provider creds in DB |
| `DATABASE_URL` | litellm-db + db endpoint | PostgreSQL connection string |
| `REDIS_PASSWORD` | litellm-env | Redis authentication |
| `STORE_MODEL_IN_DB` | config | Manage models from Admin UI |
| `DISABLE_SCHEMA_UPDATE` | config | Proxy pods skip migrations |

---

## Production Checklist

| Item | Recommendation | Status |
|------|---------------|--------|
| Pin image version | Specific tag, not :latest | OK (v1.85.1) |
| PostgreSQL | External or subchart | OK (bitnami subchart) |
| Redis | Required for rate limiting, caching | Installed |
| SALT_KEY | Generate, never rotate | Created |
| DISABLE_SCHEMA_UPDATE | true on proxy pods | Set in config |
| Replicas | 3+ for production | 1 (single-node) |
| Health probes | /health/liveliness, /health/readiness | Configured |
| Secrets | K8s secrets or cloud secret manager | K8s secrets |
| Ingress | Cloud LB or NodePort | NodePort 31275 |

---

## Upgrade Path

```bash
# 1. Check current version
helm list -n litellm

# 2. Update image.tag in values.yaml
#    image.tag: "v1.90.2"

# 3. Upgrade
helm upgrade litellm oci://ghcr.io/berriai/litellm-helm \
  --namespace litellm -f values.yaml

# 4. Verify
kubectl rollout status deployment/litellm -n litellm
kubectl exec -n litellm <pod> -- curl -s http://localhost:4000/health/liveliness
```

---

## Troubleshooting

### Redis connection refused

```bash
kubectl get pods -n litellm | grep redis
kubectl get svc -n litellm | grep redis
kubectl exec -n litellm <litellm-pod> -- \
  redis-cli -h redis-master.litellm.svc.cluster.local \
  -a <password> ping
```

### LITELLM_SALT_KEY not set

```bash
kubectl patch secret litellm-env -n litellm \
  -p '{"data":{"LITELLM_SALT_KEY":"'$(echo -n 'sk-your-salt-key' | base64)'"}}'
kubectl rollout restart deployment/litellm -n litellm
```

### Schema migration errors

```bash
# Check if DISABLE_SCHEMA_UPDATE is set
kubectl get deployment litellm -n litellm \
  -o jsonpath='{.spec.template.spec.containers[0].env}'

# Add if missing
kubectl set env deployment/litellm -n litellm DISABLE_SCHEMA_UPDATE=true
```

### Model not found in Admin UI

```bash
kubectl exec -n litellm <litellm-pod> -- \
  curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer <master-key>"
```

---

## Useful Commands

```bash
# Status
kubectl get all -n litellm

# Logs
kubectl logs -n litellm deployment/litellm -f

# Restart
kubectl rollout restart deployment/litellm -n litellm

# Helm
helm list -n litellm

# Secrets
kubectl get secrets -n litellm

# Config
kubectl get configmap litellm-config -n litellm -o yaml
```

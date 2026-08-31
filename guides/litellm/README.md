# LiteLLM Installation Guide for Kubernetes

Complete guide for installing LiteLLM proxy on Kubernetes with Gateway API and cert-manager.

## Architecture

```
Client
  → DNS: litellm.luban.paulhome.local → 192.168.89.61:443
    → Gateway (cilium, HTTPS:443, TLS terminated)
      → HTTPRoute (path: /v1, /ui, /)
        → Service: litellm.litellm.svc:4000
          → LiteLLM pod
            → PostgreSQL (external or Bitnami)
```

## Prerequisites

### Cluster Requirements

- **Kubernetes 1.25+** (k3s v1.28+ recommended)
- **Cilium CNI** (provides GatewayClass `cilium`)
- **cert-manager** installed:
  ```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
  ```
- **selfsigned-cluster-issuer** (or your preferred issuer)

### DNS

- `litellm.luban.paulhome.local` → `192.168.89.61` (or your k3s node IP)
- DNS server: `192.168.89.1` (or your internal DNS)

### Existing PostgreSQL (Recommended)

If you have PostgreSQL already running:
```bash
# Get credentials from secret
kubectl get secret -n litellm litellm-db-creds -o jsonpath='{.data}' | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print({k: base64.b64decode(v).decode() for k,v in d.items()})"
```

Or use the Bitnami Postgres chart:
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install postgres bitnami/postgresql -n litellm \
  --set auth.database=litellm \
  --set auth.username=litellm \
  --set auth.password="your-secure-password" \
  --set primary.persistence.size=5Gi
```

## Installation

### 1. Create Namespace

```bash
kubectl create namespace litellm
```

### 2. Create Secrets

#### Master Key (Admin)

```bash
MASTER_KEY="sk-$(openssl rand -hex 24)"
kubectl create secret generic litellm-masterkey \
  --from-literal=masterkey="$MASTER_KEY" \
  -n litellm
```

#### Salt Key (Encrypts provider credentials)

```bash
SALT_KEY="sk-$(openssl rand -hex 24)"
kubectl create secret generic litellm-env \
  --from-literal=LITELLM_SALT_KEY="$SALT_KEY" \
  -n litellm
```

> ⚠️ **Critical:** Never change `LITELLM_SALT_KEY` after adding models — stored credentials become unreadable.

#### Database Credentials (if using external Postgres)

```bash
kubectl create secret generic litellm-db \
  --from-literal=username=litellm \
  --from-literal=password="your-db-password" \
  -n litellm
```

### 3. Create values.yaml

Create `/tmp/litellm-values.yaml`:

```yaml
# LiteLLM Helm values for k3s single-node
replicaCount: 1

image:
  repository: ghcr.io/berriai/litellm-database
  tag: "v1.90.2"  # Pin version, don't use :latest

masterkeySecretName: litellm-masterkey
masterkeySecretKey: masterkey

# External Postgres (Bitnami or existing)
db:
  useExisting: true
  deployStandalone: false
  endpoint: "postgres-postgresql.litellm.svc"  # Your Postgres service
  database: litellm
  secret:
    name: litellm-db
    usernameKey: username
    passwordKey: password

# Environment secrets
environmentSecrets:
  - litellm-env

# Models (add your custom providers)
proxy_config:
  model_list:
    # Example: OpenAI GPT-4o
    - model_name: gpt-4o
      litellm_params:
        model: openai/gpt-4o
        api_key: os.environ/OPENAI_API_KEY
    
    # Example: Custom OpenAI provider
    - model_name: custom_openai/agnes-2.0-flash
      litellm_params:
        api_base: "https://agnes.ai/v1"
        api_key: "your-agents-key"
        model: "agnes-2.0-flash"
        api_type: openai
    
    # Example: Local GGUF model
    - model_name: custom_openai/Ornith-1.0-35B-GGUF:Q4_K_M
      litellm_params:
        api_base: "http://cenmac-mini.local:1234/v1"
        model: "deepreinforce-ai/Ornith-1.0-35B-GGUF:Q4_K_M"
        api_type: openai

# Optional: Redis for rate limiting (single node: skip)
# router_settings:
#   redis_host: "redis.litellm.svc"
#   redis_port: 6379
#   redis_password: os.environ/REDIS_PASSWORD

# Optional: Environment variables
# env:
#   - name: STORE_MODEL_IN_DB
#     value: "true"
#   - name: DISABLE_SCHEMA_UPDATE
#     value: "false"  # First install
```

### 4. Install LiteLLM

```bash
helm install litellm oci://ghcr.io/berriai/litellm-helm \
  -f /tmp/litellm-values.yaml \
  -n litellm
```

### 5. Verify Installation

```bash
# Check pods
kubectl get pods -n litellm

# Check service
kubectl get svc -n litellm litellm

# Check logs
kubectl logs -n litellm -l app.kubernetes.io/name=litellm -f

# Test API
curl -k http://localhost:31275/v1/models  # If NodePort exposed
```

## Gateway API Setup

### Apply Manifests

```bash
# Service (only if Helm didn't create one)
kubectl apply -f /home/paul/Documents/ai-workspace/guides/litellm/litellm-service.yaml

# Gateway
kubectl apply -f /home/paul/Documents/ai-workspace/guides/litellm/litellm-gateway.yaml

# TLS Certificate
kubectl apply -f /home/paul/Documents/ai-workspace/guides/litellm/litellm-tls.yaml

# HTTPRoute
kubectl apply -f /home/paul/Documents/ai-workspace/guides/litellm/litellm-httproute.yaml
```

### Verify

```bash
# Gateway
kubectl get gateway -n litellm litellm-gateway
# Expected: Accepted: true

# HTTPRoute
kubectl get httproute -n litellm litellm-route
# Expected: Accepted: true

# Certificate
kubectl get certificate -n litellm litellm-tls-cert
# Expected: Ready: true

# Secret
kubectl get secret -n litellm litellm-tls-cert
# Expected: TLS cert + key present
```

## API Key Management

### Create a User Key

```bash
curl -X POST http://<NODE_IP>:<NODE_PORT>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "models": [
      "custom_openai/agnes-2.0-flash",
      "custom_openai/Ornith-1.0-35B-GGUF:Q4_K_M",
      "agnes-2.0-flash",
      "Ornith-1.0-35B-GGUF:Q4_K_M"
    ],
    "metadata": {"user": "devops"},
    "key_alias": "devops"
  }'
```

**Copy the key immediately** — it's only shown once.

### Add Models to Database

```bash
# Via API
curl -X POST http://<NODE_IP>:<NODE_PORT>/model/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "custom_openai/agnes-2.0-flash",
    "litellm_params": {
      "api_base": "https://agnes.ai/v1",
      "api_key": "your-key",
      "model": "agnes-2.0-flash"
    }
  }'
```

### List Models

```bash
# From database
kubectl exec -n litellm -it litellm-0 -- psql -U litellm -d litellm \
  -c "SELECT model_name FROM LiteLLM_ProxyModelTable;"
```

### Key Masking Gotcha

LiteLLM masks keys everywhere. The full key is **only shown once** at creation.

If you lose a key, you must:
1. Delete the old key (by hash)
2. Create a new one

```bash
# List keys
curl http://<NODE_IP>:<NODE_PORT>/key/list \
  -H "Authorization: Bearer $MASTER_KEY"

# Delete by hash
curl -X POST http://<NODE_IP>:<NODE_PORT>/key/delete \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["<HASH>"]}'
```

## Admin UI

### Access

```
https://litellm.luban.paulhome.local/ui
```

### Login

Set `UI_USERNAME` and `UI_PASSWORD` in deployment:

```bash
# Add to values.yaml
env:
  - name: UI_USERNAME
    value: "admin"
  - name: UI_PASSWORD
    value: "your-secure-password"

# Or patch deployment
kubectl set env deployment/litellm -n litellm \
  UI_USERNAME=admin \
  UI_PASSWORD=your-password
```

### Features

- **Virtual Keys:** Create, view, delete API keys
- **Models:** View registered models
- **Playground:** Test model routing
- **Logs:** View usage logs

### Key Masking in UI

The UI shows keys as `sk-...XXXX`. To get the full key:
1. Create a new key in the UI
2. Copy it immediately (only shown once)

## Jupyter Integration

### Setup

```python
import os
os.environ["OPENAI_API_BASE"] = "https://litellm.luban.paulhome.local/v1"
os.environ["OPENAI_API_KEY"] = "sk-user-key"
```

### Jupyter Magic

```bash
pip install jupyter-ai-magic-commands
```

```python
%load_ext jupyter_ai_magic_commands

%%ai custom_openai/agnes-2.0-flash
Explain this code...
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Certificate not issued | Check `selfsigned-cluster-issuer` exists: `kubectl get clusterissuer` |
| Gateway not accepting | Check GatewayClass: `kubectl get gatewayclasses` |
| Route not attaching | Check HTTPRoute: `kubectl describe httproute -n litellm litellm-route` |
| Model not accessible | Check key allowlist: `kubectl get secret litellm-masterkey -o yaml` |
| DB connection failed | Verify Postgres: `kubectl exec -n litellm -it litellm-0 -- psql -U litellm -d litellm` |
| DNS not resolving | `dig litellm.luban.paulhome.local` → should be `192.168.89.61` |

### Key Not Allowed to Access Model

**Root cause:** LiteLLM strips `custom_openai/` prefix before checking key allowlist.

**Fix:** Add unprefixed model names to key's `models` array:

```bash
# Via API
curl -X POST http://<NODE_IP>:<NODE_PORT>/key/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["<KEY_HASH>"], "models": ["custom_openai/foo", "foo"]}'
```

Or update database directly:

```sql
UPDATE "LiteLLM_VerificationToken"
SET models = ARRAY[
  'custom_openai/agnes-2.0-flash',
  'agnes-2.0-flash',
  'custom_openai/Ornith-1.0-35B-GGUF:Q4_K_M',
  'Ornith-1.0-35B-GGUF:Q4_K_M'
]
WHERE key_alias = 'devops';
```

## Cleanup

### Uninstall LiteLLM

```bash
helm uninstall litellm -n litellm
kubectl delete namespace litellm
```

### Remove Gateway Resources

```bash
kubectl delete -f /home/paul/Documents/ai-workspace/guides/litellm/
```

## Resources

- [LiteLLM Documentation](https://docs.litellm.ai/)
- [Helm Chart](https://github.com/BerriAI/litellm)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [cert-manager](https://cert-manager.io/)

# Expose LiteLLM via Gateway API + cert-manager

Expose the LiteLLM proxy on `litellm.luban.paulhome.local` using Kubernetes Gateway API, HTTPRoute, and cert-manager for TLS termination.

## Architecture

```
Client
  → DNS: litellm.luban.paulhome.local → 192.168.89.61:443
    → Gateway (cilium, HTTPS:443, TLS terminated)
      → HTTPRoute (path: /v1, /ui, /)
        → Service: litellm.litellm.svc:4000
          → LiteLLM pod
```

## Prerequisites

- [x] **Gateway API** installed (Cilium on k3s-luban provides `cilium` GatewayClass)
- [x] **cert-manager** installed (`cert-manager` namespace)
- [x] **selfsigned-cluster-issuer** exists (ClusterIssuer for `*.luban.paulhome.local`)
- [x] **DNS** entry: `litellm.luban.paulhome.local` → `192.168.89.61` (DNS server at 192.168.89.1)
- [x] **LiteLLM** deployed in `litellm` namespace (Helm or manifests)

## Files

| File | Purpose |
|------|---------|
| `litellm-service.yaml` | Service exposing port 4000 (ClusterIP) |
| `litellm-gateway.yaml` | Gateway with HTTPS (443) + HTTP (80) listeners |
| `litellm-httproute.yaml` | HTTPRoute → `litellm:4000` |
| `litellm-tls.yaml` | cert-manager Certificate → `litellm-tls-cert` |

## Deployment

```bash
# 1. Service (only if Helm didn't create one)
kubectl apply -f litellm-service.yaml

# 2. Gateway
kubectl apply -f litellm-gateway.yaml

# 3. TLS Certificate
kubectl apply -f litellm-tls.yaml

# 4. HTTPRoute
kubectl apply -f litellm-httproute.yaml
```

## Verification

```bash
# Certificate issued?
kubectl get certificate -n litellm litellm-tls-cert
# Expected: Ready=true

# Secret created?
kubectl get secret -n litellm litellm-tls-cert
# Expected: TLS cert + key present

# Gateway attached?
kubectl get gateway -n litellm litellm-gateway
# Expected: "Accepted: true" in addresses

# Route attached?
kubectl get httproute -n litellm litellm-route
# Expected: "Accepted: true" under parentRefs
```

## Testing

```bash
# LLM API
curl -k https://litellm.luban.paulhome.local/v1/models

# Admin UI
curl -k https://litellm.luban.paulhome.local/ui

# Health
curl -k https://litellm.luban.paulhome.local/health/readiness
```

## HTTP → HTTPS Redirect

Uncomment the `filters` block in `litellm-httproute.yaml` to redirect HTTP (port 80) to HTTPS (port 443):

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /
    filters:
      - type: RequestRedirect
        requestRedirect:
          hostname: litellm.luban.paulhome.local
          scheme: https
          port: 443
```

## Troubleshooting

| Issue | Check |
|-------|-------|
| Certificate not issued | `kubectl describe certificate -n litellm litellm-tls-cert` — verify `selfsigned-cluster-issuer` exists |
| Gateway not accepting | `kubectl describe gateway -n litellm litellm-gateway` — check `Accepted: false` reason |
| Route not attaching | `kubectl describe httproute -n litellm litellm-route` — check `AllowedRoutes` match |
| DNS resolution | `dig litellm.luban.paulhome.local` — must resolve to `192.168.89.61` |

## Notes

- LiteLLM on port 4000 is plain HTTP — TLS is terminated at the Gateway
- No `BackendTLSPolicy` needed (no TLS on the backend)
- GatewayClass `cilium` is used — matches your k3s Cilium CNI
- If using a different GatewayClass, change `gatewayClassName` in `litellm-gateway.yaml`

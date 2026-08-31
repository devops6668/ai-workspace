# Kibana TLS + Envoy Gateway: Upstream Connection Reset

## Symptom

Browser shows "upstream connect error or disconnect/reset before headers. reset reason: connection termination".

Envoy access logs show:
```json
{
  "response_code": 503,
  "response_code_details": "upstream_reset_before_response_started{connection_termination}",
  "response_flags": "UC",
  "upstream_host": "10.42.1.165:5601",
  "upstream_transport_failure_reason": null
}
```

## Root Cause

ECK Kibana has `server.ssl.enabled: true` by default (auto-provisioned TLS cert). The Envoy Gateway connects to the backend via **plain HTTP** through the HTTPRoute, but Kibana expects **HTTPS**. Kibana terminates the connection immediately, causing Envoy to report "connection termination".

## Diagnosis

Direct connection to the pod IP confirms TLS mismatch:

```bash
# Plain HTTP → empty reply
curl http://10.42.1.165:5601/
# Empty reply from server (exit 0)

# HTTPS → works
curl -sk https://10.42.1.165:5601/
# 302 Found → /login?next=%2F
```

Kibana logs confirm it's running HTTPS:
```
[INFO ][http.server.Kibana] http server running at https://0.0.0.0:5601
```

## Fix: BackendTLSPolicy

### Kibana TLS Certificate SANs

```bash
kubectl get secret -n elastic-system kibana-kb-http-certs-public \
  -o jsonpath='{.data.tls\\.crt}' | base64 -d | openssl x509 -text -noout | grep DNS:
# DNS:kibana-kb-http.elastic-system.kb.local, DNS:kibana-kb-http, DNS:kibana-kb-http.elastic-system.svc, DNS:kibana-kb-http.elastic-system
```

Use `kibana-kb-http.elastic-system.svc` as the `validation.hostname`.

### Resources Created

1. **ConfigMap** `kibana-backend-ca` in `elastic-system` — contains the ECK CA cert from `kibana-kb-http-certs-public`
2. **BackendTLSPolicy** `kibana-backend-tls` in `elastic-system` — targets `kibana-kb-http` service with hostname and CA ref
3. **HTTPRoute** `kibana-route` in `elastic-system` — already existed, no changes needed

### Verification

```bash
kubectl get backendtlspolicy -n elastic-system kibana-backend-tls -o yaml | grep -A5 "status:"
# Both ResolvedRefs and Accepted should be True

curl -skL https://kibana.luban.paulhome.local/ | grep -o '<title>[^<]*</title>'
# <title>Elastic</title>
```

## Alternative: Disable Kibana SSL

If you prefer to disable Kibana SSL instead (simpler, less secure):

```yaml
spec:
  config:
    server.ssl.enabled: "false"
```

This makes Kibana serve plain HTTP on 5601. Envoy Gateway can connect without BackendTLSPolicy. However, ECK will also change the readiness probe scheme, which may cause a brief rolling update.

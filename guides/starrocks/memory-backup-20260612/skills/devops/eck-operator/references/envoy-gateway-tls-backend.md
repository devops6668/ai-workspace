# Envoy Gateway Backend TLS & Verification Guide

## Debugging Backend TLS Issues

### Symptom: 503 with `connection_termination`

When Envoy connects to an ECK-managed service (Kibana, APM Server, Fleet Server) with plain HTTP while the backend expects HTTPS:

```
response_code: 503
response_code_details: "upstream_reset_before_response_started{connection_termination}"
response_flags: "UC"
```

**Cause:** The backend service has TLS enabled (ECK auto-provisioned certs) but Envoy is configured to connect with plain HTTP.

**Fix:** Add a `BackendTLSPolicy` referencing the backend's CA cert. See the main `eck-operator` skill.

## Verifying Trace Pipeline

### Via Envoy Access Logs

```bash
kubectl logs -n gateway luban-gateway-<hash> 2>&1 | grep "apm.luban" | grep "/v1/traces"
```

Look for:
- `response_code: 200` — trace accepted
- `upstream_host: <pod_ip>:8200` — which APM pod handled it

### Via Elasticsearch Directly

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

# Check total docs in traces index
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS 'https://localhost:9200/_cat/indices/traces*?v'"

# Search by service name
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS \"https://localhost:9200/.ds-traces-apm-*/_search?pretty\" \
   -H 'Content-Type: application/json' \
   -d '{\"query\":{\"match\":{\"service.name\":\"trace-verify\"}},\"size\":0}'"
```

### Via Kibana UI

Navigate to **Observability → APM → Services**.

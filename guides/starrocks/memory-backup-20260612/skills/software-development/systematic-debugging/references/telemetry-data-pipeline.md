# Telemetry/Observability Data Pipeline Debugging

When debugging why telemetry data (traces, metrics, logs) isn't appearing in your
observability platform, apply this **hop-by-hop verification** pattern.

## The Pattern: Verify Every Hop

Telemetry systems have many layers. A failure at any hop produces the same symptom:
"data not showing in the UI." You MUST verify each hop independently.

```
App code → OTel SDK → Exporter → Protocol → Network → Endpoint → Backend → UI
```

## Verification Sequence (in order)

### Hop 1: Env Vars on the Pod

Check what the running container actually sees — not what the YAML says:

```bash
kubectl exec deploy/my-app -- env | grep OTEL_
```

**Check for:**
- `OTEL_EXPORTER_OTLP_ENDPOINT` — correct URL? Has protocol (`http://` or `https://`)?
- `OTEL_TRACES_EXPORTER` — set to `otlp`? (not `none`, not empty)
- `OTEL_EXPORTER_OTLP_HEADERS` — auth token present?
- `OTEL_EXPORTER_OTLP_CERTIFICATE` — path exists?
- `OTEL_SERVICE_NAME` — correctly overridden per deployment?

**Common gap:** Env vars from `envFrom` (ConfigMap/Secret) may be overridden or not loaded.
Check both `env` and `envFrom` in the deployment spec.

### Hop 2: SDK Initialization

Does the application code actually initialize the OTel SDK?

```bash
# Check startup chain
# For Python: entrypoints.py, __init__.py, app startup code
# Search for configure_otel, TracerProvider, start_as_current_span
```

**Test the SDK directly:**

```bash
kubectl exec deploy/my-app -- python -c "
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
print('TracerProvider:', type(trace.get_tracer_provider()).__name__)
"
```

If `ProxyTracerProvider` → SDK not initialized.
If `TracerProvider` → SDK IS initialized.

### Hop 3: SDK Creates Spans

The SDK may be initialized, but does anything CREATE spans?

```bash
# Search the application and framework code
grep -r "start_as_current_span\|start_span" /path/to/code/
```

**0 results** = No spans will ever be created. The SDK sits idle.

**Common cause:** The framework version doesn't have OTel instrumentation yet.
(e.g., Dagster added OTel in 1.14+, Django REST Framework needs
`opentelemetry-instrumentation-django`, etc.)

### Hop 4: Connectivity to Endpoint

Send a test span to verify the full OTLP pipeline works:

```bash
kubectl exec deploy/my-app -- python -c "
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider()
exporter = OTLPSpanExporter()
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer('verify')
with tracer.start_as_current_span('test-connectivity') as span:
    span.set_attribute('test', 'true')
provider.force_flush()
print('Test trace sent')
"
```

**Errors to watch for:**
- `SSLError: CERTIFICATE_VERIFY_FAILED` → CA cert missing/wrong
- `NameResolutionError` → DNS can't resolve endpoint
- `Connection refused` → Endpoint port wrong/service down
- `401 Unauthorized` → Auth token missing/expired
- No error but data missing → check Hop 5

### Hop 5: Data Arrival in Backend

Query the storage backend directly (don't trust the UI):

```bash
# Elasticsearch
curl -sk -u "user:pass" "https://es:9200/traces-apm*/_search" \
  -H "Content-Type: application/json" \
  -d '{"query":{"match":{"transaction.name":"test-connectivity"}}}'
```

**Check:**
- Does the index exist? → `_cat/indices`
- Does the data arrive? → query by service name + timestamp
- Does it arrive with a delay? → check `@timestamp` field

### Hop 6: UI Visibility

Finally check the UI. Common reasons data is in ES but not visible:
- Time range too narrow
- Wrong environment filter
- Service not indexed in APM yet (may need a few minutes)
- Kibana space permissions

## Example: Dagster 1.12 OTel Debugging

| Hop | Check | Finding |
|-----|-------|---------|
| 1 | `kubectl exec deploy/daemon -- env | grep OTEL_` | ✅ All env vars correct |
| 2 | `entrypoints.py` startup → `configure_otel()` | ✅ SDK initialized |
| 3 | Search dagster for `start_span` | ❌ **0 results** — root cause |
| 4 | Send test span manually | ✅ Works (APM reachable) |
| 5 | Query ES for `dwh-dagster-platform-daemon` | ✅ Only test span present |
| 6 | Kibana APM → Services | ❌ Only `metrics-exporter` visible |

**Root cause:** Dagster 1.12 has zero OTel instrumentation. SDK is initialized but
nothing creates spans. Upgrade to 1.14+ or add instrumentation manually.

## Common Infrastructure Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| DNS resolution failure in pod | `.local` domain not in CoreDNS | Add entry to CoreDNS `NodeHosts` |
| SSL cert verify failed | Self-signed CA not mounted | Mount CA cert ConfigMap + set `OTEL_EXPORTER_OTLP_CERTIFICATE` |
| 401 Unauthorized | Missing auth token | Set `OTEL_EXPORTER_OTLP_HEADERS` from Secret |
| Connection refused | Wrong port / service not running | Check service endpoint with `kubectl get svc -A` |
| Data arrives slowly | Batch span processor delay | Default 5s — normal for test spans |

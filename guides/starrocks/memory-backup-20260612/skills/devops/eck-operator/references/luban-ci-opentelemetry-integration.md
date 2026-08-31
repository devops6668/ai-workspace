# Luban CI → Elastic APM OpenTelemetry Integration

How Luban CI projects export traces and metrics to the ECK-managed Elastic APM Server via OpenTelemetry.

## Architecture

```
Dagster pods (webserver, daemon, code locations, run jobs)
  → OpenTelemetry SDK (OTLP HTTP/protobuf)
  → apm-server-apm-http.elastic-system.svc:8200 (HTTPS)  [internal]
  → apm.luban.paulhome.local:443 (HTTPS)                  [external via Envoy Gateway]
  → Elasticsearch
  → Visualized in Kibana (APM app)
```

## Configuration

### Central settings (`luban-config` in `luban-ci`)

Key | Value | Purpose
----|-------|--------
`otel_exporter_otlp_endpoint` | `https://apm-server-apm-http.elastic-system.svc:8200` | OTLP backend URL
`otel_exporter_otlp_protocol` | `http/protobuf` | HTTP transport for OTLP

These are read by the Luban provisioner when generating `dagster-observability` ConfigMaps for new projects.

### Generated `dagster-observability` ConfigMap defaults

When a new project is provisioned, the following ConfigMap is created in the target namespace and injected into all Dagster pods via `envFrom`:

```yaml
# namespace: <project-ns>/dagster-observability
OTEL_EXPORTER_OTLP_ENDPOINT: https://apm.luban.paulhome.local    # ⚠️ external URL
OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
OTEL_RESOURCE_ATTRIBUTES:    deployment.environment=snd,project.name=<project>
OTEL_SERVICE_NAME:           <project>-dagster-platform
OTEL_TRACES_EXPORTER:        none         ← ❌ DISABLED by default
OTEL_METRICS_EXPORTER:       none         ← ❌ DISABLED by default
```

**This ConfigMap is NOT sufficient to send traces or metrics.** Three things are missing:
1. `OTEL_TRACES_EXPORTER` and `OTEL_METRICS_EXPORTER` are `none` — nothing is exported
2. `OTEL_EXPORTER_OTLP_HEADERS` is absent — APM server rejects unauthorized requests
3. `OTEL_EXPORTER_OTLP_CERTIFICATE` is absent — HTTPS to the external endpoint fails SSL verification

### Enabling export per project

In each project's **individual deployment overlay** (e.g., `dagster.extraEnv` in the GitOps repo values), override the defaults:

```yaml
dagster:
  extraEnv:
    - name: OTEL_TRACES_EXPORTER
      value: "otlp"
    - name: OTEL_METRICS_EXPORTER
      value: "otlp"
    - name: OTEL_EXPORTER_OTLP_HEADERS
      value: "Authorization=Bearer <secret-token>"
    - name: OTEL_EXPORTER_OTLP_CERTIFICATE
      value: "/etc/luban-ca/ca.crt"          # Mount luban-ca-cert secret
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: "https://apm.luban.paulhome.local:443"  # Explicit port
  extraVolumes:
    - name: luban-ca
      secret:
        secretName: luban-ca-cert
  extraVolumeMounts:
    - name: luban-ca
      mountPath: /etc/luban-ca
      readOnly: true
```

**Do NOT attempt to patch the `dagster-observability` ConfigMap directly** — it's managed by the Luban provisioner and will be overwritten on the next provisioner run. Override at the deployment level instead. If you must patch for testing, be aware ArgoCD may revert it on next sync.

## Dagster Platform Metrics

The `dagster-platform-metrics-exporter` Deployment emits OpenTelemetry **metrics** (not traces) via `OTEL_METRICS_EXPORTER=otlp`. These arrive in a dedicated Elasticsearch data stream:

```
.ds-metrics-apm.app.<project>_dagster_platform_metrics_exporter-default-YYYY.MM.DD-000001
```

### Metric list

| Metric | Type | Description |
|--------|------|-------------|
| `dagster.run.queue.depth` | gauge | Number of runs in QUEUED state |
| `dagster.run.queue.oldest_age_seconds` | gauge | Seconds since oldest queued run was created |
| `dagster.run.in_progress.count` | gauge | Runs in NOT_STARTED / STARTING / STARTED state |
| `dagster.sensor.enabled.count` | gauge | Sensors in RUNNING status |
| `dagster.schedule.enabled.count` | gauge | Schedules in RUNNING status |
| `dagster.sensor.last_tick_age_seconds` | gauge | Seconds since latest sensor tick (per sensor) |
| `dagster.schedule.last_tick_age_seconds` | gauge | Seconds since latest schedule tick (per schedule) |
| `dagster.daemon.heartbeat.count` | gauge | Total heartbeat records visible |
| `dagster.daemon.heartbeat_age_seconds` | gauge | Seconds since last heartbeat (per daemon type) |
| `dagster.daemon.heartbeat_errors.count` | gauge | Errors on recent heartbeats (per daemon type) |

**Note:** metrics with no data (e.g., `sensor.last_tick_age_seconds` when 0 sensors enabled) simply won't appear in ES — this is expected.

### Verifying metrics in Elasticsearch

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

# List metric indices
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cat/indices/metrics-*?v"

# Inspect metric documents
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  'curl -sk -u "elastic:'"${ES_PASS}"'" \
  "https://localhost:9200/.ds-metrics-apm.app.*_metrics_exporter-*/_search?pretty&size=3"'
```

Metric documents have this structure:
```json
{
  "@timestamp": "2026-06-11T10:32:33.975Z",
  "agent": { "name": "opentelemetry/python", "version": "1.42.1" },
  "dagster": {
    "daemon": {
      "heartbeat_age_seconds": 33.9,
      "heartbeat_errors": { "count": 0.0 }
    }
  },
  "labels": {
    "dagster_component": "metrics-exporter",
    "dagster_daemon_type": "SCHEDULER",
    "project_name": "dwh"
  },
  "service": { "name": "dwh-dagster-platform-metrics-exporter" }
}
```

## Code location OTel SDK dependency management

Dagster platform pods (webserver, daemon) bundle `opentelemetry-api` and `opentelemetry-sdk` as Dagster dependencies. Code location pods use **user-built images** that may NOT include OTel packages.

### Adding OTel to a code location

1. **Add deps to `pyproject.toml`**:
```toml
dependencies = [
    ...
    "opentelemetry-api>=1.30,<2",
    "opentelemetry-sdk>=1.30,<2",
    "opentelemetry-exporter-otlp-proto-http>=1.30,<2",
]
```

2. **Initialize SDK in `__init__.py`** (runs when Dagster imports the code location):
```python
"""<app> code location."""
import os
import logging

if os.environ.get("OTEL_TRACES_EXPORTER") == "otlp" or os.environ.get("OTEL_METRICS_EXPORTER") == "otlp":
    try:
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry import trace
        provider = TracerProvider()
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        trace.set_tracer_provider(provider)
        logging.getLogger(__name__).info("OpenTelemetry SDK initialized")
    except Exception as e:
        logging.getLogger(__name__).warning("Failed to init OTel: %s", e)

from .definitions import defs
```

3. **Rebuild the image** (push to trigger CI build).

### Testing OTel from inside a code location pod

Only dagster-platform pods have OTel SDK bundled by default. On code location pods, test only after adding deps:
```bash
kubectl exec -n <ns> <pod> -- /layers/luban-ci_python-uv/venv/bin/python -c \
  "import opentelemetry; print('OTel available')"
```

## What produces traces vs metrics

| Component | Traces | Metrics | Notes |
|-----------|--------|---------|-------|
| `dagster-platform-daemon` | ✅ Sensor/schedule ticks, daemon ops | — | OTel built into Dagster Python SDK |
| `dagster-platform-webserver` | ✅ API requests | — | OTel built into Dagster Python SDK |
| `dagster-platform-metrics-exporter` | — | ✅ 10 dagster.* metrics | Custom metrics poller |
| code locations (comp, ewallet, ferry) | ⏳ If app-level instrumentation added | ⏳ | OTel SDK **NOT** installed in code location venv by default — env vars are pre-configured for future use; add deps explicitly |

**Key insight:** Setting env vars on code locations is forward-looking — they'll produce traces once application code adds OTel instrumentation AND the OTel Python packages are in the project's `pyproject.toml` dependencies.

## Authentication

The APM secret token is stored in `elastic-system/apm-server-apm-token`:

```bash
kubectl get secret -n elastic-system apm-server-apm-token \
  -o jsonpath='{.data.secret-token}' | base64 -d
```

Pass as `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>`.

🚫 **Do not commit the token** to GitOps repos. Use ArgoCD's sealed secrets, External Secrets Operator, or a manually-created Secret:

```bash
APM_TOKEN=$(kubectl get secret -n elastic-system apm-server-apm-token \
  -o jsonpath='{.data.secret-token}' | base64 -d)
kubectl create secret generic -n <target-ns> apm-otlp-headers \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${APM_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Reference it in deployment `env` (not `envFrom` — JSON patch of envFrom secretRef may be silently dropped):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_HEADERS
    valueFrom:
      secretKeyRef:
        name: apm-otlp-headers
        key: OTEL_EXPORTER_OTLP_HEADERS
```

## TLS / CA Certificate

Two approaches (user in this homelab prefers external gateway):

### Option A: External gateway URL (preferred by user)
```
OTEL_EXPORTER_OTLP_ENDPOINT=https://apm.luban.paulhome.local:443
OTEL_EXPORTER_OTLP_CERTIFICATE=/etc/luban-ca/ca.crt
```
Uses the Luban CA cert (`luban-ci/luban-ca-cert` secret). Works from anywhere that can reach the gateway.

### Option B: Internal K8s service
```
OTEL_EXPORTER_OTLP_ENDPOINT=https://apm-server-apm-http.elastic-system.svc:8200
OTEL_EXPORTER_OTLP_CERTIFICATE=<path-to-apm-ca.crt>
```
Uses ECK's internal CA cert (`apm-server-apm-http-certs-public`). Only works in-cluster.

The APM server is **HTTPS only** (port 8200). Plain HTTP requests return `400 Bad Request: Client sent an HTTP request to an HTTPS server.`

## Manual testing before GitOps commit

### Quick test from any Dagster pod

```bash
kubectl exec -n <ns> <dagster-pod> -- \
  /layers/luban-ci_python-uv/venv/bin/python -c "
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer('verify')
with tracer.start_as_current_span('test-dagster-otel') as span:
    span.set_attribute('test', 'true')
provider.force_flush()
print('Trace sent')
"
```

Only works on dagster-platform pods (webserver, daemon, metrics-exporter) — code location pods don't have OTel SDK installed.

### Full manual patch procedure

```bash
# Step 1: Create CA ConfigMap + auth secret in target namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: luban-ca
  namespace: <ns>
data:
  ca.crt: |
$(kubectl get secret -n luban-ci luban-ca-cert -o jsonpath='{.data.ca\.crt}' | base64 -d | sed 's/^/    /')
EOF

APM_TOKEN=$(kubectl get secret -n elastic-system apm-server-apm-token \
  -o jsonpath='{.data.secret-token}' | base64 -d)
kubectl create secret generic -n <ns> apm-otlp-headers \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${APM_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Patch dagster-observability ConfigMap
kubectl patch cm -n <ns> dagster-observability --type merge \
  -p '{"data":{"OTEL_EXPORTER_OTLP_CERTIFICATE":"/etc/luban-ca/ca.crt"}}'

# Step 3: Patch deployments — add volume, mount, env
for deploy in dagster-platform-daemon dagster-platform-metrics-exporter \
              dagster-platform-webserver; do
  kubectl patch deployment -n <ns> "$deploy" --type json \
    -p='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"luban-ca","configMap":{"name":"luban-ca"}}}]'
  kubectl patch deployment -n <ns> "$deploy" --type json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"luban-ca","mountPath":"/etc/luban-ca","readOnly":true}}]'
  kubectl patch deployment -n <ns> "$deploy" --type json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_HEADERS","valueFrom":{"secretKeyRef":{"name":"apm-otlp-headers","key":"OTEL_EXPORTER_OTLP_HEADERS"}}}}]'
done

# Step 4: Also patch code location deployments if desired
for deploy in comp ewallet ferry; do
  kubectl patch deployment -n <ns> "$deploy" --type json \
    -p='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"luban-ca","configMap":{"name":"luban-ca"}}}]
        [{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"luban-ca","mountPath":"/etc/luban-ca","readOnly":true}}]
        [{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_HEADERS","valueFrom":{"secretKeyRef":{"name":"apm-otlp-headers","key":"OTEL_EXPORTER_OTLP_HEADERS"}}}}]
        [{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_TRACES_EXPORTER","value":"otlp"}}]
        [{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_METRICS_EXPORTER","value":"otlp"}}]
        [{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_CERTIFICATE","value":"/etc/luban-ca/ca.crt"}}]'
done
```

**⚠️ These patches are ephemeral** — ArgoCD reverts them on next sync. Use for testing only, then commit equivalent changes to GitOps repo.

### Pitfalls (manual patching)

- **`envFrom` secretRef via JSON patch may be silently dropped** — the patch returns "patched" but envFrom isn't modified. Use direct `env` with `valueFrom.secretKeyRef` instead.
- **Patch order matters** — add volume before volume mount.
- **`env` beats `envFrom`** — explicit env vars take precedence over ConfigMap/Secret references via envFrom.
- **`OTEL_EXPORTER_OTLP_INSECURE=true` does NOT work** with the Python HTTP exporter. The env var is only respected by the gRPC exporter. Always provide a CA bundle via `OTEL_EXPORTER_OTLP_CERTIFICATE`.
- **Code location pods may lack OTel SDK** — env vars are set but actual traces/metrics won't flow until app-level instrumentation is added.

## Verification checklist

```bash
# 1. ConfigMap exists and is referenced
kubectl get cm -n <ns> dagster-observability -o yaml | grep -E "OTEL_TRACES|OTEL_METRICS"

# 2. Pods reference the ConfigMap via envFrom
kubectl get pod -n <ns> <dagster-pod> -o json | jq '.spec.containers[0].envFrom[]'

# 3. Deployment-level overrides are applied
kubectl get pod -n <ns> <dagster-pod> -o json | \
  jq '.spec.containers[0].env[] | select(.name | startswith("OTEL_"))'

# 4. CA cert volume is mounted
kubectl get pod -n <ns> <dagster-pod> -o json | \
  jq '.spec.containers[0].volumeMounts[] | select(.name == "luban-ca")'

# 5. Verify env vars from inside pod
kubectl exec -n <ns> <dagster-pod> -- env | grep OTEL_ | sort

# 6. Send a test trace from inside a dagster-platform pod
kubectl exec -n <ns> <dagster-pod> -- /layers/luban-ci_python-uv/venv/bin/python -c "
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer('verify')
with tracer.start_as_current_span('test-otel') as span:
    span.set_attribute('test', 'true')
provider.force_flush()
print('Trace sent')
"

# 7. Verify trace arrived in Elasticsearch
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  'curl -sk -u "elastic:'"${ES_PASS}"'" \
  "https://localhost:9200/traces-apm*/_search?size=1" \
  -H "Content-Type: application/json" \
  -d "{\"query\":{\"match\":{\"transaction.name\":\"test-otel\"}},\"_source\":[\"service.name\",\"@timestamp\"]}"'

# 8. Verify metrics arrived
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:${ES_PASS}" "https://localhost:9200/_cat/indices/metrics-*?v"
```

## Service identity

Each Deployment sets `OTEL_SERVICE_NAME` explicitly to distinguish workloads:
- Dagster platform daemon: `<project>-dagster-platform-daemon`
- Dagster platform webserver: `<project>-dagster-platform-webserver`
- Dagster metrics exporter: `<project>-dagster-platform-metrics-exporter`
- Code locations: `<project>-<code-location-name>`

Resource attributes (set by the Luban provisioner):
- `deployment.environment=snd|prd`
- `project.name=<project-name>`
- Platform pods: `dagster.component=daemon|webserver|metrics-exporter`
- Code locations: `dagster.code_location=<app-name>`

## References

- ECK docs: https://www.elastic.co/guide/en/cloud-on-k8s/current/
- OTel Python SDK: https://opentelemetry-python.readthedocs.io/
- Dagster OTel integration: https://docs.dagster.io/concepts/observability/opentelemetry

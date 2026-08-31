---
name: dagster-observability
description: Configure OpenTelemetry (OTel) for Dagster platform and code locations, exporting traces and metrics to Elastic APM. Covers HTTPS TLS handling, CA cert mounting, auth tokens, and the dagster-observability ConfigMap pattern.
tags:
  - dagster
  - opentelemetry
  - elastic-apm
  - otel
  - observability
  - tracing
  - metrics
  - k8s
---

# Dagster OTel Observability

Enable OpenTelemetry traces and metrics for Dagster deployments on Kubernetes, exporting to Elastic APM via OTLP/HTTP.

## Architecture

Dagster OTel uses a two-layer config pattern:

1. **`dagster-observability` ConfigMap** — platform-owned, injected via `envFrom` into all pods (webserver, daemon, code locations, run pods). Holds shared OTLP endpoint, protocol, and the exporter toggle.
2. **Per-deployment overrides** — `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` set individually per pod to distinguish services in APM.

## Prerequisites

- ECK-managed APM Server running in the cluster (see `eck-operator` skill)
- APM Server token (`kubectl get secret -n <ns> <apm-server-apm-token>`)
- CA certificate for the HTTPS APM endpoint (either the internal APM CA or the gateway/Luban CA)

## Step-by-step

### 1. Enable Export in ConfigMap

The `dagster-observability` ConfigMap defaults to `none` for both exporters. Override them:

```yaml
OTEL_TRACES_EXPORTER: otlp
OTEL_METRICS_EXPORTER: otlp
OTEL_EXPORTER_OTLP_ENDPOINT: https://apm-server-apm-http.elastic-system.svc:8200
OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
OTEL_EXPORTER_OTLP_CERTIFICATE: /etc/apm-certs/ca.crt   # path to mounted CA
OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=snd,project.name=<project>"
```

> **⚠️ ArgoCD management**: If the ConfigMap has `argocd.argoproj.io/tracking-id`, direct `kubectl patch` will be reverted on next sync. Update the GitOps repo overlay instead.

### 2. Auth Token (Secret, not ConfigMap)

The APM Bearer token must come from a Secret via `envFrom` or `env.valueFrom.secretKeyRef` — never in a ConfigMap:

```yaml
# Secret: apm-otlp-headers
OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Bearer <token>"
```

Inject into deployment:
```yaml
envFrom:
  - secretRef:
      name: apm-otlp-headers
# OR as individual env var:
env:
  - name: OTEL_EXPORTER_OTLP_HEADERS
    valueFrom:
      secretKeyRef:
        name: apm-otlp-headers
        key: OTEL_EXPORTER_OTLP_HEADERS
```

### 3. CA Certificate Volume Mount

The APM server serves HTTPS on port 8200. Without a valid CA cert, the OTel Python exporter will fail with:

```
SSL: CERTIFICATE_VERIFY_FAILED certificate verify failed: unable to get local issuer certificate
```

Two options for the CA:

**A) Internal APM CA (in-cluster only):**
```yaml
volumes:
  - name: apm-ca
    secret:
      secretName: apm-server-apm-http-certs-public
volumeMounts:
  - name: apm-ca
    mountPath: /etc/apm-certs
    readOnly: true
```

**B) Gateway/Luban CA (external or cross-cluster):**
```yaml
volumes:
  - name: luban-ca
    configMap:
      name: luban-ca
volumeMounts:
  - name: luban-ca
    mountPath: /etc/luban-ca
    readOnly: true
```

### 4. Per-deployment Service Identity

Override `OTEL_SERVICE_NAME` and add `dagster.component` for clear APM service differentiation:

| Deployment | `OTEL_SERVICE_NAME` | `dagster.component` |
|------------|-------------------|--------------------|
| dagster-platform-webserver | `<project>-dagster-platform-webserver` | webserver |
| dagster-platform-daemon | `<project>-dagster-platform-daemon` | daemon |
| dagster-platform-metrics-exporter | `<project>-dagster-platform-metrics-exporter` | metrics-exporter |
| comp (code location) | `<project>-comp` | code-location |
| ewallet (code location) | `<project>-ewallet` | code-location |

Add via deployment env (not ConfigMap, since values differ per pod):
```yaml
env:
  - name: OTEL_SERVICE_NAME
    value: "dwh-dagster-platform-webserver"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=snd,project.name=dwh,dagster.component=webserver"
```

### 5. Entrypoints Pattern (How OTel Gets Initialized)

All three Dagster platform components use `luban_dagster_platform` as their entrypoint, NOT Dagster directly:

| Pod | Entrypoint | Calls `configure_otel()`? |
|-----|-----------|:------------------------:|
| daemon | `python -m luban_dagster_platform.entrypoints daemon run ...` | ✅ Yes (in entrypoints) |
| webserver | `python -m luban_dagster_platform.entrypoints webserver ...` | ✅ Yes (in entrypoints) |
| metrics-exporter | `python -m luban_dagster_platform.metrics_exporter` | ✅ Yes (in own main()) |

The `entrypoints.py` flow:
```python
from luban_dagster_platform.otel import configure_otel

def main():
    configure_otel()          # ← Initializes OTel SDK FIRST
    if mode == "daemon":
        start_dagster_daemon() # ← Then starts Dagster
```

`configure_otel()` calls both `configure_tracing()` and `configure_metrics()` from `otel.py`, which set up `TracerProvider`, `MeterProvider`, span processors, and metric readers.

### 6. What Actually Gets Exported (Dagster 1.12 Limitation)

**Critical finding: Dagster 1.12.19 has ZERO OpenTelemetry instrumentation.** Searching the entire `dagster` package for `start_span` or `start_as_current_span` returns zero results. So even though:

- ✅ Daemon/webserver call `configure_otel()` → SDK initializes
- ⚠️ Dagster creates NO spans during its operations (sensor ticks, run executions, API calls)
- ❌ **No traces are ever produced** because nothing in Dagster's code calls the tracer

Only the **metrics-exporter** actually produces and exports data — because it creates its own **10 ObservableGauges** using `meter.create_observable_gauge()` directly, independent of Dagster.

| Pod | Has OTel SDK? | configure_otel() called? | Actually exports? | What is exported? |
|-----|:-----------:|:------------------------:|:----------------:|-------------------|
| dagster-platform-daemon | ✅ Yes | ✅ Yes | ❌ No traces | SDK initialized but Dagster 1.12 creates no spans |
| dagster-platform-webserver | ✅ Yes | ✅ Yes | ❌ No traces | SDK initialized but Dagster 1.12 creates no spans |
| dagster-platform-metrics-exporter | ✅ Yes | ✅ Yes | ✅ Yes | 10 metrics gauges (self-created, not from Dagster) |
| comp, ewallet, ferry (code locations) | ❌ No | ❌ No | ❌ None | Env vars injected but inert without SDK |
| K8s Run Pods (K8sRunLauncher) | ❌ No | ❌ No | ❌ None | Code location image has no SDK |

> **Per the [Luban CI observability guide](https://github.com/metasync/luban-ci/blob/main/docs/guides/observability.md), code locations should NOT add OTel SDK.** The guide only covers:
> - Environment variable propagation to all pods (via `dagster-observability` ConfigMap)
> - Enabling export via GitOps (for platform components)
> - Dagster platform health metrics (from `metrics-exporter`)
>
> The `dagster-observability` ConfigMap injects `OTEL_TRACES_EXPORTER=otlp` and `OTEL_METRICS_EXPORTER=otlp` into code locations for **future compatibility** — if they later add SDK or if Dagster changes its dependency packaging, the env vars are already there. But today, without the SDK packages, the env vars have no effect.
> **Future consideration**: If you ever want run-level traces (e.g., per-dbt-model timing in APM), code locations will need `opentelemetry-sdk` + `opentelemetry-exporter-otlp-proto-http` added to their `pyproject.toml`. At that point, `__init__.py` initialization is optional — Dagster handles span creation automatically.

## Verification

### Test trace from inside a pod
```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider()
exporter = OTLPSpanExporter()
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer("verify")
with tracer.start_as_current_span("verify-test") as span:
    span.set_attribute("test", "true")

provider.force_flush()
```

### Check Elasticsearch for received data

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Check traces
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/traces-apm*/_search?pretty&size=3" 2>/dev/null

# Check metrics indices
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/_cat/indices/metrics-apm*?v" 2>/dev/null

# Verify all 10 metrics have data
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/.ds-metrics-apm.app.*/_search?pretty&size=50" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
hits=d.get('hits',{}).get('hits',[])
fields=set()
for h in hits:
    dagster=h.get('_source',{}).get('dagster',{})
    for cat,vals in dagster.items():
        for metric in vals.keys():
            fields.add(f'{cat}.{metric}')
print('Metrics found:')
for f in sorted(fields):
    print(f'  {f}')
"
```

## Metrics Reference

The `dagster-platform-metrics-exporter` is a dedicated Python process (`python -m luban_dagster_platform.metrics_exporter`) that polls the Dagster PostgreSQL database every 60 seconds and emits health metrics as **OTel ObservableGauges**.

### What is a Gauge?

A **Gauge** is an OTel metric type that represents a value that can go up or down at any time — like a **speedometer** showing current speed. Unlike a Counter (only increases) or Histogram (statistical distribution), a Gauge reports "the value right now." Each of the 10 metrics below is an `ObservableGauge` whose callback runs every export interval to fetch the latest value from the DB.

### Metrics Table

| Metric | Type | Labels |
|--------|------|--------|
| `dagster.run.queue.depth` | gauge | - |
| `dagster.run.queue.oldest_age_seconds` | gauge | - |
| `dagster.run.in_progress.count` | gauge | - |
| `dagster.sensor.enabled.count` | gauge | - |
| `dagster.schedule.enabled.count` | gauge | - |
| `dagster.sensor.last_tick_age_seconds` | gauge | dagster.instigator_name, dagster.instigator_status |
| `dagster.schedule.last_tick_age_seconds` | gauge | dagster.instigator_name, dagster.instigator_status |
| `dagster.daemon.heartbeat.count` | gauge | - |
| `dagster.daemon.heartbeat_age_seconds` | gauge | dagster.daemon_type |
| `dagster.daemon.heartbeat_errors.count` | gauge | dagster.daemon_type |

## Cross-references

- **`eck-operator` skill** — comprehensive reference for ECK APM Server setup.
- **`references/otel-apm-setup.md`** — OTel env var reference, APM endpoints, token retrieval, and CA cert management.
- **`references/code-location-otel-setup.md`** — note about code locations NOT needing OTel SDK, plus future considerations and per-deployment patch commands.
- **`coredns-local-domain-fix` skill** — fix `.local` domain resolution for kpack build pods.
- **`references/kibana-dashboard-api.md`** — programmatic Kibana dashboard creation via saved objects API (metric cards, line charts, horizontal bars).

## Pitfalls

- **`OTEL_EXPORTER_OTLP_INSECURE=true` does NOT work with Python HTTP exporter** — it only affects the gRPC exporter. The HTTP exporter (`opentelemetry-exporter-otlp-proto-http`) requires a valid CA cert or a custom session with `verify=False`. Always provide a CA cert. The env var `OTEL_PYTHON_EXPORTER_OTLP_HTTP_INSECURE` does not exist either.
- **`OTLPSpanExporter` has no `insecure` parameter** in recent versions (1.42+). Passing `insecure=True` as a constructor kwarg raises `TypeError: unexpected keyword argument 'insecure'`. Use the env var `OTEL_EXPORTER_OTLP_CERTIFICATE` instead.
- **ConfigMap changes via `envFrom` require pod restart** — use `kubectl rollout restart deployment`.
- **ArgoCD auto-sync reverts direct patches** — patch the GitOps overlay, not the live resource. If auto-sync is off, direct `kubectl patch` works for testing.
- **Code locations have no OTel SDK per the observability doc** — env vars are inert without the SDK packages. Only platform components (daemon, webserver, metrics-exporter) export data.
- **`.local` domains may not resolve in k8s build pods** — If kpack builds fail with `Name does not resolve` for internal registry URLs (e.g., `nexus.paulhome.local`), see `coredns-local-domain-fix` skill. After fixing CoreDNS, trigger a rebuild by patching the kpack Image resource: `kubectl patch images.kpack.io -n <ns> <name> --type merge -p '{"spec":{"build":{"env":[{"name":"FORCE_REBUILD","value":"trigger-'$(date +%s)'"}]}}}'`
- **Kibana basic license limits visualization types** — When creating custom dashboards via API, `line` and `horizontal_bar` chart types with `terms` aggregation may hang with "loading" indefinitely. Only `metric` and `table` visualization types are reliable. Also the `data_views` API requires Enterprise license — use the existing `metrics-*` index pattern and `saved_objects` API instead. See `references/kibana-dashboard-api.md`.

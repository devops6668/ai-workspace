# Code Location OTel (Session Notes)

## Per the Luban CI Observability Doc

**Code locations do NOT need OTel SDK.** The only components that export OTel data are:

| Component | Exports | Why |
|-----------|---------|-----|
| dagster-platform-daemon | ✅ Traces | Docker image bundles OTel SDK |
| dagster-platform-webserver | ✅ Traces | Docker image bundles OTel SDK |
| dagster-platform-metrics-exporter | ✅ Metrics | Luban package bundles OTel SDK |
| comp, ewallet, ferry (code locations) | ❌ Nothing | No SDK in image — env vars inert |
| K8s Run Pods (K8sRunLauncher) | ❌ Nothing | Inherits code location image → no SDK |

The `dagster-observability` ConfigMap sets `OTEL_TRACES_EXPORTER=otlp` and `OTEL_METRICS_EXPORTER=otlp` on all pods, but without the SDK packages installed, these env vars **have no effect**.

## Future: If You Change Your Mind

If you later want run-level traces (e.g., per-dbt-model timing in APM), add to `pyproject.toml`:

```toml
dependencies = [
    ...
    "opentelemetry-api>=1.30,<2",
    "opentelemetry-sdk>=1.30,<2",
    "opentelemetry-exporter-otlp-proto-http>=1.30,<2",
]
```

No explicit `__init__.py` initialization is needed — Dagster handles span creation automatically.

## Build & Deploy Pipeline (if needed)

1. **Push to app repo** → triggers kpack build via Argo Events webhook
2. **kpack build** → produces new image digest in `ci-<project>` namespace
3. **Image tagged** with commit SHA as additional tag
4. **Update GitOps repo** → change `newTag` in `kustomization.yaml`
5. **ArgoCD sync** → applies manifest, triggers pod rollout

### Image Tag Strategy

```yaml
# app/base/deployment.yaml — uses :latest as default
image: "registry/project/app:latest"

# app/overlays/<env>/kustomization.yaml — overrides with commit tag
images:
  - name: "registry/project/app"
    newTag: "<commit-sha>"
```

The `replacements` section syncs the image to `DAGSTER_CURRENT_IMAGE` env var.

## Per-deployment Patch Commands (for platform components)

When patching platform deployments (daemon/webserver/metrics-exporter):

```bash
# Add env vars
kubectl patch deployment -n <ns> <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_TRACES_EXPORTER","value":"otlp"}},
       {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_METRICS_EXPORTER","value":"otlp"}},
       {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_CERTIFICATE","value":"/etc/luban-ca/ca.crt"}},
       {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_HEADERS","valueFrom":{"secretKeyRef":{"name":"apm-otlp-headers","key":"OTEL_EXPORTER_OTLP_HEADERS"}}}}]'

# Add volume
kubectl patch deployment -n <ns> <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"luban-ca","configMap":{"name":"luban-ca"}}}]'

# Add volume mount
kubectl patch deployment -n <ns> <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"luban-ca","mountPath":"/etc/luban-ca","readOnly":true}}]'
```

> ⚠️ These patches work only if ArgoCD auto-sync is off. Otherwise, update the GitOps overlay.

## Verification

```bash
# Check OTel is importable (platform components only)
kubectl exec -n <ns> deployment/<app> -- /layers/luban-ci_python-uv/venv/bin/python \
  -c "from opentelemetry import trace; from opentelemetry.sdk.trace import TracerProvider; print('OK')"

# Send test trace
kubectl exec -n <ns> deployment/<app> -- /layers/luban-ci_python-uv/venv/bin/python \
  -c "
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
with trace.get_tracer('verify').start_as_current_span('verification') as span:
    span.set_attribute('test','true')
provider.force_flush()
print('OK')
"
```

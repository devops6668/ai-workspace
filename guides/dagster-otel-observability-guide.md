# Dagster OpenTelemetry Observability Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Dagster Platform on K8s                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────────┐  │
│  │ metrics-exporter │  │    daemon        │  │   webserver   │  │
│  │                  │  │                  │  │               │  │
│  │ 10 ObservableGauges│ │ configure_otel() │  │ configure_otel()│ │
│  │ Polls PostgreSQL │  │ No custom metrics│  │ No custom     │  │
│  │                  │  │ No custom spans  │  │ metrics/spans │  │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬───────┘  │
│           │                     │                     │          │
│           └─────────────────────┼─────────────────────┘          │
│                                 │                                │
│  ┌──────────────────────────────┼──────────────────────────────┐ │
│  │        OTel SDK (OTLP/HTTP)  │                              │ │
│  │        ──────────────────────┘                              │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                 │                                │
│  ┌──────────────────────────────┼──────────────────────────────┐ │
│  │        Code Locations        │                              │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                     │ │
│  │  │   cms   │  │ ewallet │  │   ...   │                     │ │
│  │  │         │  │         │  │         │                     │ │
│  │  │ OTel SDK│  │ OTel SDK│  │ OTel SDK│                     │ │
│  │  │ + spans │  │ + spans │  │ + spans │                     │ │
│  │  └────┬────┘  └────┬────┘  └────┬────┘                     │ │
│  │       │            │            │                           │ │
│  │  K8s Run Workers (multiprocess executor)                    │ │
│  │  ┌──────────────────────────────────────┐                   │ │
│  │  │ configure_otel() in subprocess       │                   │ │
│  │  │ otel_transaction_span() / otel_span()│                   │ │
│  │  └──────────────────────────────────────┘                   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                 │                                │
│                          OTLP/HTTP                               │
│                                 │                                │
│  ┌──────────────────────────────┼──────────────────────────────┐ │
│  │        Elastic APM           │                              │ │
│  │  ┌─────────────┐  ┌──────────────────┐                     │ │
│  │  │   traces    │  │     metrics      │                     │ │
│  │  │  (spans)    │  │ (ObservableGauges)│                    │ │
│  │  └─────────────┘  └──────────────────┘                     │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Key Findings

### What Sends What

| Component | Sends | Protocol | Interval |
|-----------|-------|----------|----------|
| metrics-exporter | **Metrics** (10 ObservableGauges) | OTLP/HTTP | 60s |
| daemon | Nothing (SDK idle) | - | - |
| webserver | Nothing (SDK idle) | - | - |
| Code locations | **Traces** (spans) via dbt-dagsterizer | OTLP/HTTP | 5s (BSP) |
| K8s Run Workers | **Traces** (spans) via dbt-dagsterizer | OTLP/HTTP | 5s (BSP) |

### dbt-dagsterizer Creates Spans, Not Metrics

```python
# dbt-dagsterizer creates TRACES (spans):
otel_transaction_span("job/cms/daily_sync")   # transaction span
otel_span("dbt.model/stg_users")              # child span
otel_span("dbt.model/dim_orders")             # child span

# dbt-dagsterizer does NOT create:
# - counters
# - histograms
# - observable gauges
# - any OTel metrics
```

## Code Location Setup

### 1. Add OTel Dependencies

```toml
# pyproject.toml
dependencies = [
    "dagster==1.12.19",
    "dbt-dagsterizer @ git+https://github.com/devops6668/dbt-dagsterizer.git@main",
    "opentelemetry-sdk>=1.25,<2",
    "opentelemetry-exporter-otlp>=1.25,<2",
]
```

### 2. Configure OTel in definitions.py

```python
import os
import time
from pathlib import Path

from dagster import op, job, Definitions, ScheduleDefinition
from dbt_dagsterizer.api import build_definitions
from dbt_dagsterizer.otel import (
    configure_otel,
    otel_span,
    otel_transaction_span,
    otel_dagster_transaction_info,
    otel_record_exception,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DBT_PROJECT_DIR = REPO_ROOT / "dbt_project"

os.environ.setdefault("LUBAN_REPO_ROOT", str(REPO_ROOT))
os.environ.setdefault("DBT_PROJECT_DIR", str(DBT_PROJECT_DIR))
os.environ.setdefault("DBT_PROFILES_DIR", str(DBT_PROJECT_DIR))

# Initialize OpenTelemetry in parent process
configure_otel()

@op
def my_op(context):
    # Re-init OTel in subprocess — multiprocess executor doesn't inherit providers
    configure_otel()

    tx_span_name, _, tx_attrs = otel_dagster_transaction_info(context)

    with otel_transaction_span(tx_span_name, attributes=tx_attrs):
        with otel_span("dbt.model/my_model", attributes={
            "dbt.unique_id": "model.my_dbt.my_model",
            "dbt.status": "success",
            "dbt.resource_type": "model",
            "dbt.name": "my_model",
            "dbt.execution_time_s": 60.0,
        }):
            context.log.info("Running model...")
            time.sleep(60)

@job
def my_job():
    my_op()

defs = Definitions.merge(
    build_definitions(...),
    Definitions(jobs=[my_job]),
)
```

### 3. GitOps Deployment

```yaml
# app/base/deployment.yaml
spec:
  template:
    spec:
      containers:
        - name: code-location
          envFrom:
            - configMapRef:
                name: dagster-observability    # OTel env vars
          env:
            - name: OTEL_SERVICE_NAME
              value: "dwh-cms"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment=snd,project.name=dwh,dagster.component=code-location,dagster.code_location=cms"
          volumeMounts:
            - name: luban-ca
              mountPath: /etc/luban-ca
              readOnly: true
      volumes:
        - name: luban-ca
          configMap:
            name: luban-ca
```

### 4. K8sRunLauncher Volume Mount

```yaml
# dagster-instance ConfigMap
run_launcher:
  module: luban_dagster_platform.k8s_run_launcher
  class: CodeLocationAwareK8sRunLauncher
  config:
    volumes:
      - name: luban-ca
        configMap:
          name: luban-ca
    volume_mounts:
      - name: luban-ca
        mountPath: /etc/luban-ca
        readOnly: true
    env_config_maps:
      - dagster-env
      - dagster-observability
```

## Transaction Name Format

The forked dbt-dagsterizer includes code location in transaction name:

```python
# otel/dagster.py
if code_location:
    span_name = f"{tx_type}/{code_location}/{tx_name}"
else:
    span_name = f"{tx_type}/{tx_name}"
```

### Transaction Types

| Trigger | Transaction Name |
|---------|-----------------|
| UI Launch | `manual/cms/daily_sync` |
| Schedule | `job/cms/daily_sync` |
| Sensor | `sensor/cms/freshness_check` |
| Backfill | `backfill/cms/<backfill_id>` |
| Asset Materialization | `asset_job/cms` |

### Kibana Queries

```bash
# All traces for a code location
transaction.name: manual/cms/*

# All schedule runs
transaction.name: job/*/*

# All manual runs across all code locations
transaction.name: manual/*/*

# Specific job
transaction.name: manual/cms/otel_test_job
```

## ConfigMap-Based Schedule Configuration

### ewallet-gitops ConfigMap

```yaml
# app/overlays/snd/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ewallet-config
data:
  EWALLET_SYNC_ENABLED: "true"
  EWALLET_SYNC_CRON: "*/5 * * * *"
```

### definitions.py Reading ConfigMap

```python
sync_enabled = os.getenv("EWALLET_SYNC_ENABLED", "false").lower() == "true"
sync_cron = os.getenv("EWALLET_SYNC_CRON", "0 * * * *")

schedules = []
if sync_enabled:
    schedules.append(ScheduleDefinition(
        job=ewallet_sync_job,
        cron_schedule=sync_cron,
    ))
```

### Changing Schedule Without Code Push

```yaml
# Just change ConfigMap, no code rebuild needed
EWALLET_SYNC_CRON: "*/30 * * * *"   # every 30 min
EWALLET_SYNC_CRON: "0 */2 * * *"    # every 2 hours
EWALLET_SYNC_CRON: "0 9 * * *"      # daily at 9am
EWALLET_SYNC_ENABLED: "false"        # disable
```

## Failing Job with Error Spans

```python
from dagster import Failure
from dbt_dagsterizer.otel import otel_record_exception

@op
def simulate_failing_job(context):
    configure_otel()
    tx_span_name, _, tx_attrs = otel_dagster_transaction_info(context)

    with otel_transaction_span(tx_span_name, attributes=tx_attrs):
        # Model 1 succeeds
        with otel_span("dbt.model/stg_orders", attributes={
            "dbt.status": "success",
        }):
            time.sleep(30)

        # Model 2 succeeds
        with otel_span("dbt.model/dim_products", attributes={
            "dbt.status": "success",
        }):
            time.sleep(30)

        # Model 3 fails
        with otel_span("dbt.model/fct_sales", attributes={
            "dbt.status": "error",
        }) as span:
            time.sleep(20)
            error_msg = "Database Error: Table does not exist"
            otel_record_exception(span, Exception(error_msg))
            raise Failure(description=error_msg)
```

## OTel Environment Variables

### dagster-observability ConfigMap

```yaml
OTEL_TRACES_EXPORTER: otlp
OTEL_METRICS_EXPORTER: otlp
OTEL_EXPORTER_OTLP_ENDPOINT: https://apm.luban.paulhome.local
OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
OTEL_EXPORTER_OTLP_CERTIFICATE: /etc/luban-ca/ca.crt
OTEL_EXPORTER_OTLP_HEADERS: Authorization=Bearer <token>
```

### Aggressive Export (for testing)

```yaml
OTEL_BSP_SCHEDULE_DELAY: 1000       # span export every 1s
OTEL_BSP_EXPORT_TIMEOUT: 5000       # span export timeout 5s
OTEL_METRIC_EXPORT_INTERVAL: 1000   # metric export every 1s
OTEL_METRIC_EXPORT_TIMEOUT: 5000    # metric export timeout 5s
```

## Pitfalls

### 1. Multiprocess Executor Doesn't Inherit OTel Providers

Dagster uses multiprocess executor. The `configure_otel()` call in parent process doesn't propagate to subprocesses.

**Fix**: Call `configure_otel()` inside the op:

```python
@op
def my_op(context):
    configure_otel()  # ← Must re-init in subprocess
    ...
```

### 2. Run Worker Pods Need CA Cert Volume

K8sRunLauncher creates separate pods without the luban-ca volume mount.

**Fix**: Add volumes/volume_mounts to dagster-instance ConfigMap:

```yaml
run_launcher:
  config:
    volumes:
      - name: luban-ca
        configMap:
          name: luban-ca
    volume_mounts:
      - name: luban-ca
        mountPath: /etc/luban-ca
        readOnly: true
```

### 3. Code Location Packages Not in Image

OTel packages in `pyproject.toml` but not in running pod.

**Fix**: Wait for kpack to rebuild the image after pushing changes.

### 4. Code Location Name Not in Transaction Name

Using hardcoded span name instead of `otel_dagster_transaction_info()`.

**Fix**: Use the helper function:

```python
tx_span_name, _, tx_attrs = otel_dagster_transaction_info(context)
with otel_transaction_span(tx_span_name, attributes=tx_attrs):
    ...
```

## Verification Commands

```bash
# Check OTel is initialized in code location
kubectl -n snd-dwh exec <pod> -- /workspace/.venv/bin/python -c "
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry import trace
print(isinstance(trace.get_tracer_provider(), TracerProvider))
"

# Check CA cert is mounted
kubectl -n snd-dwh exec <pod> -- ls /etc/luban-ca/ca.crt

# Check traces in APM
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{"query":{"bool":{"must":[{"exists":{"field":"trace"}},{"range":{"@timestamp":{"gte":"now-10m"}}}]}},"sort":[{"@timestamp":"desc"}],"size":5}'

# Check metrics in APM
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- \
  curl -sk -u "elastic:$ES_PASS" \
  "https://localhost:9200/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{"query":{"bool":{"must":[{"exists":{"field":"metric"}},{"term":{"service.name":"snd-dwh-dagster-platform"}}]}},"sort":[{"@timestamp":"desc"}],"size":5}'

# Check run tags for code location
kubectl -n snd-dwh exec dagster-platform-postgresql-0 -- psql -U postgres -d postgres -c "
SELECT key, value FROM run_tags WHERE run_id = '<run_id>' ORDER BY key;
"
```

## Forked dbt-dagsterizer

Repository: https://github.com/devops6668/dbt-dagsterizer

Changes from upstream:
- Transaction name includes code location: `job/{code_location}/{job_name}`
- Backward compatible: falls back to `job/{job_name}` if no code location

## Related Guides

- [dagster-metrics-guide.md](../dagster-metrics/dagster-metrics-guide.md) — metrics-exporter setup
- [dagster-metrics-apm-integration-guide.md](../dagster-metrics/dagster-metrics-apm-integration-guide.md) — APM integration

# APM Data Stream Lifecycle Management

APM-managed data streams use **data stream lifecycle** (DSL, `lifecycle.data_retention`)
rather than legacy ILM policies. Retention is configured via **component templates**
that get composed into index templates.

## Component Template Naming Convention

APM ships pre-built lifecycle component templates:

| Template | Retention | Used By |
|----------|-----------|---------|
| `apm-90d@lifecycle` | 90 days | 1m-interval metrics (transaction, service_summary, service_destination, service_transaction, internal, app) |
| `apm-180d@lifecycle` | 180 days | 10m-interval metrics |
| `apm-390d@lifecycle` | 390 days | 60m-interval metrics |

## How Retention Flows

```
Component Template (apm-90d@lifecycle) 
  → composed_of in Index Template (metrics-apm.app@template) 
    → applies to Data Stream (metrics-apm.app.my_service-default) 
      → applies to Backing Index (.ds-metrics-apm.app...-000001)
```

## Changing Retention

### 1. Create a custom lifecycle component template

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -u elastic:\"\$ES_PASS\" -X PUT 'https://localhost:9200/_component_template/apm-7d@lifecycle' \
    -H 'Content-Type: application/json' \
    -d '{
      \"template\": {
        \"lifecycle\": {
          \"enabled\": true,
          \"data_retention\": \"7d\"
        }
      },
      \"version\": 1,
      \"_meta\": {
        \"managed\": false,
        \"description\": \"Custom 7-day retention\"
      }
    }'"
```

### 2. Update the index template to use the new lifecycle

Replace `apm-90d@lifecycle` with `apm-7d@lifecycle` in the `composed_of` array.
Include **all** original component templates — the PUT replaces the entire template.

```bash
ES_PASS=$(cat /tmp/es_pass)

kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -u elastic:\"\$ES_PASS\" -X PUT 'https://localhost:9200/_index_template/metrics-apm.app@template' \
    -H 'Content-Type: application/json' \
    -d '{
      \"index_patterns\": [\"metrics-apm.app.*-*\"],
      \"template\": {
        \"settings\": {
          \"index\": {
            \"default_pipeline\": \"metrics-apm.app@default-pipeline\",
            \"final_pipeline\": \"metrics-apm@pipeline\"
          }
        }
      },
      \"composed_of\": [
        \"metrics@mappings\",
        \"apm@mappings\",
        \"apm@settings\",
        \"apm-7d@lifecycle\",
        \"metrics-apm@mappings\",
        \"metrics-apm@settings\",
        \"metrics@custom\",
        \"metrics-apm.app@custom\",
        \"ecs@mappings\"
      ],
      \"priority\": 210,
      \"version\": 7,
      \"_meta\": {
        \"managed\": false,
        \"description\": \"Index template for metrics-apm.app.*-* (custom 7d retention)\"
      },
      \"data_stream\": {
        \"hidden\": false,
        \"allow_custom_routing\": false
      },
      \"allow_auto_create\": true,
      \"ignore_missing_component_templates\": [
        \"metrics@custom\",
        \"metrics-apm.app@custom\"
      ]
    }'"
```

### 3. Apply lifecycle to the existing data stream

The template change only affects **new** backing indices after rollover.
Apply directly to the current data stream:

```bash
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -u elastic:\"\$ES_PASS\" -X PUT \\
    'https://localhost:9200/_data_stream/<data-stream-name>/_lifecycle' \
    -H 'Content-Type: application/json' \
    -d '{\"data_retention\": \"7d\"}'
"
```

**Note:** This uses `PUT` — the `/_lifecycle` endpoint on a data stream
accepts `GET`, `PUT`, and `DELETE` (not `POST`).

### 4. Verify

```bash
# Check current data stream lifecycle
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -u elastic:\"\$ES_PASS\" \\
    'https://localhost:9200/_data_stream/<data-stream-name>?pretty' | grep -A 10 lifecycle
"
```

## Including Other APM Metric Data Streams

To apply the same 7d retention to **all** APM 1m-metric data streams, repeat step 2
for each index template:

| Index Template | Pattern | Current Lifecycle |
|---|---|---|
| `metrics-apm.app@template` | `metrics-apm.app.*-*` | `apm-90d@lifecycle` |
| `metrics-apm.transaction.1m@template` | `metrics-apm.transaction.1m-*` | `apm-90d@lifecycle` |
| `metrics-apm.service_summary.1m@template` | `metrics-apm.service_summary.1m-*` | `apm-90d@lifecycle` |
| `metrics-apm.service_destination.1m@template` | `metrics-apm.service_destination.1m-*` | `apm-90d@lifecycle` |
| `metrics-apm.service_transaction.1m@template` | `metrics-apm.service_transaction.1m-*` | `apm-90d@lifecycle` |
| `metrics-apm.internal@template` | `metrics-apm.internal-*` | `apm-90d@lifecycle` |

Retrieve each template's current `composed_of` before modifying, so you preserve
all other component templates:

```bash
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -u elastic:\"\$ES_PASS\" \
    'https://localhost:9200/_index_template/metrics-apm.transaction.1m@template?pretty'
" | jq '.index_templates[0].index_template.composed_of'
```

## Pitfalls

- **Managed templates have `_meta.managed: true`** — APM's built-in templates mark
  themselves as managed. Setting `_meta.managed: false` on the override prevents
  confusion. APM won't revert your custom template on upgrade (it creates version N+1
  as a separate entity).
- **Data stream lifecycle ≠ ILM policy** — These APM data streams use the newer
  "data stream lifecycle" feature (`lifecycle.data_retention`), not the legacy
  ILM `index.lifecycle.name`. Don't try to set an ILM policy on them — it won't
  take effect if `next_generation_managed_by: Data stream lifecycle`.
- **The PUT replaces the entire template** — when updating `composed_of`, you must
  include ALL component templates, not just the one you're changing. Use the GET
  output as your starting point.
- **Verify `data_retention` value format** — Elasticsearch accepts `7d`, `90d`,
  `180d`, `390d` etc. Unit suffixes: `d` (days), `h` (hours), `m` (minutes).

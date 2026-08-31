# Kibana Dashboard Creation via API

Create a Dagster metrics dashboard programmatically using Kibana's saved objects API.

## Prerequisites

- Kibana accessible (e.g., `https://kibana.luban.paulhome.local`)
- Elasticsearch credentials (`elastic` user password from `elastic-cluster-es-elastic-user` secret)

## API Note: Kibana 8.x License Limitations

**Critical: Elastic license tier determines what APIs work.**

| Feature | Basic License | Enterprise License |
|---------|:------------:|:-----------------:|
| `api/data_views/data_view` (field discovery works) | ❌ UI can't load | ✅ Full support |
| `api/saved_objects/index-pattern` (fieldAttrs may stay empty) | ✅ Works (but fields may show 0) | ✅ Full support |
| `line`, `horizontal_bar` visualization types | ❌ May hang / show "loading" | ✅ Full support |
| `metric`, `table` visualization types | ✅ Works | ✅ Full support |
| Existing `metrics-*` pattern (pre-populated by Elastic APM) | ✅ Works | ✅ Full support |

### Workaround for Basic License

The `data_views` API discovers fields correctly, but the resulting data view can't be **loaded** in the UI without an Enterprise license. The error is: *"data-view can't be loaded. Please upgrade to the default distribution of Elasticsearch and Kibana with the appropriate license."*

Instead, use the existing `metrics-*` index pattern (created by Elastic APM, pre-populated with fields) and create only **simple visualization types**:

```bash
# ✅ Use existing metrics-* pattern (works with basic license)
curl -sk -u "elastic:${ES_PASS}" -X POST \
  "https://kibana.luban.paulhome.local/api/saved_objects/visualization/<id>" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{
    "attributes": { ... },
    "references": [{"id":"metrics-*","name":"kibanaSavedObjectMeta.searchSourceJSON.index","type":"index-pattern"}]
  }'
```

If you must create a new index pattern with a different title, create it via the saved-objects API and then manually click **"Refresh field list"** in the Kibana UI (Stack Management → Data Views → select pattern → Refresh field list).

## Process

### 1. Create Data View

```bash
curl -sk -u "elastic:${ES_PASS}" -X POST \
  "https://kibana.luban.paulhome.local/api/data_views/data_view" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"data_view":{"id":"metrics-apm","title":"metrics-apm*","name":"Dagster Metrics","timeFieldName":"@timestamp"}}'
```

If the data view already exists and needs to be replaced, add `,"override":true` to the payload.

### 2. Create Individual Visualizations (one at a time)

Because the ndjson bulk import (`_import` endpoint) can return 500 errors for format mismatches, create each visualization individually:

```bash
curl -sk -u "elastic:${ES_PASS}" -X POST \
  "https://kibana.luban.paulhome.local/api/saved_objects/visualization/<id>" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "title": "[Dagster] Visualization Title",
      "version": 1,
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"metrics-apm\",\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
      },
      "uiStateJSON": "{}",
      "visState": "<JSON for vis type and aggs>"
    },
    "references": [{"id":"metrics-apm","name":"kibanaSavedObjectMeta.searchSourceJSON.index","type":"data-view"}]
  }'
```

### 3. Visualization Types Used

**⚠️ License note**: With Basic license, avoid `line`, `area`, `horizontal_bar`, and `vertical_bar` — these may display "loading" indefinitely. Use `metric` and `table` instead.

**Metric card** (single number — works with Basic license):
```json
{
  "type": "metric",
  "aggs": [{"id":"1","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.queue.depth","customLabel":"Queue Depth"}}],
  "params": {"metric":{"colorSchema":"Green to Red","colorsRange":[{"from":0,"to":100}],"labels":{"show":true},"fontSize":40}}
}
```

**Data table** (multiple metrics in tabular form — works with Basic license):
```json
{
  "type": "table",
  "aggs": [
    {"id":"1","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.queue.depth","customLabel":"Queue Depth"}},
    {"id":"2","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.in_progress.count","customLabel":"In Progress"}},
    {"id":"3","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.queue.oldest_age_seconds","customLabel":"Oldest (s)"}}
  ],
  "params": {"perPage":10,"showPartialRows":false,"showMetricsAtAllLevels":false}
}
```

**Line chart** (over time — may not work with Basic license):
```json
{
  "type": "line",
  "aggs": [
    {"id":"1","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.queue.depth","customLabel":"Queue Depth"}},
    {"id":"2","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.run.in_progress.count","customLabel":"In Progress"}},
    {"id":"4","enabled":true,"type":"date_histogram","schema":"segment","params":{"field":"@timestamp"}}
  ]
}
```

**Horizontal bar** (by label — use `max` not `avg` since each daemon type has its own document):
```json
{
  "type": "horizontal_bar",
  "aggs": [
    {"id":"1","enabled":true,"type":"max","schema":"metric","params":{"field":"dagster.daemon.heartbeat_age_seconds","customLabel":"Age (s)"}},
    {"id":"2","enabled":true,"type":"terms","schema":"segment","params":{"field":"labels.dagster_daemon_type","size":10,"order":"desc","orderBy":"1","customLabel":"Daemon Type"}}
  ]
}
```

### 4. Create Dashboard

```bash
DASHBOARD_PANELS='[{"version":"8.15.0","gridData":{"x":0,"y":0,"w":8,"h":3,"i":"1"},"panelIndex":"1","embeddableConfig":{},"panelRefName":"panel_1"},...]'

curl -sk -u "elastic:${ES_PASS}" -X POST \
  "https://kibana.luban.paulhome.local/api/saved_objects/dashboard/<dashboard-id>" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d "{
    \"attributes\": {
      \"title\": \"[Dagster] Platform Health Dashboard\",
      \"hits\": 0,
      \"kibanaSavedObjectMeta\": {\"searchSourceJSON\":\"{\\\"query\\\":{\\\"query\\\":\\\"\\\",\\\"language\\\":\\\"kuery\\\"},\\\"filter\\\":[]}\"},
      \"optionsJSON\": \"{\\\"hidePanelTitles\\\":false,\\\"useMargins\\\":true}\",
      \"panelsJSON\": $(echo "$DASHBOARD_PANELS" | jq -Rs .),
      \"version\": 1
    },
    \"references\": [
      {\"id\":\"dagster-run-queue-depth\",\"name\":\"panel_1\",\"type\":\"visualization\"},
      ...
    ]
  }'
```

## ES Field Mapping

The dagster metrics are stored in `metrics-apm.app.*` data streams. Fields are `double` type:

| ES Field Path | Type | Metric |
|--------------|------|--------|
| `dagster.daemon.heartbeat.count` | double | daemon heartbeat count |
| `dagster.daemon.heartbeat_age_seconds` | double | heartbeat age per daemon type |
| `dagster.daemon.heartbeat_errors.count` | double | heartbeat error count |
| `dagster.run.queue.depth` | double | queued run count |
| `dagster.run.queue.oldest_age_seconds` | double | oldest queued run age |
| `dagster.run.in_progress.count` | double | running run count |
| `dagster.schedule.enabled.count` | double | enabled schedule count |
| `dagster.sensor.enabled.count` | double | enabled sensor count |

Labels are stored in `labels.*` path (e.g., `labels.dagster_daemon_type`, `labels.dagster_component`).

## Recommended Naming Convention

Use short, structured IDs for visualizations to avoid URL-encoding issues in shell scripts. Group by section:

```
r1, r2, r3      → Runs section
s1, s2, s3, s4  → Sensors & Schedules section  
d1, d2, d3      → Daemon Health section
```

## Dashboard Layout (10 Panels)

### Row 1 — Runs (3 metric cards)

| x=0 | x=8 | x=16 |
|-----|-----|------|
| Queue Depth | Queue Oldest Age (s) | In Progress |

### Row 2 — Sensors & Schedules (4 metric cards)

| x=0 | x=6 | x=12 | x=18 |
|-----|-----|------|------|
| Sensors Enabled | Schedules Enabled | Sensor Last Tick (s) | Schedule Last Tick (s) |

### Row 3 — Daemon Health (1 metric + 2 data tables)

| x=0 (w=8) | x=8 (w=8, h=5) | x=16 (w=8, h=5) |
|-----------|-----------------|------------------|
| Heartbeat Count | Age by Type (table) | Errors by Type (table) |

## Metric Color Ranges (Alert Thresholds)

Use `colorsRange` and `invertColors` in the metric `params` to encode alert severity directly in the card color:

```python
# For "warn > 300s, crit > 900s" (queue age, sensor tick age)
{"colorsRange": [
    {"from": 0, "to": 300},     # green — healthy
    {"from": 300, "to": 900},   # yellow — warn threshold
    {"from": 900, "to": 99999}  # red — critical
]}

# For "crit if == 0" (heartbeat count, sensors/schedules enabled)  
# invertColors=True makes low values red, high values green
{"invertColors": True, "colorsRange": [
    {"from": 0, "to": 0},     # red — 0 is bad
    {"from": 0, "to": 100}    # green — anything >0 is good
]}

# For "warn > 120s, crit > 300s" (daemon heartbeat age)
{"colorsRange": [
    {"from": 0, "to": 120},     # green
    {"from": 120, "to": 300},   # yellow
    {"from": 300, "to": 99999}  # red
]}
```

## Pitfalls

- **📋 CRITICAL: License tier limits visualization types** — `line`, `area`, `horizontal_bar`, and `vertical_bar` chart types may hang indefinitely ("loading") with Basic license. Use `metric` cards and `data table` instead.
- **Use existing `metrics-*` index pattern** if available (pre-populated by Elastic APM). Creating new index patterns via the `api/saved_objects/index-pattern` endpoint may produce 0 `fieldAttrs` even after refreshing. The `api/data_views/data_view` API discovers fields correctly, but the resulting data view can't be loaded in the UI without Enterprise license.
- **Visualization reference type** must match the data view type:
  - For index-pattern saved objects: `"type":"index-pattern"` and `"id":"metrics-*"`
  - For data views (Enterprise license): `"type":"data-view"`
- **Individual creation via API** works better than bulk ndjson import (`_import` endpoint can give 500 errors for format mismatches)
- **`panelRefName`** must match the `references[].name` exactly (e.g., `panel_1` ↔ `references[].name: "panel_1"`)
- **Kibana version**: The `version` field in panel JSON should match Kibana's version (e.g., `"8.15.0"`)
- **Fields only appear after data is indexed** — empty data streams may show no fields in the index pattern field list
- **The `_find` API may return 0 results** across different Kibana spaces — use direct ID lookups instead
- **Daemon aggregation: use `max` not `avg`** — Each daemon type gets its own document (not all in one doc), so `avg` across docs dilutes the value. Use `max` to get the latest heartbeat age/error count per daemon type.

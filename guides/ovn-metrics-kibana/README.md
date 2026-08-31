# OVN CNI Metrics to Kibana Dashboard Guide

## Overview

This guide documents how to export OVN (Open Virtual Network) CNI metrics from Prometheus on an OpenShift cluster to an external Elasticsearch/Kibana instance, and create a Kibana dashboard for monitoring OVN health.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster                            │
│                     (lab.devops.local)                              │
│                                                                     │
│  ┌──────────────────────┐     ┌──────────────────────────────┐     │
│  │   OVN Kubernetes     │────>│      Prometheus              │     │
│  │   (ovnkube-node)     │     │  (openshift-monitoring)      │     │
│  │                      │     │                              │     │
│  │  - ovn_northd_status │     │  - 200+ OVN metrics          │     │
│  │  - ovn_controller_*  │     │  - Scraped every 15s         │     │
│  │  - ovnkube_*         │     │  - 8h retention              │     │
│  │  - ovs_*             │     │                              │     │
│  └──────────────────────┘     └──────────────┬───────────────┘     │
│                                              │                     │
│  ┌───────────────────────────────────────────▼───────────────┐     │
│  │              OVN Exporter (curlimages/curl)                │     │
│  │              Namespace: elastic-agent                      │     │
│  │                                                            │     │
│  │  - Queries Prometheus every 30s                            │     │
│  │  - Exports ~228 metrics per cycle                          │     │
│  │  - Sends to external Elasticsearch                         │     │
│  └───────────────────────────────────────────┬───────────────┘     │
│                                              │                     │
└──────────────────────────────────────────────┼─────────────────────┘
                                               │
                    ┌──────────────────────────▼─────────────────────┐
                    │              k3s Cluster                        │
                    │           (192.168.89.61)                       │
                    │                                                  │
                    │  ┌────────────────┐    ┌──────────────────┐     │
                    │  │ Elasticsearch  │───>│     Kibana       │     │
                    │  │  (8.17.0)      │    │  (8.17.0)        │     │
                    │  │                │    │                   │     │
                    │  │  Index:        │    │  Dashboard:       │     │
                    │  │  ovn-metrics-* │    │  OVN CNI Status   │     │
                    │  └────────────────┘    └──────────────────┘     │
                    │                                                  │
                    └─────────────────────────────────────────────────┘
```

## Prerequisites

### On OpenShift Cluster
- OpenShift 4.x with OVN-Kubernetes CNI
- Prometheus accessible at: `https://prometheus-k8s-openshift-monitoring.apps.lab.devops.local:443`
- Bearer token with Prometheus query permissions

### On k3s Cluster
- Elasticsearch 8.x running at: `https://es.luban.paulhome.local:443`
- Kibana 8.x running at: `https://kibana.luban.paulhome.local:443`
- Elastic credentials: `elastic` / `adD2JMUtidUs9Zfno4tnDImc`

### DNS
```
es.luban.paulhome.local      → 192.168.89.61
kibana.luban.paulhome.local  → 192.168.89.61
```

---

## Step 1: Get Prometheus Token

### Option A: Use Your User Token (Recommended)

If you have cluster-admin or monitoring-view permissions, use your own session token:

```bash
# Login to OpenShift first
oc login https://api.lab.devops.local:6443 -u <username> -p <password>

# Get your bearer token
oc whoami -t
# Output: sha256~xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Option B: Find Existing Service Account Tokens

Check for existing tokens in `openshift-monitoring` namespace:

```bash
# List all token secrets
oc get secret -n openshift-monitoring | grep token

# Example output:
# alertmanager-main-token-5xrj2          kubernetes.io/service-account-token   4   3y
# cluster-monitoring-operator-token-xxx  kubernetes.io/service-account-token   4   3y
# default-token-q4n9r                   kubernetes.io/service-account-token   4   3y
# kube-state-metrics-token-xxx          kubernetes.io/service-account-token   4   3y
# node-exporter-token-xxx               kubernetes.io/service-account-token   4   3y

# Decode a specific token (e.g., default-token)
oc get secret default-token-q4n9r -n openshift-monitoring \
  -o jsonpath='{.data.token}' | base64 -d
# Output: eyJhbGciOiJSUzI1NiIs...
```

### Option C: Create a Dedicated ServiceAccount with Monitoring Access

```bash
# Create service account
oc create serviceaccount ovn-exporter -n openshift-monitoring

# Grant permissions to read Prometheus
oc adm policy add-cluster-role-to-user monitoring-view \
  system:serviceaccount:openshift-monitoring:ovn-exporter

# Get the token
oc create token ovn-exporter -n openshift-monitoring --duration=87600h
# Output: eyJhbGciOiJSUzI1NiIs...
```

### Option D: Use Thanos Querier Token

The Thanos Querier service account can query Prometheus:

```bash
# Find thanos-querier token
oc get secret -n openshift-monitoring | grep thanos

# Decode it
oc get secret thanos-querier-token-xxx -n openshift-monitoring \
  -o jsonpath='{.data.token}' | base64 -d
```

### Verify Token Works

Test the token against Prometheus:

```bash
TOKEN=$(oc whoami -t)

curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "https://prometheus-k8s-openshift-monitoring.apps.lab.devops.local:443/api/v1/query?query=ovn_northd_status"
```

Expected response:
```json
{"status":"success","data":{"resultType":"vector","result":[...]}}
```

### Create the Secret

Once you have a working token:

```bash
# Save token to file
oc whoami -t > /tmp/prom-token.txt

# Create secret
oc create secret generic prometheus-token \
  --from-file=token=/tmp/prom-token.txt \
  -n elastic-agent

# Clean up
rm /tmp/prom-token.txt
```

## Step 2: Create the OVN Exporter Deployment

The exporter uses `curlimages/curl` to query Prometheus and send data to Elasticsearch.

### 2.1 Create Namespace (if not exists)
```bash
oc create namespace elastic-agent
```

### 2.2 Create the Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ovn-exporter
  namespace: elastic-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ovn-exporter
  template:
    metadata:
      labels:
        app: ovn-exporter
    spec:
      serviceAccountName: default
      tolerations:
      - operator: Exists
      hostAliases:
      - ip: 192.168.89.61
        hostnames:
        - es.luban.paulhome.local
        - kibana.luban.paulhome.local
      - ip: 192.168.138.9
        hostnames:
        - prometheus-k8s-openshift-monitoring.apps.lab.devops.local
      containers:
      - name: exporter
        image: curlimages/curl:latest
        env:
        - name: PROM_TOKEN
          valueFrom:
            secretKeyRef:
              name: prometheus-token
              key: token
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting OVN Metrics Exporter..."
          PROM_HOST="prometheus-k8s-openshift-monitoring.apps.lab.devops.local"
          ES_HOST="es.luban.paulhome.local"
          ES_AUTH="elastic:adD2JMUtidUs9Zfno4tnDImc"
          QUERIES="ovn_northd_status ovn_controller_southbound_database_connected ovnkube_controller_leader ovn_db_db_size_bytes ovn_controller_integration_bridge_openflow_total ovn_controller_flow_generation_total_samples ovn_controller_flow_installation_total_samples ovnkube_controller_num_egress_firewalls ovnkube_controller_num_egress_ips ovnkube_controller_admin_network_policies ovn_northd_build_info ovs_vswitchd_bridge_total ovs_vswitchd_dp_flows_total ovn_controller_integration_bridge_geneve_ports ovn_controller_integration_bridge_patch_ports ovn_controller_txn_success ovn_northd_txn_success ovn_northd_lflows_datapaths_maximum ovn_controller_monitor_all"

          while true; do
            exported=0
            for q in $QUERIES; do
              result=$(curl -sk -H "Authorization: Bearer ${PROM_TOKEN}" "https://${PROM_HOST}:443/api/v1/query?query=${q}" 2>/dev/null)
              if echo "$result" | grep -q '"status":"success"'; then
                count=$(echo "$result" | grep -o '"instance"' | wc -l)
                ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                for i in $(seq 1 $count); do
                  instance=$(echo "$result" | grep -o '"instance":"[^"]*"' | sed -n "${i}p" | cut -d'"' -f4)
                  pod=$(echo "$result" | grep -o '"pod":"[^"]*"' | sed -n "${i}p" | cut -d'"' -f4)
                  job=$(echo "$result" | grep -o '"job":"[^"]*"' | sed -n "${i}p" | cut -d'"' -f4)
                  ns=$(echo "$result" | grep -o '"namespace":"[^"]*"' | sed -n "${i}p" | cut -d'"' -f4)
                  val=$(echo "$result" | grep -o '\[[0-9.]*,"[0-9.]*"\]' | sed -n "${i}p" | grep -o ',"[^"]*"\]' | tr -d ',"]')
                  doc="{\"@timestamp\":\"${ts}\",\"metric_name\":\"${q}\",\"instance\":\"${instance}\",\"pod\":\"${pod}\",\"job\":\"${job}\",\"namespace\":\"${ns}\",\"value\":${val:-0},\"cluster\":\"lab.devops.local\"}"
                  curl -sk -X POST "https://${ES_HOST}:443/ovn-metrics-/_doc" \
                    -H "Content-Type: application/json" \
                    -u "${ES_AUTH}" \
                    -d "${doc}" 2>/dev/null
                  exported=$((exported + 1))
                done
              fi
            done
            echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Exported ${exported} metrics"
            sleep 30
          done
        securityContext:
          runAsUser: 0
```

Apply:
```bash
oc apply -f ovn-exporter-deployment.yaml
```

### 2.3 Verify
```bash
# Check pod is running
oc get pods -n elastic-agent

# Check logs
oc logs -n elastic-agent -l app=ovn-exporter --tail=20

# Check data in Elasticsearch
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://es.luban.paulhome.local/ovn-metrics-/_count"
```

---

## Step 3: Create Kibana Data View

In Kibana, create a Data View to index the OVN metrics:

1. Go to **Stack Management** > **Data Views**
2. Click **Create data view**
3. Set:
   - **Name**: `OVN Metrics`
   - **Pattern**: `ovn-metrics-*`
   - **Timestamp field**: `@timestamp`
4. Click **Save data view to Kibana**

Or via API:
```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/data_views/data_view" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "data_view": {
      "title": "ovn-metrics-*",
      "name": "OVN Metrics",
      "timeFieldName": "@timestamp"
    }
  }'
```

---

## Step 4: Create Kibana Visualizations

### 4.1 OVN Total Metrics (Metric Counter)

```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/saved_objects/visualization/ovn-metric-count" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "description": "",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"<DATA_VIEW_ID>\",\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
      },
      "title": "OVN Total Metrics",
      "uiStateJSON": "{}",
      "version": 1,
      "visState": "{\"type\":\"metric\",\"params\":{\"addTooltip\":true,\"addLegend\":false,\"type\":\"count\"},\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"params\":{},\"schema\":\"metric\"}]}"
    },
    "references": []
  }'
```

### 4.2 OVN Metrics by Name and Pod (Data Table)

```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/saved_objects/visualization/ovn-data-table" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "description": "",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"<DATA_VIEW_ID>\",\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
      },
      "title": "OVN Metrics by Name and Pod",
      "uiStateJSON": "{}",
      "version": 1,
      "visState": "{\"type\":\"data_table\",\"params\":{\"perPage\":25,\"showPartialRows\":false,\"showMetricsAtAllLevels\":false,\"showTotal\":true,\"totalFunc\":\"sum\"},\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"params\":{},\"schema\":\"metric\"},{\"id\":\"2\",\"enabled\":true,\"type\":\"terms\",\"params\":{\"field\":\"metric_name.keyword\",\"size\":20,\"order\":\"desc\",\"orderBy\":\"1\"},\"schema\":\"bucket\"},{\"id\":\"3\",\"enabled\":true,\"type\":\"terms\",\"params\":{\"field\":\"pod.keyword\",\"size\":20,\"order\":\"desc\",\"orderBy\":\"1\"},\"schema\":\"bucket\"},{\"id\":\"4\",\"enabled\":true,\"type\":\"max\",\"params\":{\"field\":\"value\"},\"schema\":\"metric\"}]}"
    },
    "references": []
  }'
```

### 4.3 OVN Metrics by Node (Histogram)

```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/saved_objects/visualization/ovn-metrics-histogram" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "description": "",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"<DATA_VIEW_ID>\",\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
      },
      "title": "OVN Metrics by Node",
      "uiStateJSON": "{}",
      "version": 1,
      "visState": "{\"type\":\"histogram\",\"params\":{\"type\":\"histogram\",\"grid\":{\"categoryLines\":false},\"categoryAxes\":[{\"id\":\"CategoryAxis-1\",\"type\":\"category\",\"position\":\"bottom\",\"show\":true,\"labels\":{\"show\":true,\"filter\":true,\"truncate\":100}}],\"valueAxes\":[{\"id\":\"ValueAxis-1\",\"name\":\"LeftAxis-1\",\"type\":\"value\",\"position\":\"left\",\"show\":true,\"labels\":{\"show\":true,\"rotate\":0,\"filter\":false,\"truncate\":100}}],\"seriesParams\":[{\"show\":true,\"type\":\"histogram\",\"mode\":\"stacked\",\"data\":{\"label\":\"Count\",\"id\":\"1\"},\"valueAxis\":\"ValueAxis-1\",\"drawLinesBetweenPoints\":true,\"showCircles\":true}],\"addTooltip\":true,\"addLegend\":true,\"legendPosition\":\"right\",\"times\":[],\"addTimeMarker\":false},\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"params\":{},\"schema\":\"metric\"},{\"id\":\"2\",\"enabled\":true,\"type\":\"terms\",\"params\":{\"field\":\"instance.keyword\",\"size\":20,\"order\":\"desc\",\"orderBy\":\"1\"},\"schema\":\"segment\"}]}"
    },
    "references": []
  }'
```

> **Note**: Replace `<DATA_VIEW_ID>` with the actual ID of your "OVN Metrics" data view.

---

## Step 5: Create Kibana Dashboard

### 5.1 Delete Existing Dashboard (if any)
```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/saved_objects/dashboard/ovn-dashboard" \
  -H "kbn-xsrf: true" -X DELETE
```

### 5.2 Create Dashboard
```bash
curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://kibana.luban.paulhome.local/api/saved_objects/dashboard/ovn-dashboard" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "description": "OVN CNI health and metrics for lab.devops.local",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"filter\":[],\"query\":{\"language\":\"kuery\",\"query\":\"\"}}"
      },
      "optionsJSON": "{\"hidePanelTitles\":false,\"useMargins\":true}",
      "panelsJSON": "[{\"gridData\":{\"x\":0,\"y\":0,\"w\":24,\"h\":12,\"i\":\"p1\"},\"panelIndex\":\"p1\",\"type\":\"visualization\",\"panelRefName\":\"panel_p1\"},{\"gridData\":{\"x\":24,\"y\":0,\"w\":24,\"h\":12,\"i\":\"p2\"},\"panelIndex\":\"p2\",\"type\":\"visualization\",\"panelRefName\":\"panel_p2\"},{\"gridData\":{\"x\":0,\"y\":12,\"w\":48,\"h\":20,\"i\":\"p3\"},\"panelIndex\":\"p3\",\"type\":\"visualization\",\"panelRefName\":\"panel_p3\"}]",
      "timeRestore": true,
      "timeTo": "now",
      "timeFrom": "now-1h",
      "refreshInterval": {"pause": false, "value": 30000},
      "title": "OVN CNI Status Dashboard",
      "version": 1
    },
    "references": [
      {"id": "ovn-metric-count", "name": "panel_p1", "type": "visualization"},
      {"id": "ovn-data-table", "name": "panel_p2", "type": "visualization"},
      {"id": "ovn-metrics-histogram", "name": "panel_p3", "type": "visualization"}
    ]
  }'
```

### 5.3 Access Dashboard
```
https://kibana.luban.paulhome.local/app/dashboards#/view/ovn-dashboard
```

---

## OVN Metrics Collected

| Metric Name | Description |
|-------------|-------------|
| `ovn_northd_status` | OVN northd status (1=healthy) |
| `ovn_controller_southbound_database_connected` | SB DB connection status |
| `ovnkube_controller_leader` | OVNKube controller leader election |
| `ovn_db_db_size_bytes` | OVN database size in bytes |
| `ovn_controller_integration_bridge_openflow_total` | OpenFlow rules count |
| `ovn_controller_flow_generation_total_samples` | Flow generation samples |
| `ovn_controller_flow_installation_total_samples` | Flow installation samples |
| `ovnkube_controller_num_egress_firewalls` | Egress firewall count |
| `ovnkube_controller_num_egress_ips` | Egress IP count |
| `ovnkube_controller_admin_network_policies` | Admin network policy count |
| `ovn_northd_build_info` | OVN northd build info |
| `ovs_vswitchd_bridge_total` | OVS bridge count |
| `ovs_vswitchd_dp_flows_total` | OVS datapath flows count |
| `ovn_controller_integration_bridge_geneve_ports` | Geneve tunnel ports |
| `ovn_controller_integration_bridge_patch_ports` | Patch ports count |
| `ovn_controller_txn_success` | Successful transactions |
| `ovn_northd_txn_success` | Northd successful transactions |
| `ovn_northd_lflows_datapaths_maximum` | Max logical flows per datapath |
| `ovn_controller_monitor_all` | Controller monitor status |
| `ovnkube_controller_ready_duration_seconds` | Controller ready duration |

---

## Elasticsearch Document Format

Each metric is stored as:

```json
{
  "@timestamp": "2026-07-22T03:02:37Z",
  "metric_name": "ovn_northd_status",
  "instance": "192.168.138.21:9105",
  "pod": "ovnkube-node-kg2sk",
  "job": "ovnkube-node",
  "namespace": "openshift-ovn-kubernetes",
  "value": 1,
  "cluster": "lab.devops.local"
}
```

---

## Troubleshooting

### Exporter Pod Not Running
```bash
# Check events
oc get events -n elastic-agent --sort-by='.lastTimestamp'

# Check deployment status
oc get deployment ovn-exporter -n elastic-agent -o yaml

# Scale up if needed
oc scale deployment ovn-exporter -n elastic-agent --replicas=1
```

### No Data in Elasticsearch
```bash
# Check exporter logs
oc logs -n elastic-agent -l app=ovn-exporter --tail=50

# Test Prometheus access from pod
oc exec -n elastic-agent <pod-name> -- \
  curl -sk -H "Authorization: Bearer $PROM_TOKEN" \
  "https://prometheus-k8s-openshift-monitoring.apps.lab.devops.local:443/api/v1/query?query=ovn_northd_status"

# Test Elasticsearch access from pod
oc exec -n elastic-agent <pod-name> -- \
  curl -sk -u elastic:adD2JMUtidUs9Zfno4tnDImc \
  "https://es.luban.paulhome.local/ovn-metrics-/_count"
```

### Kibana Dashboard Error
If you see "Cannot read properties of undefined (reading 'searchSourceJSON')":
1. Ensure the dashboard has `kibanaSavedObjectMeta` attribute
2. Ensure the dashboard has `version: 1` attribute
3. Ensure all visualizations have `kibanaSavedObjectMeta` with `searchSourceJSON`
4. Ensure dashboard `references` array matches `panelRefName` in `panelsJSON`

---

## Credentials Summary

| Service | URL | User | Password |
|---------|-----|------|----------|
| Elasticsearch | https://es.luban.paulhome.local | elastic | adD2JMUtidUs9Zfno4tnDImc |
| Kibana | https://kibana.luban.paulhome.local | elastic | adD2JMUtidUs9Zfno4tnDImc |
| Prometheus | https://prometheus-k8s-openshift-monitoring.apps.lab.devops.local | Bearer Token | (see prometheus-token secret) |

---

## Files

| File | Description |
|------|-------------|
| `ovn-exporter-deployment.yaml` | OVN Exporter Deployment manifest |
| `kibana-visualizations.sh` | Script to create Kibana visualizations |
| `kibana-dashboard.sh` | Script to create Kibana dashboard |

---

*Last updated: 2026-07-22*
*Cluster: lab.devops.local (OpenShift 4.x + k3s 1.33.0)*

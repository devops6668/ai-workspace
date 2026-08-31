# OSSM 3 Observability Setup - Step by Step Guide

Updated for OSSM 3.3 based on official Red Hat docs:
- https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/observability/index
- https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/migrating_from_service_mesh_2_to_service_mesh_3/index

**PREREQUISITE:** You must be running OSSM 2.6.14 before migrating to OSSM 3.x.

---

## Current Cluster State (as of 2026-06-26)

| Component | Status | Details |
|-----------|--------|---------|
| OSSM 2 SMCP | **REMOVED** | No SMCP found in istio-system |
| OSSM 3 Istio | **INSTALLED** | `basic` revision, v1.24.3, Healthy, RevisionBased strategy |
| Istiod | **RUNNING** | 2 replicas on infra04/infra05 (infra node selector + tolerations) |
| Ingress Gateway | **RUNNING** | 2 replicas (gateway-injected, not SMCP-managed) |
| Kiali Operator | **INSTALLED** | v2.22.5 |
| Kiali Pod | **RUNNING** | 1 replica |
| Kiali Route | **CREATED** | kiali-istio-system.apps.lab.devops.local |
| Tempo Operator | **INSTALLED** | v0.21.0-1 |
| TempoStack | **NOT DEPLOYED** | No TempoStack found in tempo namespace |
| Tempo Namespace | **NOT CREATED** | `tempo` namespace does not exist |
| OTel Collector | **NOT DEPLOYED** | No OpenTelemetryCollector found |
| Telemetry CR | **NOT DEPLOYED** | No Telemetry CR found in istio-system |
| ServiceMonitor | **NOT DEPLOYED** | Not yet created |
| PodMonitor | **NOT DEPLOYED** | Not yet created |
| Mesh Namespaces | **LABELED** | project-05, devops, istio-system, mesh-demo-1..5, project-01..05 |
| Namespace Label | `service-mesh: enabled` | discoverySelectors in Istio CR |
| Kiali Config | **PARTIALLY CONFIGURED** | Uses Thanos Querier + Tempo, but needs updates |
| Istio Config | **PARTIALLY CONFIGURED** | extensionProviders set, but no Telemetry CR |

---

## Overview: What Changes in OSSM 3 Observability

In OSSM 2, observability components (Prometheus, Grafana, Jaeger, Kiali) were bundled as add-ons inside the ServiceMeshControlPlane (SMCP). In OSSM 3, they are all managed independently by separate operators:

| OSSM 2 | -> | OSSM 3 |
|--------|----|--------|
| Prometheus addon | -> | Thanos Querier via User Workload Monitoring |
| Grafana addon | -> | Red Hat OpenShift distributed tracing data collection |
| Jaeger addon | -> | Tempo (via Red Hat OpenShift distributed tracing platform) |
| Kiali addon | -> | Kiali Operator provided by Red Hat (separate) |
| SMCP tracing.type | -> | Telemetry CR + Istio extensionProviders |
| ServiceMeshMemberRoll | -> | discoverySelectors + namespace labels |
| istio-injection=enabled | -> | istio.io/rev:<revision> (when multiple control planes) |

Components of Red Hat OpenShift Observability that integrate with OSSM 3:
- OpenShift Monitoring (Thanos Querier for metrics)
- Red Hat OpenShift distributed tracing platform (Tempo for traces)
- Kiali Operator provided by Red Hat (management console)
- OpenShift Service Mesh Console (OSSMC) plugin (optional)

---

## Step 1: Disable OSSM 2 Add-ons (Premigration Checklist)

**[COMPLETED]** — No SMCP found, OSSM 2 already removed.

---

## Step 2: Install Independent Observability Operators

**[PARTIALLY COMPLETE]**

| Operator | Status |
|----------|--------|
| Kiali Operator v2.22.5 | Installed |
| Tempo Operator v0.21.0-1 | Installed |
| Red Hat OpenShift distributed tracing data collection | **NOT INSTALLED** |
| User Workload Monitoring | **VERIFY** |

### 2.1 Install Red Hat OpenShift distributed tracing data collection Operator:
- Go to OperatorHub in OpenShift Console
- Search for "Red Hat build of OpenTelemetry"
- Install the operator (stable channel, All namespaces)
- This provides the OpenTelemetry Collector for trace ingestion

### 2.2 Verify User Workload Monitoring is enabled:
```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml
```
Check if `enableUserWorkload: true` is set under `data.config.yaml`. If not, apply:
```bash
oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'
```

---

## Step 3: Deploy Tempo Stack

**[NOT DONE]**

### 3.1 Create the tempo namespace:
```bash
oc new-project tempo
```

### 3.2 Create a TempoStack instance:

```yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: sample
  namespace: tempo
spec:
  resources:
    frontend:
      limits:
        maxGlobalTracesPerUser: 1000000
    queryFrontend:
      jaegerQuery:
        ingress:
          type: route
    storage:
      secret:
        name: tempo-storage
  template:
    gateway:
      auth:
        anonymous: {}
```

Apply:
```bash
oc apply -f tempo-stack.yaml
```

### 3.3 Verify Tempo is running:
```bash
oc get pods -n tempo
oc get routes -n tempo
```

---

## Step 4: Deploy OpenTelemetry Collector

**[NOT DONE]**

### 4.1 Deploy the OpenTelemetry Collector in the istio-system namespace:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: istio-system
spec:
  mode: deployment
  observability:
    metrics: {}
  deploymentUpdateStrategy: {}
  config: |
    exporters:
      otlp:
        endpoint: 'tempo-sample-distributor.tempo.svc.cluster.local:4317'
        tls:
          insecure: true
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: '0.0.0.0:4317'
          http: {}
    service:
      pipelines:
        traces:
          exporters:
            - otlp
          receivers:
            - otlp
```

> **NOTE:** `spec.config.exporters.otlp.endpoint` defines the Tempo sample distributor service. Adjust the namespace and service name to match your TempoStack deployment.

Apply:
```bash
oc apply -f otel-collector.yaml
```

### 4.2 Verify:
```bash
oc get pods -n istio-system -l app=otel-collector
```

---

## Step 5: Istio Resource — Already Configured

**[COMPLETED]**

Your Istio resource (`basic`) already has:
- `enableTracing: true` in meshConfig
- `extensionProviders` for both `prometheus` and `otel`
- `discoverySelectors` matching `service-mesh: enabled`
- `enableAutoMtls: true`
- `traceSampling: 100`
- `enablePrometheusMerge: true`

No changes needed here.

---

## Step 6: Create the Telemetry CR

**[NOT DONE]**

### 6.1 Combined Telemetry CR for both metrics and tracing:

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  metrics:
    - providers:
        - name: prometheus
  tracing:
    - providers:
        - name: otel
      randomSamplingPercentage: 100
```

Apply:
```bash
oc apply -f telemetry.yaml
```

> **NOTE:** After verifying traces appear, lower `randomSamplingPercentage` to reduce overhead, or set it to `"default"` to use Istio default (100%).

---

## Step 7: Configure OpenShift Monitoring Integration (Metrics)

**[NOT DONE]**

### 7.1 Create a ServiceMonitor for the Istio control plane:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istiod-monitor
  namespace: istio-system
spec:
  targetLabels:
    - app
  selector:
    matchLabels:
      istio: pilot
  endpoints:
    - port: http-monitoring
      interval: 30s
```

### 7.2 Create a PodMonitor for the Istio proxies:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-proxies-monitor
  namespace: istio-system
spec:
  selector:
    matchExpressions:
      - key: istio-prometheus-ignore
        operator: DoesNotExist
  podMetricsEndpoints:
    - path: /stats/prometheus
      interval: 30s
      relabelings:
        - action: keep
          sourceLabels: [__meta_kubernetes_pod_container_name]
          regex: "istio-proxy"
        - action: keep
          sourceLabels: [__meta_kubernetes_pod_annotationpresent_prometheus_io_scrape]
        - action: replace
          regex: '(\d+);(([\w\.\-]*)?(:[0-9]*){1,})'
          sourceLabels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
          targetLabel: __address__
        - action: replace
          regex: '(\d+);(([\w\.\-]*)?(:[0-9]*){1,})'
          sourceLabels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
          targetLabel: __address__
        # Set the 'app' label
        - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_name", "__meta_kubernetes_pod_label_app"]
          separator: ";"
          targetLabel: "app"
          action: replace
          regex: "(.+);.*|.*;(.+)"
          replacement: "${1}${2}"
        # Set the 'version' label
        - sourceLabels: ["__meta_kubernetes_pod_label_app_kubernetes_io_version", "__meta_kubernetes_pod_label_version"]
          separator: ";"
          targetLabel: "version"
          action: replace
          regex: "(.+);.*|.*;(.+)"
          replacement: "${1}${2}"
        # additional labels
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
          action: replace
        - replacement: "mesh_id"
          targetLabel: mesh_id
          action: replace
```

> **IMPORTANT:** The PodMonitor must be applied in **ALL** mesh namespaces, including the Istio control plane namespace.

Mesh namespaces detected:
- `istio-system` (control plane)
- `project-01`, `project-02`, `project-03`, `project-04`, `project-05`
- `devops`
- `mesh-demo-1`, `mesh-demo-2`, `mesh-demo-3`, `mesh-demo-4`, `mesh-demo-5`

Apply to each namespace:
```bash
oc apply -f podmonitor.yaml -n istio-system
oc apply -f podmonitor.yaml -n project-01
oc apply -f podmonitor.yaml -n project-02
oc apply -f podmonitor.yaml -n project-03
oc apply -f podmonitor.yaml -n project-04
oc apply -f podmonitor.yaml -n project-05
oc apply -f podmonitor.yaml -n devops
oc apply -f podmonitor.yaml -n mesh-demo-1
oc apply -f podmonitor.yaml -n mesh-demo-2
oc apply -f podmonitor.yaml -n mesh-demo-3
oc apply -f podmonitor.yaml -n mesh-demo-4
oc apply -f podmonitor.yaml -n mesh-demo-5
```

### 7.3 Validate:
- Go to OpenShift Console -> Observe -> Metrics
- Query: `istio_requests_total`
- Should display Istio request metrics

---

## Step 8: Update Kiali Configuration

**[NEEDS UPDATE]**

Your Kiali is already partially configured:
- Prometheus: connected to Thanos Querier (correct)
- Tracing: provider=tempos, use_grpc=true, url=http://tempo-query-frontend.openshift-tempo.svc.cluster.local:3200
- Grafana: enabled=false (correct)
- **Issue:** `accessible_namespaces: ['**']` is **deprecated** in OSSM 3 — remove it
- **Issue:** `cluster_wide_access: true` is fine (default in OSSM 3)

### 8.1 Create/update the Kiali ClusterRoleBinding for monitoring access:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-monitoring-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: kiali-service-account
    namespace: istio-system
```

### 8.2 Patch the Kiali CR to remove deprecated settings and update tracing URL:

After TempoStack is deployed (Step 3), update the Kiali CR:

```bash
oc patch kiali kiali -n istio-system --type merge -p '{
  "spec": {
    "deployment": {
      "accessible_namespaces": null
    },
    "external_services": {
      "tracing": {
        "enabled": true,
        "provider": "tempo",
        "use_grpc": false,
        "internal_url": "https://tempo-sample-gateway.tempo.svc.cluster.local:8080/api/traces/v1/default/tempo",
        "external_url": "https://tempo-sample-gateway-tempo.apps.<cluster-domain>/api/traces/v1/default/search",
        "health_check_url": "https://tempo-sample-gateway-tempo.apps.<cluster-domain>/api/traces/v1/default/tempo/api/echo",
        "auth": {
          "ca_file": "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt",
          "insecure_skip_verify": false,
          "type": "bearer",
          "use_kiali_token": true
        },
        "tempo_config": {
          "url_format": "jaeger"
        }
      }
    }
  }
}'
```

> **NOTE:** Replace `<cluster-domain>` with your actual cluster domain (e.g., `apps.lab.devops.local`).

---

## Step 9: Verify Integrations

### 9.1 Verify Prometheus metrics in OpenShift Console:
- Go to Observe -> Metrics
- Run query: `istio_requests_total`
- Should return Istio request metrics

### 9.2 Verify traces in Tempo:
- Get the Tempo route: `oc get routes -n tempo`
- Navigate to the Tempo dashboard UI
- Send some traffic to generate traces

### 9.3 Verify Kiali topology graphs:
- Open Kiali URL: `https://kiali-istio-system.apps.lab.devops.local`
- Navigate to Traffic Graph tab
- Verify mesh infrastructure is visible

### 9.4 Verify trace overlays in Kiali:
- Navigate to Workload -> Traces tab in Kiali
- Should see traces correlated with workloads

---

## Step 10: Complete the Migration

**[PARTIALLY COMPLETE]**

### 10.1 Already done:
- OSSM 2 SMCP removed
- OSSM 3 Istio deployed and Healthy
- Workloads migrated (namespaces labeled with `service-mesh: enabled`)

### 10.2 Remove Maistra labels from namespaces (if still present):
```bash
oc get namespace -l maistra.io/ignore-namespace
```
If any namespaces are returned, remove the label:
```bash
oc label namespace <namespace> maistra.io/ignore-namespace-
```

### 10.3 Verify no OSSM 2 resources remain:
```bash
oc get smcp -A
oc get smmr -A
oc get smm -A
```
All should return "No resources found".

---

## Remaining Work Summary

| Step | Status | Action |
|------|--------|--------|
| 1. Disable OSSM 2 add-ons | **DONE** | No action needed |
| 2. Install operators | **IN PROGRESS** | Install "Red Hat build of OpenTelemetry" operator, verify User Workload Monitoring |
| 3. Deploy TempoStack | **TODO** | Create tempo namespace, deploy TempoStack CR |
| 4. Deploy OTel Collector | **TODO** | Deploy after TempoStack is running |
| 5. Istio resource | **DONE** | Already configured with extensionProviders |
| 6. Telemetry CR | **TODO** | Create combined metrics+tracing Telemetry CR |
| 7. ServiceMonitor/PodMonitor | **TODO** | Apply to all 12 mesh namespaces |
| 8. Kiali CR update | **TODO** | Remove deprecated accessible_namespaces, update tracing URL |
| 9. Verification | **TODO** | After all steps above complete |
| 10. Cleanup | **IN PROGRESS** | Remove Maistra labels if any remain |

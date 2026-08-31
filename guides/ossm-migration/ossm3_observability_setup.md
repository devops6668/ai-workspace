OSSM 3 Observability Setup - Step by Step Guide
=================================================
Based on official Red Hat docs:
https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/migrating_from_service_mesh_2_to_service_mesh_3/index

PREREQUISITE: You must be running OSSM 2.6.14 before migrating to OSSM 3.0.

========================================================================
STEP 1: Disable OSSM 2 Add-ons (Premigration Checklist)
========================================================================

Before installing OSSM 3, disable the add-ons that are embedded in SMCP:

1.1 Edit your existing ServiceMeshControlPlane (SMCP):

apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.6
  security:
    manageNetworkPolicy: false
  addons:
    grafana:
      enabled: false
    kiali:
      enabled: false
    prometheus:
      enabled: false
  meshConfig:
    extensionProviders:
      - name: prometheus
        prometheus: {}
      - name: otel
        opentelemetry:
          port: 4317
          service: otel-collector.istio-system.svc.cluster.local
  gateways:
    enabled: false
    openshiftRoute:
      enabled: false
  mode: MultiTenant
  tracing:
    type: None

Apply:
  oc apply -f <your-smcp-file>

1.2 Verify the SMCP is still healthy:
  oc get smcp -n istio-system
  oc get pods -n istio-system

========================================================================
STEP 2: Install Independent Observability Operators
========================================================================

In OSSM 3, observability is handled by separate operators:

2.1 Install Red Hat OpenShift distributed tracing platform (Tempo) Operator:
  - Go to OperatorHub in OpenShift Console
  - Search for "Red Hat OpenShift distributed tracing platform"
  - Install the operator (it will create a Tempo instance)

2.2 Install Kiali Operator provided by Red Hat:
  - Go to OperatorHub
  - Search for "Kiali Operator provided by Red Hat"
  - Install the operator

2.3 User Workload Monitoring (for Prometheus/Grafana):
  - Ensure User Workload Monitoring is enabled on your cluster
  - This provides the Thanos Querier that Kiali connects to

========================================================================
STEP 3: Deploy Tempo for Distributed Tracing
========================================================================

3.1 Create a Tempo instance:

apiVersion: tempo.simple.cloud/v1alpha1
kind: TempoMonolithic
metadata:
  name: tempo
  namespace: tempo
spec:
  storage:
    secret:
      name: tempo-storage
  storageSize: 10Gi
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi

3.2 Verify Tempo is running:
  oc get pods -n tempo
  oc get tempo -n tempo

========================================================================
STEP 4: Create the Telemetry CR (Istio Resource)
========================================================================

4.1 The Telemetry CR tells Istio to send metrics to Prometheus and traces to OTel:

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

4.2 Apply:
  oc apply -f telemetry.yaml

4.3 This Telemetry CR is referenced in the Istio resource via extensionProviders.

========================================================================
STEP 5: Create the Istio Resource with extensionProviders
========================================================================

5.1 Your Istio resource should include extensionProviders that reference
    Prometheus and OTel:

apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: istio
  namespace: istio-system
spec:
  version: v1.24.3
  values:
    meshConfig:
      extensionProviders:
        - name: prometheus
          prometheus: {}
        - name: otel
          opentelemetry:
            port: 4317
            service: otel-collector.opentelemetrycollector-3.svc.cluster.local
      discoverySelectors:
        - matchLabels:
            mesh: enabled
    global:
      logging:
        level: "default:info"

5.2 Apply:
  oc apply -f istio.yaml

========================================================================
STEP 6: Deploy Kiali with Correct Configuration
========================================================================

6.1 Create the Kiali CR that connects to Thanos Querier (instead of
    Prometheus add-on) and Tempo (instead of Jaeger):

apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: istio-system
spec:
  version: default
  external_services:
    prometheus:
      auth:
        type: bearer
        use_kiali_token: true
      thanos_proxy:
        enabled: true
      url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    tracing:
      enabled: true
      provider: tempo
      use_grpc: false
      internal_url: http://tempo-sample-query-frontend.tempo:3200
      external_url: https://<your-tempo-url>
    grafana:
      enabled: false

6.2 Apply:
  oc apply -f kiali.yaml

6.3 Verify Kiali is running:
  oc get pods -n istio-system -l app=kiali
  oc get route -n istio-system kiali

========================================================================
STEP 7: Configure OTel Collector (for Traces)
========================================================================

7.1 If you don't already have an OTel collector, deploy one:

apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: opentelemetrycollector-3
spec:
  mode: deployment
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
    exporters:
      otlp/tempo:
        endpoint: tempo:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/tempo]

7.2 Apply:
  oc apply -f otel-collector.yaml

========================================================================
STEP 8: Pre-Migration Verification
========================================================================

8.1 Verify all add-ons are disabled in SMCP:
  oc get smcp -n istio-system -o yaml | grep -A5 'addons:'

8.2 Verify Prometheus is accessible via Thanos Querier:
  curl -sk https://thanos-querier.openshift-monitoring.svc.cluster.local:9091/-/healthy

8.3 Verify Tempo is running and accepting traces:
  oc get pods -n tempo

8.4 Verify Kiali can reach Prometheus and Tempo:
  oc exec -it $(oc get pods -n istio-system -l app=kiali -o jsonpath='{.items[0].metadata.name}') -n istio-system -- wget -qO- http://localhost:20001

========================================================================
STEP 9: Complete the Migration
========================================================================

9.1 After installing OSSM 3 Operator and creating the Istio resource:
  - Verify proxies are connecting to the new control plane
  - Check Kiali topology graphs are populated
  - Verify traces appear in Tempo

9.2 Remove OSSM 2 resources (after all workloads are migrated):
  oc delete smcp --all -A
  oc delete smmr --all -A
  oc delete smm --all -A

9.3 Remove OSSM 2 Operator and CRDs:
  oc delete subscription servicemeshoperator -n openshift-operators
  oc get crds -o name | grep ".*\.maistra\.io" | xargs -r -n1 oc delete

========================================================================
KEY CHANGES FROM OSSM 2 to OSSM 3 OBSERVABILITY
========================================================================

| OSSM 2                          | OSSM 3                              |
|---------------------------------|-------------------------------------|
| Prometheus (addon in SMCP)      | Thanos Querier (openshift-monitoring)|
| Grafana (addon in SMCP)         | User workload monitoring (separate) |
| Jaeger (distributed tracing)    | Tempo (distributed tracing platform)|
| Kiali (addon in SMCP)           | Kiali Operator (separate)           |
| Tracing configured in SMCP      | Telemetry CR + Istio extensionProviders |
| service_url for Jaeger          | internal_url for Tempo              |
| deployment.cluster_wide_access  | discoverySelectors (Kiali)          |
| accessible_namespaces           | REMOVED - use discoverySelectors    |
| api.namespaces.include/exclude  | REMOVED - use discoverySelectors    |

========================================================================
TROUBLESHOOTING
========================================================================

If Kiali shows "no data":
  1. Verify Thanos Querier is reachable: curl https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  2. Verify Kiali CR has correct thanos_proxy.url
  3. Check Istio extensionProviders in the Istio resource
  4. Verify Telemetry CR is applied in istio-system

If traces don't appear in Tempo:
  1. Verify OTel collector is running and listening on port 4317
  2. Check Istio extensionProviders references the correct OTel service
  3. Verify Telemetry CR has tracing.providers referencing "otel"
  4. Check OTel collector config exports to the correct Tempo endpoint

If Kiali can't see namespaces:
  1. Verify discoverySelectors in Istio resource match what you expect
  2. Kiali uses discoverySelectors to determine namespace visibility
  3. Remove any deprecated settings (accessible_namespaces, api.namespaces.*)
  4. deployment.cluster_wide_access=true is default (cluster-wide access)

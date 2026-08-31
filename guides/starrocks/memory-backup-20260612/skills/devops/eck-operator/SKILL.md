---
name: eck-operator
description: "Install and manage Elastic Cloud on Kubernetes (ECK) operator — Elasticsearch, Kibana, APM Server, Enterprise Search, Beats, Logstash on Kubernetes. Covers Helm installation, resource creation, networking (Envoy Gateway / Ingress), TLS issues, and troubleshooting."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, kubernetes]
metadata:
  hermes:
    tags: [kubernetes, k3s, elastic, eck, elk, operators, devops]
    related_skills: [k3s-rancher-management, container-vulnerability-scanning]
---

# ECK Operator — Elastic Cloud on Kubernetes

Manage the Elastic Cloud on Kubernetes operator: installation, Elasticsearch clusters, Kibana, APM Server, Enterprise Search, and associated resources.

## Installation

### Via Helm (recommended)

```bash
helm repo add elastic https://helm.elastic.co
helm repo update elastic
helm install eck-operator elastic/eck-operator --version <version> --namespace elastic-system --create-namespace --wait --timeout 5m
```

- Latest version: check `helm search repo elastic/eck-operator --versions`
- Namespace: `elastic-system`
- App version matches chart version (e.g., 3.4.0 → ECK 3.4.0)

### Via YAML

```bash
kubectl apply -f https://download.elastic.co/downloads/eck/3.4.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/3.4.0/operator.yaml
```

## Resource Support (ECK 3.x)

All managed via CRDs in `elastic-system`:

| CRD | Kind | Purpose |
|-----|------|---------|
| `elasticsearches.elasticsearch.k8s.elastic.co` | `Elasticsearch` | Elasticsearch clusters |
| `kibanas.kibana.k8s.elastic.co` | `Kibana` | Kibana dashboards |
| `apmservers.apm.k8s.elastic.co` | `ApmServer` | APM Server (connects to ES + Kibana) |
| `enterprisesearches.enterprisesearch.k8s.elastic.co` | `EnterpriseSearch` | Elastic Enterprise Search |
| `beats.beat.k8s.elastic.co` | `Beat` | Beats (Filebeat, Metricbeat, etc.) |
| `logstashes.logstash.k8s.elastic.co` | `Logstash` | Logstash pipelines |
| `elasticmapsservers.maps.k8s.elastic.co` | `ElasticMapsServer` | Maps Server |
| `agents.agent.k8s.elastic.co` | `Agent` | Elastic Agent (Fleet) |
| `stackconfigpolicies.stackconfigpolicy.k8s.elastic.co` | `StackConfigPolicy` | Shared config for the stack |

## Elasticsearch Deployment

### Minimal 1-node cluster

```yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: elastic-cluster
  namespace: elastic-system
spec:
  version: 8.15.0
  nodeSets:
    - name: default
      count: 1
      config:
        node.store.allow_mmap: false
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources:
                requests:
                  memory: 2Gi
                  cpu: 500m
                limits:
                  memory: 4Gi
                  cpu: "1"
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            storageClassName: <your-storageclass>
            resources:
              requests:
                storage: 10Gi
```

**Key settings:**
- `node.store.allow_mmap: false` — required for k3s (cgroup v2 issue)
- Use `nfs-csi` or other RWO storage class for data durability
- Single-node cluster = **yellow** health (no replicas) is expected
- 3+ nodes = **green** health with replica copies

### Multi-node cluster (3 nodes)

Set `count: 3` in `nodeSets`. Each node gets its own PVC. Minimum memory per node: 2Gi.

## Kibana Deployment

### Minimal config

```yaml
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: kibana
  namespace: elastic-system
spec:
  version: 8.15.0
  count: 1
  elasticsearchRef:
    name: elastic-cluster
    namespace: elastic-system
  config:
    server.ssl.enabled: false   # IMPORTANT when using Envoy Gateway
  podTemplate:
    spec:
      containers:
        - name: kibana
          resources:
            requests:
              memory: 1Gi
              cpu: 250m
            limits:
              memory: 2Gi
              cpu: "1"
```

### HTTPRoute for Envoy Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kibana-route
  namespace: elastic-system
spec:
  parentRefs:
    - name: luban-gateway
      namespace: gateway
  hostnames:
    - "kibana.luban.paulhome.local"
  rules:
    - backendRefs:
        - name: kibana-kb-http
          port: 5601
```

## APM Server Deployment

```yaml
apiVersion: apm.k8s.elastic.co/v1
kind: ApmServer
metadata:
  name: apm-server
  namespace: elastic-system
spec:
  version: 8.15.0
  count: 1
  elasticsearchRef:
    name: elastic-cluster
    namespace: elastic-system
  kibanaRef:
    name: kibana
    namespace: elastic-system
  podTemplate:
    spec:
      containers:
        - name: apm-server
          resources:
            requests:
              memory: 512Mi
              cpu: 250m
            limits:
              memory: 1Gi
              cpu: "1"
```

### OTLP Endpoint for OpenTelemetry Exporters

The APM Server accepts OTLP data on the same HTTPS port (8200). Connect OpenTelemetry exporters as follows:

| Detail | Value |
|--------|-------|
| Service | `apm-server-apm-http.elastic-system.svc:8200` |
| Protocol | HTTPS (ECK auto-provisioned TLS cert) |
| OTLP endpoint (traces) | `https://apm-server-apm-http.elastic-system.svc:8200/v1/traces` |
| OTLP endpoint (metrics) | `https://apm-server-apm-http.elastic-system.svc:8200/v1/metrics` |
| OTLP protocol | `http/protobuf` (recommended for in-cluster) or `grpc` |

**Authentication:** ECK generates a secret token stored in the `apm-server-apm-token` secret:

```bash
kubectl get secret -n elastic-system apm-server-apm-token \
  -o jsonpath='{.data.secret-token}' | base64 -d
```

Pass this as an `Authorization: Bearer <token>` header in OTLP requests. For OpenTelemetry SDKs, set:

```
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>
```

**TLS / CA Certificate:** The APM Server's TLS cert is signed by ECK's internal CA. The CA cert is in the `apm-server-apm-http-certs-public` secret. For in-cluster OTel exporters, either:

- Mount the CA cert and set `OTEL_EXPORTER_OTLP_CERTIFICATE=<path>`
- Or include the APM CA in an existing CA bundle (e.g., `luban-ca-cert`)

**Verify OTLP endpoint with a sample trace (Python):**

Use the bundled verification script (supports single trace and batch mode):

```bash
# Single trace
python3 /root/.hermes/skills/devops/eck-operator/scripts/send-sample-trace.py

# Batch load test: 100 traces across 5 services
python3 /root/.hermes/skills/devops/eck-operator/scripts/send-sample-trace.py \
  --batch 100 --services api-gateway,user-service,order-service,payment-service,notification-service

# Continuous load test: send traces for 15 minutes (900 seconds)
python3 /root/.hermes/skills/devops/eck-operator/scripts/send-sample-trace.py \
  --duration 900 --services api-gateway,user-service,order-service,payment-service,notification-service
```

Check Kibana → **Observability → APM → Services** to see the services.

For external clusters, pass the endpoint and token explicitly:

```bash
python3 send-sample-trace.py \
  --endpoint https://apm.luban.paulhome.local:443 \
  --token $(kubectl get secret -n elastic-system apm-server-apm-token \
             -o jsonpath='{.data.secret-token}' | base64 -d) \
  --ca-bundle /etc/ssl/certs/luban-ca.crt
```

**Verifying traces arrived:**

```bash
# Check Envoy Gateway access logs
kubectl logs -n gateway luban-gateway-<hash> 2>&1 | grep "apm.luban" | grep "/v1/traces" | tail -5

# Check Elasticsearch trace index
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS 'https://localhost:9200/_cat/indices/traces*?v'"
```

**Pitfall: `OTEL_EXPORTER_OTLP_INSECURE=true` does NOT work with the Python HTTP exporter.** The env var is only respected by the gRPC exporter. The HTTP-based OTLPSpanExporter ignores it and uses system CA certs. Always provide a CA bundle via `--ca-bundle` or `OTEL_EXPORTER_OTLP_CERTIFICATE`.

### Verify OTLP endpoint is working (quick curl test)

```bash
# Test with a simple POST (expects 400 for bad protobuf data — that's OK)
kubectl run -n elastic-system curl-test --image=curlimages/curl \
  --restart=Never --rm -it -- /bin/sh -c \
  "curl -sk -X POST -H 'Authorization: Bearer <token>' \
   -H 'Content-Type: application/x-protobuf' \
   'https://apm-server-apm-http.elastic-system.svc:8200/v1/traces' \
   -d 'test' -w '\\\nHTTP_CODE: %{http_code}\\\n'"
# Expected: 400 (failed to unmarshal request body) — means endpoint is alive
```

### Verify traces arrived in Elasticsearch

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

# Check total trace index size
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS 'https://localhost:9200/_cat/indices/traces*?v'"

# Search for a specific service
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS \
  'https://localhost:9200/.ds-traces-apm-default-*/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{\"query\":{\"match\":{\"service.name\":\"trace-verify\"}},\"size\":0}'"

# Count total docs for a test batch
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c \
  "curl -sk -u elastic:\$ES_PASS \
  'https://localhost:9200/.ds-traces-apm-default-*/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{\"query\":{\"terms\":{\"service.name\":[\"api-gateway\",\"user-service\",\"order-service\",\"payment-service\",\"notification-service\"]}},\"size\":0}'"
```

Envoy Gateway access logs also confirm incoming trace traffic:
```bash
kubectl logs -n gateway luban-gateway-<hash> 2>&1 | grep "apm.luban" | grep "/v1/traces" | tail -5
```

### Expose APM Server via Envoy Gateway

Follow the generic BackendTLSPolicy + HTTPRoute pattern (see "Exposing ECK Services via Envoy Gateway" section):

1. Create CA ConfigMap:
```bash
kubectl create configmap -n elastic-system apm-backend-ca \
  --from-file=<(kubectl get secret -n elastic-system apm-server-apm-http-certs-public \
    -o jsonpath='{.data.ca\\.crt}' | base64 -d) --dry-run=client -o yaml | kubectl apply -f -
```

2. Create BackendTLSPolicy (hostname MUST match APM cert SAN: `apm-server-apm-http.elastic-system.svc`):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: apm-backend-tls
  namespace: elastic-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: apm-server-apm-http
  validation:
    hostname: apm-server-apm-http.elastic-system.svc
    caCertificateRefs:
      - name: apm-backend-ca
        group: ""
        kind: ConfigMap
```

3. Create HTTPRoute:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: apm-route
  namespace: elastic-system
spec:
  hostnames:
    - apm.luban.paulhome.local
  parentRefs:
    - name: luban-gateway
      namespace: gateway
  rules:
    - backendRefs:
        - name: apm-server-apm-http
          port: 8200
      matches:
        - path:
            type: PathPrefix
            value: /
```

Default settings (all commented in config):

- `ssl.enabled: false` in the default config, but ECK overrides this by mounting auto-provisioned TLS certs from `/mnt/elastic-internal/http-certs/`
- `auth.secret_token:` — ECK sets this from the generated secret
- The APM server serves HTTPS only — plain HTTP requests get `400 Bad Request: Client sent an HTTP request to an HTTPS server.`

### Fleet-managed APM vs Standalone APM

| Factor | Standalone (ApmServer CRD) | Fleet-managed (Agent + APM integration) |
|--------|---------------------------|----------------------------------------|
| Setup | Simple, one CRD | Complex: Fleet Server + Agent + policy |
| External access | Works out of the box | Fleet API forces `localhost:8200` host |
| TLS | ECK auto-provisioned | TLS disabled by default |
| Config management | Via ECK CRD | Via Fleet/Kibana UI |
| Reliability | High | Lower — depends on Fleet Server connectivity |
| Recommendation | ✅ Use this | ⚠️ Only if you need Fleet's agent management |

**Bottom line:** Prefer standalone ApmServer CRD unless you specifically need Fleet-managed Elastic Agents for other integrations (endpoint security, OSQuery, etc.). The Fleet API's hardcoded `localhost:8200` default for the APM integration host makes it impractical for receiving traces from external sources.

## Networking: TLS to Backend Issue (Critical Pitfall)

**Problem:** ECK Kibana serves HTTPS on port 5601 by default (auto-provisioned TLS certs). When routing through Envoy Gateway or similar ingress that sends plaintext HTTP to backends, you get `503 upstream_reset_before_response_started{connection_termination}`.

**Diagnosis:** 
- Envoy access logs show `response_code: 503`, `response_flags: "UC"`, `response_code_details: "upstream_reset_before_response_started{connection_termination}"`
- `upstream_transport_failure_reason: null` (Envoy disconnected, not a network error)
- Direct curl to the pod IP on port 5601 returns `Empty reply from server` (plain HTTP to HTTPS listener)

**Solution A: Disable Kibana HTTPS (simpler)**
Set `server.ssl.enabled: false` in Kibana's `config` block. The Envoy Gateway terminates TLS at the gateway, and Kibana doesn't need its own TLS.

**Solution B: BackendTLSPolicy (keeps Kibana HTTPS, preferred for security)**
Use `BackendTLSPolicy` (Gateway API v1) to tell Envoy to connect to Kibana via TLS. Steps:

1. Extract Kibana's CA certificate from the ECK auto-provisioned secret:
```bash
kubectl get secret -n elastic-system kibana-kb-http-certs-public \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/kibana-ca.crt
```

2. Create a ConfigMap with the CA cert:
```bash
kubectl create configmap -n elastic-system kibana-backend-ca \
  --from-file=ca.crt=/tmp/kibana-ca.crt --dry-run=client -o yaml | kubectl apply -f -
```

3. Create the BackendTLSPolicy — the `hostname` must match a SAN in the Kibana TLS cert:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: kibana-backend-tls
  namespace: elastic-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: kibana-kb-http
  validation:
    hostname: kibana-kb-http.elastic-system.svc  # MUST match cert SAN
    caCertificateRefs:
      - name: kibana-backend-ca
        group: ""
        kind: ConfigMap
```

4. Verify the policy is accepted:
```bash
kubectl get backendtlspolicy -n elastic-system kibana-backend-tls -o yaml
# Status should show: ResolvedRefs=True, Accepted=True
```

**Important:** The `hostname` field serves as both the SNI for the TLS handshake AND the server name for certificate validation. It MUST match one of the Subject Alternative Names in the Kibana TLS certificate. Check with:
```bash
kubectl get secret -n elastic-system kibana-kb-http-certs-public \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep DNS:
```
Typical SANs: `kibana-kb-http.elastic-system.svc`, `kibana-kb-http.elastic-system.kb.local`, `kibana-kb-http`

## Fleet Server (Elastic Agent) Deployment

Fleet Server manages Elastic Agents. In ECK, it's deployed via the `Agent` CRD with `mode: fleet` and `fleetServerEnabled: true`.

### Minimal Fleet Server

**Prerequisite:** Create the Fleet Server policy in Kibana before the Agent pod can start (see below).

```yaml
apiVersion: agent.k8s.elastic.co/v1alpha1
kind: Agent
metadata:
  name: fleet-server
  namespace: elastic-system
spec:
  version: 8.15.0
  mode: fleet
  fleetServerEnabled: true
  policyID: fleet-server-policy
  elasticsearchRefs:
    - name: elastic-cluster
      namespace: elastic-system
  kibanaRef:
    name: kibana
    namespace: elastic-system
  deployment:
    replicas: 1
    podTemplate:
      spec:
        securityContext:
          fsGroup: 1000   # Required: agent runs as UID 1000
        containers:
          - name: agent
            resources:
              requests:
                cpu: 200m
                memory: 512Mi
              limits:
                cpu: 1
                memory: 1Gi
  http:
    service:
      spec:
        type: ClusterIP
```

### Required: create Fleet Server policy in Kibana

ECK looks for a Fleet Server agent policy named `fleet-server-policy`. It does NOT create this automatically — you must create it via the Fleet API before the Agent pod can start:

```bash
ES_PASS=*** get secret -n elastic-system elastic-cluster-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic-system kibana-kb-<hash> -- bash -c "
  curl -sk -X POST 'https://localhost:5601/api/fleet/agent_policies?sys_monitoring=true' \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -u 'elastic:$ES_PASS' \
    -d '{\"name\":\"Fleet Server policy\",\"description\":\"Default Fleet Server agent policy\",\"namespace\":\"default\",\"monitoring_enabled\":[\"logs\",\"metrics\"],\"is_default_fleet_server\":true,\"has_fleet_server\":true}'
"
```

The created policy has `id: fleet-server-policy`. ECK will find it and proceed with enrollment.

### Fleet Server state directory permissions (critical)

The Fleet Server pod uses a `hostPath` volume at `/var/lib/elastic-agent/<namespace>/<name>/state` for its state. The container runs as UID 1000 (non-root) and cannot create this directory on the host. Before the pod starts:

```bash
sudo mkdir -p /var/lib/elastic-agent/elastic-system/fleet-server/state/data
sudo chown -R 1000:1000 /var/lib/elastic-agent/
```

### Expose Fleet Server via Envoy Gateway

Fleet Server uses TLS on port 8220. Follow the same BackendTLSPolicy + HTTPRoute pattern as other ECK services:

1. Extract the Fleet Server CA cert:
```bash
kubectl create configmap -n elastic-system fleet-backend-ca \
  --from-file=<(kubectl get secret -n elastic-system fleet-server-agent-http-certs-public \
    -o jsonpath='{.data.ca\\.crt}' | base64 -d) --dry-run=client -o yaml | kubectl apply -f -
```

2. Create BackendTLSPolicy (hostname MUST match a SAN in the Fleet Server cert):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: fleet-backend-tls
  namespace: elastic-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: fleet-server-agent-http
  validation:
    hostname: fleet-server-agent-http.elastic-system.svc
    caCertificateRefs:
      - name: fleet-backend-ca
        group: ""
        kind: ConfigMap
```

3. Create HTTPRoute:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fleet-route
  namespace: elastic-system
spec:
  hostnames:
    - fleet.luban.paulhome.local
  parentRefs:
    - name: luban-gateway
      namespace: gateway
  rules:
    - backendRefs:
        - name: fleet-server-agent-http
          port: 8220
      matches:
        - path:
            type: PathPrefix
            value: /
```

Verify:
```bash
curl -sk --resolve 'fleet.luban.paulhome.local:443:192.168.48.111' \
  https://fleet.luban.paulhome.local/api/status
# Expected: {"name":"fleet-server","status":"HEALTHY"}
```

### Fleet Server Troubleshooting

#### "Failed to decrypt attribute 'passphrase'" — corrupted Fleet signing keys

**Symptom:** Kibana logs show repeated `Failed to decrypt attribute "passphrase" of saved object "fleet-message-signing-keys,..."`. The ECK operator shows `ECK cannot setup Fleet enrollment`.

**Cause:** The Fleet message signing keys are stored in Elasticsearch as an encrypted saved object (in `.kibana_ingest_*` index). When Kibana restarts with a different encryption key (e.g., pod was recreated), the saved object can't be decrypted.

**Fix — delete the corrupted saved object using Kibana's service account:**

```bash
# 1. Delete the Fleet Server Agent
kubectl delete agent -n elastic-system fleet-server

# 2. Get the Kibana service account token
KB_TOKEN=*** get secret -n elastic-system kibana-kibana-user -o jsonpath='{.data.token}' | base64 -d)

# 3. Delete the corrupted document from Elasticsearch
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -H 'Authorization: Bearer $KB_TOKEN' \
  -X DELETE 'https://localhost:9200/.kibana_ingest_*/_doc/fleet-message-signing-keys:<key-id>'
"

# 4. Find the document id first if needed:
kubectl exec -n elastic-system elastic-cluster-es-default-0 -- bash -c "
  curl -sk -H 'Authorization: Bearer $KB_TOKEN' \
  'https://localhost:9200/.kibana_ingest_*/_search?q=fleet-message-signing-keys&pretty'
"

# 5. Recreate the Fleet Server Agent + Fleet Server policy (see sections above)
```

**Important:** The direct ES API approach requires the Kibana service account token (not the `elastic` superuser), because `.kibana_ingest_*` indices reject writes even from the superuser.

#### Fleet Server wrong namespace registration (critical bug)

**Symptom:** Fleet Server registers in Kibana with `fleet-server-agent-http.elastic.svc.cluster.local` instead of `fleet-server-agent-http.elastic-system.svc.cluster.local`. All Fleet-managed agents fail with `DNS lookup failure` or `x509: certificate is valid for` errors.

**Impact:** Any Agent with `mode: fleet` and `fleetServerRef` cannot receive policy updates. APM and other Fleet-managed integrations inside the agent won't start.

**Workaround:** See `references/fleet-server-namespace-bug.md` for the CoreDNS hosts + `FLEET_INSECURE=true` workaround.

#### Agent pod "CrashLoopBackOff" — state directory permission denied

**Symptom:** Pod log shows `Error: preparing STATE_PATH(/usr/share/elastic-agent/state) failed: mkdir /usr/share/elastic-agent/state/data: permission denied`

**Cause:** The container runs as UID 1000 but the hostPath directory on the node is owned by root.

**Fix:** Pre-create the hostPath directory on the node with correct ownership before the pod starts:

```bash
sudo mkdir -p /var/lib/elastic-agent/elastic-system/fleet-server/state/data
sudo chown -R 1000:1000 /var/lib/elastic-agent/
```

Then delete the pod so the deployment recreates it:
```bash
kubectl delete pod -n elastic-system -l agent.k8s.elastic.co/name=fleet-server
```

## Exposing ECK Services via Envoy Gateway (Generic Pattern)

All ECK services (Kibana, APM Server, Fleet Server) serve **HTTPS** on their ports using ECK auto-provisioned TLS certificates. To expose them through Envoy Gateway, you need:

1. **BackendTLSPolicy** — tells Envoy to connect via TLS, not plain HTTP
2. **HTTPRoute** — maps a hostname to the ClusterIP service

### Step 1: Find TLS certificate SANs

```bash
kubectl get secret -n elastic-system <service>-http-certs-public \
  -o jsonpath='{.data.tls\\.crt}' | base64 -d | openssl x509 -text -noout | grep DNS:
```

Use one of the returned DNS names (e.g., `<service>.<namespace>.svc`) as the `validation.hostname` in the BackendTLSPolicy.

### Step 2: Create CA ConfigMap

```bash
kubectl create configmap -n elastic-system <name>-backend-ca \
  --from-file=<(kubectl get secret -n elastic-system <service>-http-certs-public \
    -o jsonpath='{.data.ca\\.crt}' | base64 -d) --dry-run=client -o yaml | kubectl apply -f -
```

### Step 3: Create the resources

```yaml
# BackendTLSPolicy
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: <name>-backend-tls
  namespace: elastic-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: <service-name>
  validation:
    hostname: <service>.<namespace>.svc  # MUST match cert SAN
    caCertificateRefs:
      - name: <name>-backend-ca
        group: ""
        kind: ConfigMap
---
# HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <name>-route
  namespace: elastic-system
spec:
  hostnames:
    - <name>.luban.paulhome.local
  parentRefs:
    - name: luban-gateway
      namespace: gateway
  rules:
    - backendRefs:
        - name: <service-name>
          port: <port>
      matches:
        - path:
            type: PathPrefix
            value: /
```

### Step 4: Verify

```bash
# Check both resources are Accepted by the gateway
kubectl get backendtlspolicy -n elastic-system <name>-backend-tls -o jsonpath='{.status.ancestors[0].conditions[0].reason}'
kubectl get httproute -n elastic-system <name>-route -o jsonpath='{.status.parents[0].conditions[0].reason}'
# Both should output: Accepted

# Test the endpoint (use --resolve if DNS doesn't resolve the .local domain)
curl -sk --resolve '<name>.luban.paulhome.local:443:<NODE_IP>' \
  https://<name>.luban.paulhome.local/<path>
```

## Envoy Gateway Integration Notes

### Gateway must be running
The Envoy Gateway deployment (`envoy-gateway` in `envoy-gateway-system`) and its proxy (`luban-gateway` in `gateway`) can be scaled to 0 during maintenance. New HTTPRoutes won't be picked up until scaled back up.

**Check:** `kubectl get deploy -n envoy-gateway-system envoy-gateway` and `kubectl get deploy -n gateway luban-gateway`

**Scale up:**
```bash
kubectl scale deployment envoy-gateway -n envoy-gateway-system --replicas=1
kubectl scale deployment luban-gateway -n gateway --replicas=1
```

### Endpoint cache staleness
Envoy caches service endpoints. When Kibana/Elasticsearch pods rotate, Envoy may try old pod IPs (visible in access logs as stale IPs). This is transient — Envoy reconciles on the next request cycle. Check access logs for `upstream_host` IPs to verify.

### Checking route reconciliation
```bash
kubectl get httproute <name> -n <ns> -o yaml | grep -A 20 status:
# Should show: Accepted=True, ResolvedRefs=True
# If BackendsAvailable not shown, check endpoint readiness
```

### Envoy access log format
Access logs use JSON per line. Key fields for debugging:
- `response_code` — 503 = upstream connection failure
- `response_code_details` — `upstream_reset_before_response_started{connection_termination}` = TLS mismatch or wrong IP
- `upstream_host` — the pod IP Envoy connected to
- `upstream_transport_failure_reason` — empty means Envoy disconnected; populated means network error

## Troubleshooting

### Kibana readiness probe fails: "HTTP response to HTTPS client"
**Symptom:** Pod shows `0/1 Running`, events repeatedly show `http: server gave HTTP response to HTTPS client`.\n**Cause:** ECK defaults the readiness probe to `scheme: HTTPS`. If `server.ssl.enabled: false` in Kibana config, Kibana serves HTTP but probe expects HTTPS.\n**Fix A (preferred):** Patch `server.ssl.enabled` back to `true` on the existing Kibana CR:\n```bash\nkubectl patch kibana <name> -n elastic-system --type merge -p '{\n  "spec": {\n    "config": {"server.ssl.enabled": "true"},\n    "http": {"tls": {"certificate": {}}}\n  }\n}'\n```\nECK will reconcile: create a new pod, configure the auto-provisioned TLS cert (`kibana-kb-http-certs-internal`), update the readiness probe scheme to HTTPS, and roll it out. No delete/recreate needed.\n\n**Fix B:** If patch doesn't roll out, delete + recreate the Kibana CR:\n```bash\nkubectl delete kibana <name> -n elastic-system\nkubectl apply -f kibana-ssl-enabled.yaml  # config: server.ssl.enabled: true\n```\n\n**Pitfall:** `spec.http.tls.enabled` is NOT a valid field on the Kibana CR — it produces a warning `"unknown field"` and is ignored. Use `spec.config.server.ssl.enabled` instead.

### Kibana shows "red" health
- Check pod readiness: `kubectl get pods -n elastic-system -l app.kubernetes.io/managed-by=kibana`
- Readiness probe may fail during rolling update — wait for new pod
- Check Kibana config: `kubectl exec <kibana-pod> -n elastic-system -- cat /usr/share/kibana/config/kibana.yml`
- Verify Elasticsearch connection: Kibana needs to reach `https://<es-service>:9200` with CA cert

### Elasticsearch stuck in "ApplyingChanges"
- Check PVC binding: `kubectl get pvc -n elastic-system`
- Check pod logs: `kubectl logs -n elastic-system <es-pod>`
- Image pull can take time (~1GB image)
- Init containers (filesystem init, suspend) add delay

### APM Server failing to connect
- Ensure Elasticsearch is Ready (not just Running)
- APM Server needs Kibana ref AND Elasticsearch ref
- Check logs: `kubectl logs -n elastic-system <apm-pod>`

## Managing APM Data Stream Retention

APM data streams (metrics, traces) use **data stream lifecycle** (DSL) configured
via component templates — not legacy ILM policies.

Built-in lifecycle templates: `apm-90d@lifecycle` (1m metrics), `apm-180d@lifecycle`
(10m metrics), `apm-390d@lifecycle` (60m metrics). To change retention, you:

1. Create a custom component template with your desired `lifecycle.data_retention`
2. Update the index template's `composed_of` to reference it instead of the built-in
3. Apply the lifecycle directly to the existing data stream via `PUT /_data_stream/<name>/_lifecycle`

See `references/data-stream-lifecycle.md` for detailed commands, index template
names, and pitfall notes.

### Getting Elasticsearch user password
```bash
kubectl get secret elastic-cluster-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d
```

### Checking overall ECK status
```bash
kubectl get elasticsearch -n elastic-system
kubectl get kibana -n elastic-system
kubectl get apmserver -n elastic-system
```

## Pitfalls

- **`node.store.allow_mmap: false` is required on k3s** — cgroup v2 prevents Elasticsearch from using mmapfs, causing startup failure
- **1-node clusters = yellow health** — this is normal, not a failure. Green requires replicas (3+ nodes)
- **ECK Kibana enables HTTPS on 5601 by default** — conflicts with Envoy Gateway (sends plaintext). Fix with either (a) `server.ssl.enabled: false` or (b) a `BackendTLSPolicy` to keep HTTPS end-to-end (see "Networking: TLS to Backend Issue" section)
- **Envoy Gateway deployments can be scaled to 0** — new HTTPRoutes silently fail if the gateway controller/proxy aren't running
- **Endpoints can show stale pod IPs** in Envoy — access logs will show old IPs during pod rotation
- **Kibana readiness probe may lag during rolling updates** — the new pod's config takes effect after init, readiness goes 0→1
- **Elasticsearch image is ~1GB** — initial pull takes time, don't mistake it for a hang
- **ECK 3.x API changes from 2.x** — some config fields changed (e.g., `elasticsearchRef` format)
- **Check `--previous` pod logs** when debugging — the current pod might look healthy while all prior restarts had errors
- **`OTEL_EXPORTER_OTLP_INSECURE=true` only works with gRPC exporter** — the Python HTTP/protobuf exporter ignores this env var. Always provide a CA certificate via `OTEL_EXPORTER_OTLP_CERTIFICATE` or mount a bundle
- **ArgoCD application-controller must be running for app refresh/sync** — if the StatefulSet is scaled to 0, refresh operations silently fail. Check `kubectl get sts -n argocd | grep application-controller`
- **Code location pods may not have OTel SDK** — Dagster platform pods bundle opentelemetry as a dependency, but code location images may not. Setting env vars is forward-looking; test with `/layers/luban-ci_python-uv/venv/bin/python`

## References

- `references/fleet-server-namespace-bug.md` — Fleet Server wrong namespace registration bug and workarounds
- `references/fleet-server-setup.md` — Fleet Server deployment details
- `references/envoy-gateway-tls-backend.md` — Detailed Envoy Gateway TLS-to-backend integration guide
- `references/kibana-probe-http-mismatch.md` — Kibana readiness probe HTTP vs HTTPS mismatch diagnosis
- `references/luban-ci-opentelemetry-integration.md` — Luban CI → Elastic APM OTel pipeline setup
- `references/data-stream-lifecycle.md` — Changing APM data stream retention (7d/90d/etc.)
- ECK docs: https://www.elastic.co/guide/en/cloud-on-k8s/current/

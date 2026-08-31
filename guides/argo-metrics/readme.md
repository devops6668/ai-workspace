# Argo Workflows Metrics — Step-by-Step Setup Guide
## OpenTelemetry → Elasticsearch → Kibana Dashboard

---

## 1. 部署 OpenTelemetry Collector

在 `elastic-system` namespace 部署 OTel Collector，接收 Argo Controller 的 OTLP metrics/traces/logs，寫入 Elasticsearch。

### 1a. 建立 ES 憑證 Secret

```bash
kubectl create secret generic otel-es-credentials -n elastic-system \
  --from-literal=es-username=elastic \
  --from-literal=es-password=<PASSWORD>
```

> `<PASSWORD>` 改為 ES `elastic` 用戶的密碼。

### 1b. 建立 CA 證書 Secret

ES 使用 self-signed certificate，需建立 CA 證書 Secret：

```bash
kubectl create secret generic es-luban-ca -n elastic-system \
  --from-file=ca.crt=es-luban-ca.crt
```

> 將 `es-luban-ca.crt` 替換為實際的 CA 證書檔案路徑。

### 1c. 部署 OTel Collector

**`otel-collector.yaml`：**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: otel-es-credentials
  namespace: elastic-system
type: Opaque
stringData:
  es-username: elastic
  es-password: <PASSWORD>
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: elastic-system
data:
  otel-collector-config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 1000

    exporters:
      elasticsearch:
        endpoints:
          - "https://${env:ES_USERNAME}:${env:ES_PASSWORD}@elastic-cluster-es-http.elastic-system.svc:9200"
        tls:
          insecure: false
          ca_file: /etc/otel/tls/ca.crt

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679
      pprof:
        endpoint: 0.0.0.0:1777

    service:
      extensions: [health_check, zpages, pprof]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [elasticsearch]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [elasticsearch]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [elasticsearch]
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: elastic-system
  labels:
    app: otel-collector
spec:
  selector:
    app: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: metrics
      port: 8888
      targetPort: 8888
    - name: healthcheck
      port: 13133
      targetPort: 13133
    - name: zpages
      port: 55679
      targetPort: 55679
    - name: pprof
      port: 1777
      targetPort: 1777
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: elastic-system
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.119.0
          args:
            - "--config=/conf/otel-collector-config.yaml"
          env:
            - name: ES_USERNAME
              valueFrom:
                secretKeyRef:
                  name: otel-es-credentials
                  key: es-username
            - name: ES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: otel-es-credentials
                  key: es-password
          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
            - containerPort: 8888
              name: metrics
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /conf
            - name: es-ca
              mountPath: /etc/otel/tls
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
        - name: es-ca
          secret:
            secretName: es-luban-ca
```

> 注意：`<PASSWORD>` 改為 ES `elastic` 用戶的密碼。
> CA 證書來自 `es-luban-ca` Secret。

```bash
kubectl apply -f otel-collector.yaml
```

### 1d. 驗證 Collector 狀態

```bash
# 檢查 Pod
kubectl get pods -n elastic-system -l app=otel-collector

# 健康檢查
kubectl exec -n elastic-system <POD> -- wget -qO- http://localhost:13133/health

# 確認所有端點
curl -sk https://otel.luban.paulhome.local/health
# 預期回應: {"status":"Server available","upSince":"...","uptime":"..."}
```

---

## 2. 透過 Gateway API 暴露 OTel Collector

使用 Gateway API + cert-manager 將 OTel Collector 暴露為 HTTPS endpoint，供外部集群（如 Argo）使用。

### 架構

```
Argo (remote cluster)
  → OTLP gRPC → https://otel.luban.paulhome.local:443
    → Gateway (TLS termination)
      → GRPCRoute → otel-collector:4317 (gRPC)
      → HTTPRoute → otel-collector:4318 (HTTP)
```

### 2a. 建立 TLS Certificate（cert-manager）

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: otel-luban-paulhome-tls
  namespace: envoy-gateway-system
spec:
  secretName: otel-luban-paulhome-tls
  issuerRef:
    name: selfsigned-cluster-issuer
    kind: ClusterIssuer
  commonName: otel.luban.paulhome.local
  dnsNames:
    - otel.luban.paulhome.local
  duration: 2160h
  renewBefore: 720h
```

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: otel-luban-paulhome-tls
  namespace: envoy-gateway-system
spec:
  secretName: otel-luban-paulhome-tls
  issuerRef:
    name: selfsigned-cluster-issuer
    kind: ClusterIssuer
  commonName: otel.luban.paulhome.local
  dnsNames:
    - otel.luban.paulhome.local
  duration: 2160h
  renewBefore: 720h
EOF
```

確認 Certificate Ready：

```bash
kubectl get certificate -n envoy-gateway-system otel-luban-paulhome-tls
# 預期: READY=True
```

### 2b. 在 Gateway 加入 HTTPS Listener

為 `my-shared-gateway` 加入 `https-otel` listener：

```bash
kubectl -n envoy-gateway-system patch gateway my-shared-gateway --type json \
  -p='[{"op":"add","path":"/spec/listeners/-","value":{"allowedRoutes":{"namespaces":{"from":"All"}},"hostname":"otel.luban.paulhome.local","name":"https-otel","port":443,"protocol":"HTTPS","tls":{"certificateRefs":[{"name":"otel-luban-paulhome-tls"}],"mode":"Terminate"}}}]'
```

### 2c. 建立 HTTPRoute（OTLP HTTP + 健康檢查）

> **重要**：不要使用 catch-all `PathPrefix: /` 規則！catch-all 會攔截 gRPC 流量，
> 導致 gRPC client 收到 HTTP/JSON 回應而報錯。每個路徑必須明確指定。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: otel-collector-route
  namespace: elastic-system
spec:
  hostnames:
    - otel.luban.paulhome.local
  parentRefs:
    - name: my-shared-gateway
      namespace: envoy-gateway-system
      sectionName: https-otel
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/traces
      backendRefs:
        - name: otel-collector
          port: 4318
    - matches:
        - path:
            type: PathPrefix
            value: /v1/metrics
      backendRefs:
        - name: otel-collector
          port: 4318
    - matches:
        - path:
            type: PathPrefix
            value: /v1/logs
      backendRefs:
        - name: otel-collector
          port: 4318
    - matches:
        - path:
            type: PathPrefix
            value: /debug/pprof
      backendRefs:
        - name: otel-collector
          port: 1777
    - matches:
        - path:
            type: Exact
            value: /health
      backendRefs:
        - name: otel-collector
          port: 13133
    - matches:
        - path:
            type: Exact
            value: /ready
      backendRefs:
        - name: otel-collector
          port: 13133
    - matches:
        - path:
            type: Exact
            value: /
      backendRefs:
        - name: otel-collector
          port: 13133
```

### 2d. 建立 GRPCRoute（OTLP gRPC）

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: otel-collector-grpc-route
  namespace: elastic-system
spec:
  hostnames:
    - otel.luban.paulhome.local
  parentRefs:
    - name: my-shared-gateway
      namespace: envoy-gateway-system
      sectionName: https-otel
  rules:
    - backendRefs:
        - name: otel-collector
          port: 4317
```

### 2e. 驗證 Gateway API 資源

```bash
# HTTPRoute 狀態
kubectl get httproute otel-collector-route -n elastic-system
# 預期: HOSTNAMES=["otel.luban.paulhome.local"]

# GRPCRoute 狀態
kubectl get grpcroute otel-collector-grpc-route -n elastic-system
# 預期: HOSTNAMES=["otel.luban.paulhome.local"]

# Gateway listener 狀態
kubectl get gateway my-shared-gateway -n envoy-gateway-system \
  -o jsonpath='{range .status.listeners[*]}{.name}: {range .conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' | grep otel
# 預期: https-otel: Programmed=True Accepted=True ResolvedRefs=True

# 測試所有端點
curl -sk https://otel.luban.paulhome.local/health
curl -sk https://otel.luban.paulhome.local/ready
curl -sk -X POST -H "Content-Type: application/json" https://otel.luban.paulhome.local/v1/metrics
```

### 已知陷阱

| 問題 | 原因 | 解決方案 |
|------|------|----------|
| `received unexpected content-type "application/json"` | HTTPRoute catch-all `/` 拦截了 gRPC 流量 | 移除 catch-all，改用明確路徑匹配 |
| gRPC 請求返回 405 | 請求被 HTTPRoute 路由到 HTTP 端口 | 確認 GRPCRoute 已建立且被 Gateway 接受 |
| Certificate 未 Ready | cert-manager issuer 不存在 | 確認 `selfsigned-cluster-issuer` ClusterIssuer 存在 |
| Gateway listener 未接受 | 證書 Secret 未建立 | 等待 cert-manager 完成證書簽發 |

---

## 3. 配置 Argo Controller 發送 OTLP Metrics

### 方式 A：內部集群（同集群）

直接使用 ClusterIP Service：

```bash
kubectl set env deployment/workflow-controller -n argo \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.elastic-system.svc:4317 \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  OTEL_SERVICE_NAME=workflows-controller \
  OTEL_RESOURCE_ATTRIBUTES=service.name=workflows-controller

kubectl set env deployment/argo-server -n argo \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.elastic-system.svc:4317 \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  OTEL_SERVICE_NAME=argo-server \
  OTEL_RESOURCE_ATTRIBUTES=service.name=argo-server
```

### 方式 B：外部集群（跨集群）

使用 Gateway API HTTPS endpoint：

```bash
kubectl set env deployment/workflow-controller -n argo \
  OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.luban.paulhome.local:443 \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  OTEL_SERVICE_NAME=workflows-controller \
  OTEL_RESOURCE_ATTRIBUTES=service.name=workflows-controller

kubectl set env deployment/argo-server -n argo \
  OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.luban.paulhome.local:443 \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  OTEL_SERVICE_NAME=argo-server \
  OTEL_RESOURCE_ATTRIBUTES=service.name=argo-server
```

> **注意**：使用外部 endpoint 時，Argo Pod 需要能解析 `otel.luban.paulhome.local`。
> 如果是跨集群，需確保 DNS 或 `/etc/hosts` 設定正確。

確認 rollout：

```bash
kubectl rollout status deployment/workflow-controller -n argo
kubectl rollout status deployment/argo-server -n argo
```

---

## 4. 啟用 Argo Controller Prometheus Metrics

Argo controller 默認會暴露 Prometheus metrics 在 port 9090 (`/metrics`)。如果自訂過 configmap，可以確認以下設定：

```bash
kubectl patch configmap workflow-controller-configmap -n argo --type=merge -p '{
  "data": {
    "config": "metricsConfig:\n  enabled: true\n  port: 9090\n  path: /metrics\n"
  }
}'
```

---

## 5. 驗證 Metrics 流入 ES

等待 1–2 分鐘讓數據流動：

```bash
# 確認有新的 generic metrics index
kubectl exec curl-pod -- curl -sk \
  -u "elastic:<PASSWORD>" \
  "https://es.luban.paulhome.local/_cat/indices" | grep generic

# 檢查數據內容
kubectl exec curl-pod -- curl -sk \
  -u "elastic:<PASSWORD>" \
  "https://es.luban.paulhome.local/.ds-metrics-generic-default*/_search?size=3"
```

> `<PASSWORD>` 改為 ES `elastic` 用戶的密碼。

---

## 6. 在 Kibana 建立 Data Views（Index Patterns）

Dashboard panels 透過 `searchSourceJSON` 的 `"index"` 欄位引用 data view ID，必須先建立對應的 data views，否則面板會顯示 "Could not find the data view"。

### 6a. OTel Metrics Data View

```bash
curl -sk -X POST "https://kibana.luban.paulhome.local/api/data_views/data_view" \
  -u "elastic:$(kubectl get secret elastic-cluster-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  -d '{
    "data_view": {
      "id": "ds-metrics-generic-default",
      "title": ".ds-metrics-generic-default*",
      "name": "Argo OTel Metrics",
      "timeFieldName": "@timestamp"
    }
  }'
```

### 6b. Workflow Durations Data View

```bash
curl -sk -X POST "https://kibana.luban.paulhome.local/api/data_views/data_view" \
  -u "elastic:$(kubectl get secret elastic-cluster-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  -d '{
    "data_view": {
      "id": "argo-workflow-durations",
      "title": "argo-workflow-durations*",
      "name": "Argo Workflow Durations",
      "timeFieldName": "@timestamp"
    }
  }'
```

> **重要**：`id` 欄位必須與 NDJSON 匯入的 dashboard panels 中 `searchSourceJSON` 的 `"index"` 值完全一致。如果 ID 不匹配，面板會顯示 "Could not find the data view"。

---

## 7. 建立 Visualizations 和 Dashboard

使用 Saved Objects API 依次建立：

1. **Saved Search** — `argo_metrics_search`（filter `service.name: workflows-controller`）
2. **7 個 Controller Visualizations**：
   - `argo_phase_trend` — Workflow Phase Trend（line, max of gauge by phase）
   - `argo_namespaces` — Workflows by Namespace（pie, count by kubernetes.namespace）
   - `argo_k8s_api` — K8s API Requests（pie, sum of k8s_request_total by kind）
   - `argo_queue_depth` — Queue Depth（line, avg of queue_depth_gauge by queue）
   - `argo_errors` — Error Count（metric, sum of error_count）
   - `argo_workers` — Workers Busy（line, avg of workers_busy_count）
   - `argo_error_causes` — Error Causes（table, sum of error_count by cause）
3. **Dashboard** — `argo-workflows-overview`（16 panels, time range now-24h）

API 調用範例（每個 visualization 一個 POST）：

```bash
curl -sk -X POST "https://kibana.luban.paulhome.local/api/saved_objects/visualization/argo_phase_trend" \
  -u "elastic:$(kubectl get secret elastic-cluster-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  -d '{
    "attributes": {
      "title": "Workflow Phase Trend",
      "visState": "{\"title\":\"Workflow Phase Trend\",\"type\":\"line\",\"aggs\":[{\"id\":\"1\",\"type\":\"max\",\"schema\":\"metric\",\"params\":{\"field\":\"gauge\",\"customLabel\":\"Workflow Count\"}},{\"id\":\"2\",\"type\":\"date_histogram\",\"schema\":\"segment\",\"params\":{\"field\":\"@timestamp\",\"interval\":\"auto\",\"min_doc_count\":1}},{\"id\":\"3\",\"type\":\"terms\",\"schema\":\"group\",\"params\":{\"field\":\"phase\",\"size\":10,\"order\":\"desc\",\"orderBy\":\"1\"}}]}",
      "uiStateJSON": "{}",
      "kibanaSavedObjectMeta": {
        "searchSourceJSON": "{\"index\":\"ds-metrics-generic-default\",\"query\":{\"bool\":{\"must\":[{\"term\":{\"service.name\":\"workflows-controller\"}}]}}}"
      }
    }
  }'
```

Dashboard panelsJSON 需使用 Kibana 8.x 格式（`gridData` 非 `gridPosition`）。

---

## 8. 建立 Workflow Duration 收集 (CronJob)

### 8a. 設定 RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-duration-sa
  namespace: argo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-duration-reader
rules:
- apiGroups: ["argoproj.io"]
  resources: ["workflows"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-duration-reader-binding
subjects:
- kind: ServiceAccount
  name: argo-duration-sa
  namespace: argo
roleRef:
  kind: ClusterRole
  name: argo-duration-reader
  apiGroup: rbac.authorization.k8s.io
```

### 8b. 建立 ES 憑證 Secret

```bash
kubectl create secret generic es-credentials -n argo \
  --from-literal=ES_USER=elastic \
  --from-literal=ES_PASS=<PASSWORD>
```

### 8c. 建立 Python Script 作為 ConfigMap

Script 邏輯：
- 通過 K8s API 獲取所有 namespace 的 Workflow CRD
- 提取 `status.startedAt` / `finishedAt` 計算 duration
- 推送到 ES index `argo-workflow-durations`
- GC：每個 template 只保留最近 10 筆

```bash
kubectl create configmap argo-duration-script -n argo --from-file=main.py=collector.py
```

### 8d. 建立 CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: argo-workflow-durations
  namespace: argo
spec:
  schedule: "*/3 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: argo-duration-sa
          containers:
          - name: collector
            image: python:3.12-alpine
            command:
            - /bin/sh
            - -c
            - |
              apk add --no-cache curl >/dev/null 2>&1
              python3 /scripts/main.py
            envFrom:
            - secretRef:
                name: es-credentials
            env:
            - name: ES_URL
              value: https://es.luban.paulhome.local
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
          restartPolicy: Never
          volumes:
          - name: script
            configMap:
              name: argo-duration-script
              defaultMode: 0555
```

### 8e. 在 Kibana 建立 Duration Data View

```bash
curl -sk -X POST "https://kibana.luban.paulhome.local/api/data_views/data_view" \
  -u "elastic:$(kubectl get secret elastic-cluster-es-elastic-user -n elastic-system -o jsonpath='{.data.elastic}' | base64 -d)" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  -d '{
    "data_view": {
      "id": "argo-workflow-durations",
      "title": "argo-workflow-durations*",
      "name": "Argo Workflow Durations",
      "timeFieldName": "@timestamp"
    }
  }'
```

> 如果 Step 6b 已建立此 data view，可跳過此步驟。

### 8f. 建立 Duration Visualizations

5 個 visualizations（共用 index: `argo-workflow-durations`）：

| ID | 類型 | 用途 |
|----|------|------|
| `argo_duration_latest` | metric | 最新一次 workflow duration |
| `argo_duration_trend` | line | 各 template 的 duration 趨勢 |
| `argo_duration_by_tmpl` | histogram | 每個 template 平均 duration |
| `argo_ns_duration` | table | 每個 NS + app label 的最新 duration |
| `argo_duration_runs_line` | line | 各 workflow 的 duration 時間序列 |

---

## 9. 最終 Dashboard Layout

16 個 panels：

```
Row 0: [Workflow Phase Trend                                    ]  全闊 line
Row 1: [By NS] [K8s API] [Queue Depth] [Errors]
Row 2: [API by NS] [Workers Busy] [Error Causes]
Row 3: [Leader] [Latest Controller Logs                          ]
Row 4: [Duration by App Over Time                                ]  全闊 line
Row 5: [Latest Dur] [Workflow Duration Over Time                 ]
Row 6: [Duration Tmpl] [Duration NS(app)] [Latest Runs Line]
```

---

## 10. 端點總覽

| 端點 | 端口 | 協議 | 用途 |
|------|------|------|------|
| `/v1/traces` | 4318 | HTTP | OTLP HTTP traces receiver |
| `/v1/metrics` | 4318 | HTTP | OTLP HTTP metrics receiver |
| `/v1/logs` | 4318 | HTTP | OTLP HTTP logs receiver |
| gRPC (所有 service) | 4317 | gRPC | OTLP gRPC receiver |
| `/health` | 13133 | HTTP | 健康檢查 |
| `/ready` | 13133 | HTTP | 就緒檢查 |
| `/debug/pprof` | 1777 | HTTP | 效能分析 |

---

## 11. 已知限制

- **Histogram metrics 被 drop**：OTel ES exporter 0.119.0 不支持 cumulative temporality histogram，`operation_duration_seconds`、`k8s_request_duration` 等 metrics 不會寫入 ES。如果需要，可改用 Prometheus remote write 或在 OTel pipeline 加入 `cumulativetodelta` processor（需 upgrade 到 0.121.0+，但 0.121.0 有 mapping 問題）。
- **CronJob 不支援 kubectl**：使用 K8s API 直接查 workflow，不需 kubectl binary。
- **Dashboard 時間範圍**：設為 `now-24h`，可手動在 Kibana 調整。
- **Gateway API GRPCRoute**：需確認 GatewayClass 支持 gRPC（Cilium `cilium` 或 Envoy Gateway `eg` 均支持）。

---

*Updated by Hermes Agent — 2026-07-23*

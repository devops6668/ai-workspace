# Argo Workflows → OTLP → Remote OTel Collector Setup Plan

## Overview

Send Argo Workflows metrics from k3s-luban (192.168.48.111) to remote OTel Collector at otel.luban.paulhome.local (192.168.89.61) via OTLP gRPC over HTTPS.

```
k3s-luban (192.168.48.111)              Remote k3s (192.168.89.61)
┌─────────────────────────┐             ┌──────────────────────────┐
│ argo namespace          │             │ otel.luban.paulhome.local│
│ ┌─────────────────────┐ │   OTLP gRPC │ ┌──────────────────────┐ │
│ │workflow-controller  │─┼─────────────┼─│OTel Collector        │ │
│ │  OTEL env vars      │ │  :443 HTTPS │ │  (already running)   │ │
│ └─────────────────────┘ │             │ └──────────┬───────────┘ │
│ ┌─────────────────────┐ │             │            │              │
│ │argo-server          │─┼─────────────┼─│            ▼              │
│ │  OTEL env vars      │ │             │      Elasticsearch         │
│ └─────────────────────┘ │             └──────────────────────────┘
└─────────────────────────┘
```

## Prerequisites

- [x] Remote OTel Collector running and accepting OTLP traffic
- [x] CA certificate for TLS verification (k3s-ca-cert.pem)
- [x] Argo Workflows v4.0.5 deployed on k3s-luban
- [x] DNS: otel.luban.paulhome.local resolves to 192.168.89.61

## CA Certificate Verification

```
Subject: CN = k3s-ca-cert
Issuer:  CN = k3s-ca-cert (self-signed)

Remote collector cert chain:
  depth=1: CN = k3s-ca-cert (CA)
  depth=0: CN = otel.luban.paulhome.local (leaf)

Verification: openssl verify -CAfile k3s-ca-cert.pem → OK
```

---

## Step 1: Create ConfigMap with CA cert

**Namespace:** argo
**Name:** otel-ca-cert
**Data:** ca.crt (k3s-ca-cert.pem)

```bash
kubectl create configmap otel-ca-cert -n argo \
  --from-file=ca.crt=/tmp/k3s-ca-cert.pem
```

---

## Step 2: Patch workflow-controller deployment

**Add to container[0]:**

### Env vars (append to existing)

| Name | Value |
|------|-------|
| OTEL_EXPORTER_OTLP_ENDPOINT | `https://otel.luban.paulhome.local:443` |
| OTEL_EXPORTER_OTLP_PROTOCOL | `grpc` |
| OTEL_EXPORTER_OTLP_CERTIFICATE | `/etc/otel-tls/ca.crt` |
| OTEL_SERVICE_NAME | `workflows-controller` |
| OTEL_RESOURCE_ATTRIBUTES | `service.name=workflows-controller` |

### Volume mount

```yaml
- name: otel-ca
  mountPath: /etc/otel-tls
  readOnly: true
```

### Volume

```yaml
- name: otel-ca
  configMap:
    name: otel-ca-cert
```

### Existing env preserved

- SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
- LEADER_ELECTION_IDENTITY (from fieldRef)

### Command

```bash
kubectl patch deployment workflow-controller -n argo --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"https://otel.luban.paulhome.local:443"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_PROTOCOL","value":"grpc"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_CERTIFICATE","value":"/etc/otel-tls/ca.crt"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_SERVICE_NAME","value":"workflows-controller"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_RESOURCE_ATTRIBUTES","value":"service.name=workflows-controller"}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"otel-ca","mountPath":"/etc/otel-tls","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"otel-ca","configMap":{"name":"otel-ca-cert"}}}
]'
```

---

## Step 3: Patch argo-server deployment

Same pattern as Step 2, with `service.name=argo-server`.

### Env vars

| Name | Value |
|------|-------|
| OTEL_EXPORTER_OTLP_ENDPOINT | `https://otel.luban.paulhome.local:443` |
| OTEL_EXPORTER_OTLP_PROTOCOL | `grpc` |
| OTEL_EXPORTER_OTLP_CERTIFICATE | `/etc/otel-tls/ca.crt` |
| OTEL_SERVICE_NAME | `argo-server` |
| OTEL_RESOURCE_ATTRIBUTES | `service.name=argo-server` |

### Existing env preserved

- SSO_DELEGATE_RBAC_TO_NAMESPACE=true
- ARGO_NAMESPACE (empty)
- ARGO_BASE_HREF=/

### Command

```bash
kubectl patch deployment argo-server -n argo --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"https://otel.luban.paulhome.local:443"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_PROTOCOL","value":"grpc"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_CERTIFICATE","value":"/etc/otel-tls/ca.crt"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_SERVICE_NAME","value":"argo-server"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_RESOURCE_ATTRIBUTES","value":"service.name=argo-server"}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"otel-ca","mountPath":"/etc/otel-tls","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"otel-ca","configMap":{"name":"otel-ca-cert"}}}
]'
```

---

## Step 4: Rolling restart

```bash
kubectl rollout restart deployment workflow-controller -n argo
kubectl rollout restart deployment argo-server -n argo

# Wait for ready
kubectl rollout status deployment/workflow-controller -n argo --timeout=120s
kubectl rollout status deployment/argo-server -n argo --timeout=120s
```

---

## Step 5: Verify

### 5a. Check pods are running

```bash
kubectl get pods -n argo -l app=workflow-controller
kubectl get pods -n argo -l app=argo-server
```

### 5b. Check OTEL env vars are set

```bash
kubectl exec -n argo deploy/workflow-controller -- env | grep OTEL
kubectl exec -n argo deploy/argo-server -- env | grep OTEL
```

### 5c. Check CA cert is mounted

```bash
kubectl exec -n argo deploy/workflow-controller -- ls /etc/otel-tls/
kubectl exec -n argo deploy/workflow-controller -- cat /etc/otel-tls/ca.crt | head -3
```

### 5d. Check controller logs for OTLP activity

```bash
kubectl logs -n argo deploy/workflow-controller --tail=20 | grep -i "otel\|otlp\|telemetry"
```

### 5e. Check remote collector health

```bash
curl -sk https://otel.luban.paulhome.local/health
```

### 5f. Check ES for incoming metrics

```bash
curl -sk -u "elastic:<PASSWORD>" \
  "https://es.luban.paulhome.local/_cat/indices" | grep -i "metric\|otel\|argo"
```

---

## Risk

- **Rolling restart:** ~10-30s Argo unavailability per deployment
- **OTLP export failure:** Argo logs errors but doesn't crash
- **Remote collector unreachable:** Argo retries with backoff
- **No workflow interruption:** OTLP is fire-and-forget

---

## What This Does Not Cover (future steps from guide)

- Prometheus ServiceMonitor for port 9090 metrics (separate)
- CronJob for workflow durations (separate)
- Kibana dashboards (separate)
- Gateway API routes on k3s-luban side (not needed — remote handles it)

---

*Created: 2026-08-03*
*Guide ref: /home/devops/Documents/paul-ai-worksapce/guides/argo-metrics/*

# OTel + Elastic APM Setup Reference (Session Notes)

## APM Endpoints

- Internal K8s service: `https://apm-server-apm-http.elastic-system.svc:8200`
- External gateway: `https://apm.luban.paulhome.local:443`

## Token Retrieval

```bash
kubectl get secret -n elastic-system apm-server-apm-token \
  -o jsonpath='{.data.secret-token}' | base64 -d
```

## Key Commands Used

### Create Secret + ConfigMap for in-cluster CA
```bash
kubectl create secret generic -n snd-dwh apm-otlp-headers \
  --from-literal=OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"

kubectl get secret -n luban-ci luban-ca-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/luban-ca.crt

kubectl create configmap -n snd-dwh luban-ca \
  --from-file=ca.crt=/tmp/luban-ca.crt
```

### Patch Deployment: Add Volume + Mount + Secret Env
```bash
# Add volume
kubectl patch deployment -n snd-dwh <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"luban-ca","configMap":{"name":"luban-ca"}}}]'

# Add volume mount
kubectl patch deployment -n snd-dwh <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"luban-ca","mountPath":"/etc/luban-ca","readOnly":true}}]'

# Add env var from secret
kubectl patch deployment -n snd-dwh <deploy> --type json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OTEL_EXPORTER_OTLP_HEADERS","valueFrom":{"secretKeyRef":{"name":"apm-otlp-headers","key":"OTEL_EXPORTER_OTLP_HEADERS"}}}}]'
```

### Patch ConfigMap
```bash
kubectl patch cm -n snd-dwh dagster-observability --type merge \
  -p='{"data":{"OTEL_EXPORTER_OTLP_CERTIFICATE":"/etc/luban-ca/ca.crt"}}'
```

## Error Diagnostics (SSLError)

```
SSL: CERTIFICATE_VERIFY_FAILED certificate verify failed: unable to get local issuer certificate
```

**Root cause**: OTel Python HTTP exporter (1.42+) has no `insecure` parameter — must provide CA cert.

**Fix**: Mount the APM server's internal CA cert (`apm-server-apm-http-certs-public`) or the gateway's Luban CA (`luban-ca-cert`).

## Python OTel SDK Env Vars (HTTP exporter)

The latest Python HTTP exporter reads these env vars (confirmed via inspect):
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_CERTIFICATE`
- `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE`
- `OTEL_EXPORTER_OTLP_CLIENT_KEY`
- `OTEL_EXPORTER_OTLP_COMPRESSION`
- `OTEL_EXPORTER_OTLP_HEADERS`
- `OTEL_EXPORTER_OTLP_TIMEOUT`
- Per-signal variants: `OTEL_EXPORTER_OTLP_TRACES_*`

Does NOT support: `OTEL_EXPORTER_OTLP_INSECURE` (gRPC only).

## Verified Working Config

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://apm.luban.paulhome.local:443
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>
OTEL_EXPORTER_OTLP_CERTIFICATE=/etc/luban-ca/ca.crt
OTEL_EXPORTER_OTLP_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_METRICS_EXPORTER=otlp
```

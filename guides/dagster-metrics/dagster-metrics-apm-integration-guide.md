# Dagster Metrics Exporter Configuration Guide

## Problem
The Dagster metrics exporter pod fails to send metrics to the APM server (`apm.luban.paulhome.local`) with two errors:

1. **SSL Certificate Verification Failed** — The APM server uses a self-signed certificate not trusted by the default CA bundle.
2. **401 Unauthorized** — The APM server requires authentication via Bearer token.

## Solution Overview

Three changes are required:

1. Add the APM server's self-signed certificate to the `luban-ca` ConfigMap.
2. Set the `OTEL_EXPORTER_OTLP_CERTIFICATE` environment variable so the OTel SDK uses the correct CA bundle.
3. Set the `OTEL_EXPORTER_OTLP_HEADERS` environment variable with the APM bearer token.

---

## Step 1: Get the APM Server Certificate

Retrieve the APM server's TLS certificate from the running pod:

```bash
kubectl -n <namespace> exec <pod-name> -- /workspace/.venv/bin/python3 -c "
import ssl, socket
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = socket.create_connection(('apm.luban.paulhome.local', 443), timeout=5)
s = ctx.wrap_socket(s, server_hostname='apm.luban.paulhome.local')
cert_der = s.getpeercert(binary_form=True)
from cryptography import x509
from cryptography.hazmat.primitives import serialization
cert = x509.load_der_x509_certificate(cert_der)
pem = cert.public_bytes(serialization.Encoding.PEM)
print(pem.decode())
"
```

Save the PEM output — it looks like:
```
-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIQRQ7RtjQ78QOSl8Yo0K3dCDANBgkqhkiG9w0BAQsFADAj
...
-----END CERTIFICATE-----
```

---

## Step 2: Add the Certificate to the luban-ca ConfigMap

Edit the `luban-ca` ConfigMap in the target namespace and append the APM certificate:

```bash
kubectl -n <namespace> get configmap luban-ca -o yaml > /tmp/luban-ca-patch.yaml
```

Open `/tmp/luban-ca-patch.yaml`, find the `ca.crt` field under `data:`, and append the APM certificate at the end (after the last `-----END CERTIFICATE-----`).

Apply the updated ConfigMap:

```bash
kubectl -n <namespace> apply -f /tmp/luban-ca-patch.yaml
```

Verify the cert is present:

```bash
kubectl -n <namespace> get cm luban-ca -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
content = data['data']['ca.crt']
print('Total certs:', content.count('BEGIN CERTIFICATE'))
# Check by looking at base64 data of the APM cert
apm_b64 = 'MIIDFTCCAf2gAwIBAgIQRQ7RtjQ78QOSl8Yo0K3dCDANBgkqhkiG9w0BAQsFADAj'
print('APM cert present:', apm_b64 in content)
"
```

Expected output: `APM cert present: True`

---

## Step 3: Set OTEL_EXPORTER_OTLP_CERTIFICATE Environment Variable

Add the env var to the deployment so the OTel SDK knows where to find the CA bundle:

```bash
kubectl -n <namespace> patch deployment <deployment-name> \
  --type=json \
  -p '[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "OTEL_EXPORTER_OTLP_CERTIFICATE", "value": "/etc/luban-ca/ca.crt"}}]'
```

For example, for the metrics exporter:

```bash
kubectl -n snd-dwh patch deployment dagster-platform-metrics-exporter \
  --type=json \
  -p '[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "OTEL_EXPORTER_OTLP_CERTIFICATE", "value": "/etc/luban-ca/ca.crt"}}]'
```

Verify the env var is set in the new pod:

```bash
NEW_POD=$(kubectl -n <namespace> get pods -l app=<label> --no-headers -o name | head -1 | cut -d/ -f2)
kubectl -n <namespace> exec "$NEW_POD" -- env | grep OTEL_EXPORTER_OTLP_CERTIFICATE
```

---

## Step 4: Get the APM Bearer Token

The APM token is stored in the `elastic-system` namespace as a Kubernetes Secret:

```bash
TOKEN=$(kubectl -n elastic-system get secret apm-server-apm-token -o jsonpath='{.data.secret-token}' | base64 -d)
echo "$TOKEN"
```

Expected output: `2yLlsJ0gpsx9R2IYGAq15y89` (or similar — always re-read this value).

---

## Step 5: Add the Auth Header to the Observability ConfigMap

Add the `OTEL_EXPORTER_OTLP_HEADERS` key to the `dagster-observability` ConfigMap:

```bash
kubectl -n <namespace> get configmap dagster-observability -o json 2>&1 | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['data']['OTEL_EXPORTER_OTLP_HEADERS'] = 'Authorization=Bearer <TOKEN>'
print(json.dumps(data, indent=2))
" > /tmp/dagster-observability-patch.json
```

Replace `<TOKEN>` with the actual token value from Step 4.

Apply the updated ConfigMap:

```bash
kubectl -n <namespace> apply -f /tmp/dagster-observability-patch.json
```

Verify:

```bash
kubectl -n <namespace> get cm dagster-observability -o yaml
```

Look for `OTEL_EXPORTER_OTLP_HEADERS: Authorization=Bearer ...` in the output.

---

## Step 6: Restart the Deployment

Roll out the new configuration:

```bash
kubectl -n <namespace> rollout restart deployment <deployment-name>
kubectl -n <namespace> rollout status deployment <deployment-name> --timeout=120s
```

For all Dagster components:

```bash
kubectl -n snd-dwh rollout restart deployment \
  dagster-platform-webserver \
  dagster-platform-daemon \
  dagster-platform-metrics-exporter
```

Wait for pods to be ready, then check logs:

```bash
sleep 75  # wait for first export cycle (60s interval + startup time)
kubectl -n <namespace> logs -l app=<label> --tail=30
```

Expected: No more SSL errors or 401 Unauthorized messages.

---

## Verification Checklist

- [ ] APM cert is in `luban-ca` ConfigMap (count should have increased)
- [ ] `OTEL_EXPORTER_OTLP_CERTIFICATE=/etc/luban-ca/ca.crt` is set on the pod
- [ ] `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>` is set on the pod
- [ ] Pod restarts successfully (check `kubectl get pods`)
- [ ] No SSL errors in logs
- [ ] No 401 Unauthorized errors in logs
- [ ] Metrics appear in Elasticsearch/Kibana

---

## Troubleshooting

### SSL still failing after adding cert to ConfigMap
The ConfigMap volume mount may take up to 1 minute to propagate. Force a rollout restart:
```bash
kubectl -n <namespace> rollout restart deployment <deployment-name>
```

### Still getting 401 Unauthorized
- Verify the token is current: `kubectl -n elastic-system get secret apm-server-apm-token -o jsonpath='{.data.secret-token}' | base64 -d`
- Verify the header format is correct: `Authorization=Bearer <token>` (no spaces around `=`)
- Check the env var in the running pod: `kubectl exec <pod> -- env | grep OTEL_EXPORTER_OTLP_HEADERS`

### Metrics not appearing in Kibana
- Check the OTel SDK is actually creating exporters with the right config:
  ```bash
  kubectl exec <pod> -- /workspace/.venv/bin/python3 -c "
  from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
  e = OTLPMetricExporter()
  print('endpoint:', e._endpoint)
  print('headers:', e._headers)
  print('certificate_file:', e._certificate_file)
  "
  ```
- Expected output should show the correct endpoint, headers dict, and certificate path.

---

## Files Modified

| Resource | Namespace | Change |
|----------|-----------|--------|
| `configmap/luban-ca` | `<namespace>` | Added APM server self-signed cert to `ca.crt` |
| `configmap/dagster-observability` | `<namespace>` | Added `OTEL_EXPORTER_OTLP_HEADERS` with bearer token |
| `deployment/<name>` | `<namespace>` | Added `OTEL_EXPORTER_OTLP_CERTIFICATE` env var |

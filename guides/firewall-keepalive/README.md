# 🔥 Firewall Keepalive — K8s CronJob

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Files](#files)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Endpoint Format](#endpoint-format)
  - [Protocol Details](#protocol-details)
- [Manual Testing](#manual-testing)
- [Customization](#customization)
  - [Change Schedule](#change-schedule)
  - [Add/Remove Endpoints](#addremove-endpoints)
  - [Change Namespace](#change-namespace)
- [Troubleshooting](#troubleshooting)
- [Job Status Output](#job-status-output)

---

## Overview

A generic K8s CronJob that performs periodic health-checks against a configurable list of endpoints (stored in a ConfigMap). The purpose is to generate regular traffic that prevents firewall rules from expiring due to inactivity.

**Key features:**
- Reads endpoints from a ConfigMap (no rebuild needed)
- Supports 4 protocols: `telnet`, `curl`, `curl-https`, `openssl`
- Reports pass/fail per endpoint in Job logs
- Configurable schedule (default: every hour)
- Lightweight — uses `busybox:1.37` image only

---

## Architecture

```
┌─────────────────────┐
│   K8s CronJob       │  Schedule: "0 * * * *" (每小時整點)
│   firewall-keepalive│
└────────┬────────────┘
         │
         │  mounts
         ▼
┌─────────────────────┐     ┌──────────────────────────────┐
│  ConfigMap          │     │  ConfigMap                   │
│  script-configmap   │     │  firewall-keepalive-endpoints│
│  (keepalive.sh)     │     │  (endpoints.txt)            │
└────────┬────────────┘     └──────────┬───────────────────┘
         │                             │
         ▼                             ▼
┌──────────────────────────────────────────────────┐
│  busybox:1.37 container                          │
│                                                  │
│  1. Read /config/endpoints.txt                   │
│  2. For each endpoint:                           │
│     ┌──────────┬──────────────────────────────┐  │
│     │ telnet   │ nc -zvw3 <host> <port>       │  │
│     │ curl     │ curl -sfk http://<host>:<port>│ │
│     │ curl-https│curl -sfk https://<host>:<port>││
│     │ openssl  │ openssl s_client -connect     │  │
│     └──────────┴──────────────────────────────┘  │
│  3. Print summary report to stdout               │
└──────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────┐
│  kubectl logs        │  查看 Job 執行結果
│  cronjob-<pod-name>  │
└──────────────────────┘
```

---

## Files

| File | Description |
|------|-------------|
| `cronjob.yaml` | CronJob resource definition |
| `endpoints-configmap.yaml` | ConfigMap with target endpoints |
| `script-configmap.yaml` | ConfigMap with the health-check script |
| `keepalive.sh` | Standalone script (same as script-configmap) |

---

## Quick Start

```bash
# 1. Edit endpoints-configmap.yaml — add your targets
vim endpoints-configmap.yaml

# 2. Apply all manifests
kubectl apply -f endpoints-configmap.yaml
kubectl apply -f script-configmap.yaml
kubectl apply -f cronjob.yaml

# 3. Verify
kubectl get cronjob firewall-keepalive

# 4. Test manually (one-shot Job)
kubectl create job --from=cronjob/firewall-keepalive firewall-keepalive-test

# 5. Check logs
kubectl logs job/firewall-keepalive-test
```

---

## Configuration

### Endpoint Format

Edit `endpoints-configmap.yaml`, the `endpoints.txt` data field:

```yaml
data:
  endpoints.txt: |
    telnet 10.0.0.1 22
    curl 10.0.0.1 80
    curl-https api.example.com 443
    openssl mail.example.com 465
```

**Rules:**
- One endpoint per line
- Format: `<protocol> <host> <port>`
- Lines starting with `#` are comments
- Empty lines are skipped

### Protocol Details

| Protocol | Tool | What it does | Use case |
|----------|------|-------------|----------|
| `telnet` | `nc -zvw3` | TCP connection check | SSH, DB ports, any TCP service |
| `curl` | `curl -sfk http://` | HTTP GET (insecure, follow redirects) | HTTP endpoints, web APIs |
| `curl-https` | `curl -sfk https://` | HTTPS GET (skip cert verify) | HTTPS endpoints, REST APIs |
| `openssl` | `openssl s_client` | TLS handshake + cert check | SMTP (465/587), LDAPS, HTTPS with cert validation |

---

## Manual Testing

### Run as one-shot Job

```bash
kubectl create job --from=cronjob/firewall-keepalive firewall-keepalive-manual
kubectl logs -f job/firewall-keepalive-manual
```

### Expected output

```
=======================================
🔥 Firewall Keepalive Report
🕐 2026-09-23 14:00:01
=======================================

✅ PASS  telnet 10.0.0.1:22
✅ PASS  curl 10.0.0.1:80
✅ PASS  curl-https api.example.com:443
✅ PASS  openssl mail.example.com:465

---------------------------------------
Total: 4 | ✅ Pass: 4 | ❌ Fail: 0
=======================================
```

### Cleanup test job

```bash
kubectl delete job firewall-keepalive-manual
```

---

## Customization

### Change Schedule

Edit `cronjob.yaml` → `spec.schedule`:

```yaml
spec:
  schedule: "*/30 * * * *"   # 每30分鐘
  schedule: "0 */2 * * *"    # 每2小時
  schedule: "*/10 * * * *"   # 每10分鐘 (測試用)
```

Apply:
```bash
kubectl apply -f cronjob.yaml
```

### Add/Remove Endpoints

Edit `endpoints-configmap.yaml` and apply:
```bash
kubectl apply -f endpoints-configmap.yaml
```

> ⚠️ ConfigMap changes are picked up on the **next** CronJob run.
> The current running Job uses the ConfigMap mounted at startup time.

### Change Namespace

1. Edit all YAML files → change `namespace: default` to your target
2. Apply:
```bash
kubectl apply -f endpoints-configmap.yaml -n <namespace>
kubectl apply -f script-configmap.yaml -n <namespace>
kubectl apply -f cronjob.yaml -n <namespace>
```

---

## Troubleshooting

### Job shows FAILED status

```bash
# Check logs
kubectl logs job/firewall-keepalive-<timestamp>

# Common reasons:
# - Some endpoints returned ❌ FAIL
# - ConfigMap not mounted (check: k describe job <name>)
```

### Pod stuck in ContainerCreating

```bash
kubectl describe pod/firewall-keepalive-<hash>
# Check Events for ImagePullBackOff, Mount issues, etc.
```

### ConfigMap not updating

ConfigMap volume mounts use **subPath-free** mode by default — they update automatically on the next Job's pod creation. If not:
```bash
# Force delete the ConfigMap and re-apply
kubectl delete configmap firewall-keepalive-endpoints
kubectl apply -f endpoints-configmap.yaml
```

### Image pull issues in air-gapped environment

Replace `busybox:1.37` in `cronjob.yaml` with your internal registry:
```yaml
image: registry.internal.com/library/busybox:1.37
```

---

## Job Status Output

Check all Jobs:
```bash
kubectl get jobs -l app=firewall-keepalive --sort-by=.metadata.creationTimestamp
```

Check latest run logs:
```bash
LATEST=$(kubectl get jobs -l app=firewall-keepalive --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs job/$LATEST
```

---

> **Note:** This keepalive approach sends real TCP/TLS/HTTP traffic to your endpoints.
> Each run opens connections briefly (seconds) and closes them. The combined traffic
> from all endpoints is minimal and should not impact performance.

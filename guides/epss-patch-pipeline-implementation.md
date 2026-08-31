# EPSS Patch Pipeline — Luban CI Implementation Guide

## Overview

EPSS (Exploit Prediction Scoring System) + Luban CI flow, two-layer automated patching for Harbor images on k3s-luban.



```
Layer 1: ClusterStack Rebase (全自动)
  CronWorkflow → EPSS scan → EPSS >= 0.7 (base OS) →
  Update ClusterStack → kpack rebase → Rollout restart

Layer 2: Application dep (Developer 处理)
  Dashboard 显示 → Developer update dependencies →
  git commit → Luban CI auto rebuild → ArgoCD sync
```

---

## Phase 1: RBAC

### Created Resources

| Resource | Type | Namespace | Description |
|----------|------|-----------|-------------|
| workflow-sa | ServiceAccount | argo | 执行 workflow |
| epss-workflow-role | ClusterRole | cluster-wide | kpack, deployments, pods 权限 |
| epss-workflow-binding | ClusterRoleBinding | cluster-wide | 绑定 workflow-sa |

### ClusterRole Rules

```yaml
rules:
  # kpack: discover images across namespaces
  - apiGroups: ["kpack.io"]
    resources: ["images", "builds"]
    verbs: ["get", "list", "watch"]
  # kpack: update ClusterStack
  - apiGroups: ["kpack.io"]
    resources: ["clusterstacks"]
    verbs: ["get", "list", "watch", "update", "patch"]
  # kpack: trigger rebase (annotate images)
  - apiGroups: ["kpack.io"]
    resources: ["images/finalizers"]
    verbs: ["update"]
  # Core: read namespaces
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list"]
  # Core: read secrets/configmaps
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch"]
  # Apps: rollout restart deployments
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch"]
  # Core: check pod status
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  # Core: read pod logs
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  # Argo: workflow task results
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

### Verification

```bash
# Test RBAC from workflow-sa
kubectl run rbac-test --rm -it --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"workflow-sa"}}' \
  -n argo --image=curlimages/curl:latest -- sh -c '
    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    API=https://kubernetes.default.svc
    # Test kpack images
    curl -s -o /dev/null -w "%{http_code}" --cacert $CA -H "Authorization: Bearer $TOKEN" "$API/apis/kpack.io/v1alpha2/namespaces/ci-dwh/images"
    # Test ClusterStacks
    curl -s -o /dev/null -w "%{http_code}" --cacert $CA -H "Authorization: Bearer $TOKEN" "$API/apis/kpack.io/v1alpha2/clusterstacks"
    # Test Deployments
    curl -s -o /dev/null -w "%{http_code}" --cacert $CA -H "Authorization: Bearer $TOKEN" "$API/apis/apps/v1/namespaces/ci-dwh/deployments"
  '
```

---

## Phase 2: Config + Secrets

### Resources

| Resource | Type | Namespace |
|----------|------|-----------|
| epss-config | ConfigMap | argo |
| epss-secrets | Secret | argo |

### ConfigMap: epss-config

```yaml
data:
  HARBOR_URL: "https://ds01-harbor.luban.paulhome.local"
  EPSS_API: "https://api.first.org/data/v1/epss"
  PROMETHEUS_PUSHGATEWAY: "http://pushgateway.cattle-monitoring-system:9091"
  CLUSTERSTACK_NAME: "luban-stack"
  BUILD_IMAGE: "harbor.luban.paulhome.local/luban-ci/luban-build:al2023-ca1"
  RUN_IMAGE: "harbor.luban.paulhome.local/luban-ci/luban-run:al2023-ca1"
```

### Secret: epss-secrets

```yaml
stringData:
  HARBOR_USER: "admin"
  HARBOR_PASSWORD: "Harbor12345"
```


```yaml
data:
  config.json: <base64-encoded docker config>
```

### Key Decisions

- `SCAN_NAMESPACES` NOT in ConfigMap — specified via Workflow parameter `kpack_namespaces`
- Harbor URL: `ds01-harbor.luban.paulhome.local` (not `harbor.luban.paulhome.local`)
- Pushgateway: `pushgateway.cattle-monitoring-system:9091` (not `pushgateway.monitoring`)

---

## Phase 3: WorkflowTemplate + CronWorkflow + Scan Script

### WorkflowTemplate: epss-auto-patch

**Parameter**: `kpack_namespaces` (default: "ci-dwh")

**DAG**:
```
scan → update-stack → rebase-images → restart-pods
```

**Conditional Execution**:
- `scan` always runs, always exits 0
- Writes `rebase_needed.txt` with "true" or "false"
- Output parameter `rebase_needed` read by Argo
- Steps 2-4 use `when: {{tasks.scan.outputs.parameters.rebase_needed}} == true`

### Templates

| Template | Image | Purpose |
|----------|-------|---------|
| scan-and-identify | python:3.11-slim | Trivy scan + EPSS enrich |
| update-clusterstack | bitnami/kubectl:latest | kubectl patch clusterstack |
| kpack-rebase-all | bitnami/kubectl:latest | annotate images force-rebase |
| rollout-restart | bitnami/kubectl:latest | kubectl rollout restart |

### Scan Container Setup

```yaml
container:
  image: python:3.11-slim
  command: ['sh', '-c']
  args:
    - |
      pip install --no-cache-dir --target /tmp/pylibs requests >/dev/null 2>&1
      python -c "import urllib.request,os; urllib.request.urlretrieve('https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl','/tmp/kubectl'); os.chmod('/tmp/kubectl',0o755)"
      python -c "import urllib.request,os,tarfile,io; u=urllib.request.urlopen('https://github.com/aquasecurity/trivy/releases/download/v0.74.0/trivy_0.74.0_Linux-64bit.tar.gz'); t=tarfile.open(fileobj=io.BytesIO(u.read())); m=t.extractfile('trivy'); open('/tmp/trivy','wb').write(m.read()); os.chmod('/tmp/trivy',0o755)"
      export PATH=/tmp:$PATH
      export TRIVY_CACHE_DIR=/tmp/trivy-cache
      mkdir -p $TRIVY_CACHE_DIR
      trivy image --download-db-only --timeout 5m 2>/dev/null
      PYTHONPATH=/tmp/pylibs python /scripts/scan-and-identify.py
```

### Key Fixes Applied

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| `No module named 'requests'` | PEP 668 blocks system pip | `pip install --target /tmp/pylibs` + `PYTHONPATH=/tmp/pylibs` |
| `kubectl: not found` | python:3.11-slim has no kubectl | Download kubectl via urllib to /tmp |
| `wget: not found` | python:3.11-slim has no wget | Use Python urllib for downloads |
| `Trivy 404` | v0.55.0 has no binary assets | Use v0.74.0 |
| `mkdir /.cache: permission denied` | Non-root container | `TRIVY_CACHE_DIR=/tmp/trivy-cache` |
| `PermissionError: /usr/local/bin/trivy` | Non-root container | Download to `/tmp/trivy` |
| `UNAUTHORIZED` for Harbor images | Stale kpack digests | Use `:latest` tag instead of digest |
| `TypeError: float vs str` | EPSS API returns strings | `float(item['epss'])` with try/except |
| `workflowtaskresults: forbidden` | Missing RBAC | Added to ClusterRole |

### CronWorkflow: epss-daily-auto-patch

```yaml
spec:
  schedules:
    - "0 2 * * *"
  concurrencyPolicy: "Forbid"
  workflowSpec:
    workflowTemplateRef:
      name: epss-auto-patch
    arguments:
      parameters:
        - name: kpack_namespaces
          value: "ci-dwh"
```

**Adding new namespace**: patch CronWorkflow value
```bash
kubectl patch cronworkflow epss-daily-auto-patch -n argo \
  --type=merge -p '{"spec":{"workflowSpec":{"arguments":{"parameters":[{"name":"kpack_namespaces","value":"ci-dwh,ci-marketing"}]}}}}'
```

---

## Phase 4: Scan Script (scan-and-identify.py)

### Flow

```
1. Discover kpack images from KPACK_NAMESPACES
   kubectl get images.kpack.io -n <ns> -o json
   → Use status.latestImage or spec.tag + ":latest"

2. Check if digest exists in Harbor (skip stale)
   HEAD /v2/<repo>/manifests/<digest>

3. Trivy scan each image
   trivy image --format json --severity CRITICAL,HIGH --insecure <image>
   → Uses TRIVY_USERNAME / TRIVY_PASSWORD env vars

4. EPSS enrich CVEs
   GET https://api.first.org/data/v1/epss?cve=CVE-xxx,CVE-yyy
   → Batch of 50, rate limit 0.5s

5. Categorize: base OS vs app CVEs
   BASE_OS_PACKAGES = {openssl, curl, libc6, ...}

6. Push metrics to Prometheus Pushgateway
   PUT http://pushgateway.cattle-monitoring-system:9091/metrics/job/epss_scan/instance/<ts>

7. Write results
   /workspace/scan-results.json
   /workspace/base-os-rebuild-list.json
   /workspace/rebase_needed.txt (true/false)

8. Always exit 0 (Argo treats non-zero as failure)
```

### Metrics Pushed

```
epss_image_base_os_cve{namespace,image} <count>
epss_image_app_cve{namespace,image} <count>
epss_image_epss_max{namespace,image} <score>
epss_image_total_vulns{namespace,image} <count>
epss_global_base_os_critical <count>
epss_global_app_critical <count>
epss_images_scanned <count>
epss_images_rebase_needed <count>
```

### Stale Digest Handling

kpack images may reference digests that were garbage-collected by Harbor. The script handles this by:

1. Using `:latest` tag instead of digest reference
2. For non-READY kpack images, falls back to `spec.tag + ":latest"`
3. Checking Harbor API before scanning (HEAD request)

---

## Phase 5: Grafana Dashboards

### Dashboard 1: Security Posture

| Panel | Type | Query |
|-------|------|-------|
| 🔴 Base OS Critical CVEs | stat | `epss_global_base_os_critical` |
| 🟡 App Critical CVEs | stat | `epss_global_app_critical` |
| 📊 Images Scanned | stat | `epss_images_scanned` |
| 🔄 Rebase Needed | stat | `epss_images_rebase_needed` |
| 📈 Base OS vs App CVEs (7d) | timeseries | `epss_global_base_os_critical`, `epss_global_app_critical` |
| 📈 Images Scanned (7d) | timeseries | `epss_images_scanned`, `epss_images_rebase_needed` |
| 🔍 Per-Image CVE Detail | table | `epss_image_*` |

### Dashboard 2: Auto-Patch Pipeline

| Panel | Type | Query |
|-------|------|-------|
| 🔄 Images Scanned | stat | `epss_images_scanned` |
| 🔴 Base OS Critical | stat | `epss_global_base_os_critical` |
| 🔄 Rebase Needed | stat | `epss_images_rebase_needed` |
| 📈 Scan History (7d) | timeseries | `epss_images_scanned`, `epss_images_rebase_needed`, `epss_global_*` |

### Namespace

Dashboards deployed to `cattle-dashboards` (not `cattle-monitoring-system`).

Grafana sidecar config:
```
NAMESPACE: cattle-dashboards
LABEL: grafana_dashboard=1
```

### Pushgateway

Deployed in `cattle-monitoring-system`:
- Deployment: `prom/pushgateway:v1.9.0`
- Service: `pushgateway:9091`
- ServiceMonitor: port 9091, interval 30s

---

## Phase 6: Stack Rebuild Workflow

### Purpose

When upstream Amazon Linux 2023 has security update, automatically:
1. Detect change
2. Update ClusterStack
3. kpack rebase all images
4. Wait for builds
5. Rollout restart

### WorkflowTemplate: stack-rebuild

```
check-upstream → update-clusterstack → rebase-images → wait-for-builds → restart-pods
```

| Template | Image | Purpose |
|----------|-------|---------|
| check-upstream-digest | python:3.11-slim | Query ECR API for digest |
| update-clusterstack | bitnami/kubectl:latest | Trigger kpack rebuild |
| kpack-rebase-all | bitnami/kubectl:latest | annotate images force-rebase |
| wait-for-kpack-builds | bitnami/kubectl:latest | wait for image Ready |
| rollout-restart | bitnami/kubectl:latest | kubectl rollout restart |

### CronWorkflow: stack-rebuild-check

```yaml
spec:
  schedules:
    - "0 */6 * * *"
  concurrencyPolicy: "Forbind"
  workflowSpec:
    workflowTemplateRef:
      name: stack-rebuild
```

### Known Issue

check-upstream.py fails with ECR API 404 — `Docker-Content-Digest` header not returned. Currently using placeholder (`exit 0`). Needs fix.

---

## kpack Image Discovery

The pipeline dynamically discovers kpack images from specified namespaces:

```python
# Prefer status.latestImage, fall back to spec.tag
latest = item.get('status', {}).get('latestImage', '')
spec_tag = item.get('spec', {}).get('tag', '')
if latest:
    image_ref = latest.split('@')[0] + ':latest'  # strip digest, use :latest
elif spec_tag:
    image_ref = spec_tag + ':latest'
```

### Current kpack Images

| Namespace | Image | Source | Status |
|-----------|-------|--------|--------|
| ci-dwh | cms | git@ssh.dev.azure.com:v3/paulbeyond/dwh/cms | Ready |
| ci-dwh | comp | git@ssh.dev.azure.com:v3/paulbeyond/dwh/comp | Unknown (build failed) |
| ci-dwh | dagster-platform | git@ssh.dev.azure.com:v3/paulbeyond/dwh/dagster-platform | Unknown |
| ci-dwh | ewallet | git@ssh.dev.azure.com:v3/paulbeyond/dwh/ewallet | Ready |
| ci-dwh | ferry | git@ssh.dev.azure.com:v3/paulbeyond/dwh/ferry | Unknown |

---

## Resource Summary

| Phase | Resource | Status |
|-------|----------|--------|
| 1 | ServiceAccount: workflow-sa | ✅ |
| 1 | ClusterRole: epss-workflow-role | ✅ |
| 1 | ClusterRoleBinding: epss-workflow-binding | ✅ |
| 2 | ConfigMap: epss-config | ✅ |
| 2 | Secret: epss-secrets | ✅ |
| 3 | WorkflowTemplate: epss-auto-patch | ✅ |
| 3 | CronWorkflow: epss-daily-auto-patch | ✅ |
| 3 | ConfigMap: epss-scripts | ✅ |
| 3 | ConfigMap: epss-stack-digest | ✅ |
| 4 | scan-and-identify.py | ✅ |
| 5 | ConfigMap: grafana-dashboard-epss-security | ✅ |
| 5 | ConfigMap: grafana-dashboard-epss-pipeline | ✅ |
| 5 | Deployment: pushgateway | ✅ |
| 5 | Service: pushgateway | ✅ |
| 5 | ServiceMonitor: pushgateway | ✅ |
| 6 | WorkflowTemplate: stack-rebuild | ✅ |
| 6 | CronWorkflow: stack-rebuild-check | ✅ |
| 6 | ConfigMap: stack-rebuild-scripts | ✅ |

---

## Pending Issues

| Issue | Description | Priority |
|-------|-------------|----------|
| ECR API 404 | check-upstream.py can't get Docker-Content-Digest header | Medium |
| kpack image stale digests | comp, dagster-platform, ferry builds failed | Low (use :latest tag) |
| Pushgateway metrics expire | Metrics not persistent across restarts | Low |

---

## Files

```
/tmp/epss-scan-and-identify.py          Main scan script
/tmp/epss-scan-wrapper.sh               Wrapper script (unused, kept for reference)
/tmp/epss-workflow-template-v7.yaml     epss-auto-patch WorkflowTemplate
/tmp/epss-cronworkflow.yaml             epss-daily-auto-patch CronWorkflow
/tmp/epss-dashboard-security.yaml       Security Posture dashboard
/tmp/epss-dashboard-pipeline.yaml       Auto-Patch Pipeline dashboard
/tmp/stack-rebuild-workflow.yaml        stack-rebuild WorkflowTemplate
/tmp/stack-rebuild-cron.yaml            stack-rebuild-check CronWorkflow
/tmp/check-upstream.py                  Upstream digest check (ECR API issue)
/tmp/epss-rbac.yaml                     RBAC resources
/tmp/stack/{base,run,build}/Dockerfile  Stack image Dockerfiles
```

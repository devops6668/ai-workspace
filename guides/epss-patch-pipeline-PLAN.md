# EPSS Patch Pipeline — ArgoWorkflows + Grafana 方案 (v3)

## 概覽

利用 EPSS 機率評分，自動化 Harbor image 漏洞掃描同修復。

```
Stage 1: CronWorkflow (每日自動)
  Trivy scan → EPSS enrich → Push metrics → Grafana Dashboard 顯示 EPSS >= 0.7

Stage 2: Workflow (人手觸發)
  人睇 Dashboard → input image name → rebuild → verify → push → ArgoCD sync
```

Grafana Dashboard 係 Stage 1 同 Stage 2 嘅唯一交接介面。

---

## 架構

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌─── Stage 1: CronWorkflow (每日 02:00) ───────────────────┐  │
│  │                                                            │  │
│  │  Harbor ──▶ Trivy Scan ──▶ EPSS Query ──▶ Push Metrics   │  │
│  │                                                  │         │  │
│  │                                                  ▼         │  │
│  │                                          ┌──────────────┐  │  │
│  │                                          │  Prometheus   │  │  │
│  │                                          │  Pushgateway  │  │  │
│  │                                          └──────┬───────┘  │  │
│  └─────────────────────────────────────────────────┼──────────┘  │
│                                                    │             │
│                                                    ▼             │
│                                          ┌──────────────────┐   │
│                                          │  Grafana         │   │
│                                          │  Dashboard       │   │
│                                          │                  │   │
│                                          │  EPSS >= 0.7     │   │
│                                          │  列出所有高風險    │   │
│                                          │  CVE + Image     │   │
│                                          └────────┬─────────┘   │
│                                                   │              │
│                                          人 review + 記低 image  │
│                                                   │              │
│  ┌─── Stage 2: Workflow (人手觸發) ───────────────┼──────────┐  │
│  │                                                │           │  │
│  │  argo submit epss-auto-fix \                   │           │  │
│  │    --parameter image=dwh/dagster-platform:latest           │  │
│  │                                                │           │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │  │
│  │  │ Build   │─▶│ Trivy   │─▶│ Push    │─▶│ ArgoCD  │      │  │
│  │  │ Kaniko  │  │ Verify  │  │ Harbor  │  │ Sync    │      │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 組件

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-scan | CronWorkflow | argo | 每日凌晨 2 點 |
| epss-scan | WorkflowTemplate | argo | Stage 1 scan workflow |
| epss-auto-fix | WorkflowTemplate | argo | Stage 2 fix workflow |
| workflow-sa | ServiceAccount | argo | 執行 workflow |
| epss-config | ConfigMap | argo | Harbor URL、EPSS API |
| epss-secrets | Secret | argo | Harbor credentials |
| pushgateway | Deployment | monitoring | Prometheus Pushgateway |
| pushgateway | Service | monitoring | :9091 |
| epss-dashboard | ConfigMap | cattle-monitoring-system | Grafana dashboard |

---

## Phase 1: 安裝 ArgoWorkflows

### 1.1 Helm Install
```bash
kubectl create namespace argo

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.enabled=true \
  --set controller.workflowNamespace=argo \
  --set controller.workflowWorkers=16 \
  --wait
```

### 1.2 RBAC
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workflow-role
  namespace: argo
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "secrets", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "cronworkflows"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workflow-role-binding
  namespace: argo
subjects:
  - kind: ServiceAccount
    name: workflow-sa
    namespace: argo
roleRef:
  kind: Role
  name: workflow-role
  apiGroup: rbac.authorization.k8s.io
```

### 1.3 Gateway Route
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argo-workflows-ui
  namespace: argo
spec:
  parentRefs:
    - name: luban-gateway
      namespace: infra
  hostnames:
    - "argo-workflows.luban.paulhome.local"
  rules:
    - backendRefs:
        - name: argo-workflows-server
          port: 2746
```

---

## Phase 2: Pushgateway + Grafana Dashboard

### 2.1 Pushgateway
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pushgateway
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pushgateway
  template:
    metadata:
      labels:
        app: pushgateway
    spec:
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          ports:
            - containerPort: 9091
---
apiVersion: v1
kind: Service
metadata:
  name: pushgateway
  namespace: monitoring
spec:
  selector:
    app: pushgateway
  ports:
    - port: 9091
      targetPort: 9091
```

### 2.2 Grafana Dashboard

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-epss
  namespace: cattle-monitoring-system
  labels:
    grafana_dashboard: "1"
data:
  epss-dashboard.json: |
    {
      "uid": "epss-patch",
      "title": "EPSS Patch Pipeline",
      "tags": ["epss", "security"],
      "panels": [
        {
          "title": "🔴 EPSS >= 0.7 — 需要即刻修復",
          "type": "table",
          "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
          "targets": [{
            "expr": "epss_vuln_epss_score",
            "format": "table",
            "instant": true
          }],
          "transformations": [
            {
              "id": "filterByValue",
              "options": {
                "conditions": [{
                  "fieldName": "epss_score",
                  "operator": { "gte": 0.7 },
                  "type": "number"
                }]
              }
            }
          ],
          "fieldConfig": {
            "defaults": {
              "custom": { "align": "auto" },
              "mappings": []
            },
            "overrides": [
              {
                "matcher": { "id": "byName", "options": "epss_score" },
                "properties": [{ "id": "thresholds", "value": {
                  "steps": [
                    { "color": "green", "value": null },
                    { "color": "yellow", "value": 0.2 },
                    { "color": "orange", "value": 0.5 },
                    { "color": "red", "value": 0.7 }
                  ]
                }}]
              }
            ]
          }
        },
        {
          "title": "📊 EPSS Score 分佈",
          "type": "histogram",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 10 },
          "targets": [{
            "expr": "epss_vuln_epss_score",
            "legendFormat": "{{image}}"
          }]
        },
        {
          "title": "🖼️ 每個 Image 嘅 Critical CVE 數",
          "type": "barchart",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 10 },
          "targets": [{
            "expr": "topk(10, epss_vuln_critical)",
            "legendFormat": "{{image}}"
          }]
        },
        {
          "title": "📈 歷史趨勢 (7日)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 18 },
          "targets": [
            { "expr": "epss_global_critical", "legendFormat": "Critical (EPSS>=0.7)" },
            { "expr": "epss_global_high", "legendFormat": "High (EPSS 0.2-0.7)" }
          ]
        }
      ],
      "time": { "from": "now-7d", "to": "now" },
      "refresh": "1h"
    }
```

### 2.3 Dashboard Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  🔴 EPSS >= 0.7 — 需要即刻修復 (Table)                         │
├─────────────────────────────────────────────────────────────────┤
│ CVE          │ Image              │ Package  │ CVSS │ EPSS      │
│ CVE-2024-3094│ dagster-platform   │ xz-utils │ 8.8  │ 0.92 🔴   │
│ CVE-2024-21626│ comp              │ runc     │ 8.6  │ 0.85 🔴   │
│ CVE-2024-1086│ cms                │ kernel   │ 7.8  │ 0.78 🔴   │
└─────────────────────────────────────────────────────────────────┘
│                                                                 │
│  📊 EPSS Score 分佈          │  🖼️ Critical CVEs per Image     │
│  (histogram)                 │  (barchart)                     │
│                              │                                 │
├──────────────────────────────┴─────────────────────────────────┤
│  📈 歷史趨勢 (7日)                                              │
│  ── Critical ── High ──                                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 3: Stage 1 — Scan CronWorkflow

### 3.1 ConfigMap + Secret

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: epss-config
  namespace: argo
data:
  HARBOR_URL: "https://ds01-harbor.luban.paulhome.local"
  EPSS_API: "https://api.first.org/data/v1/epss"
  PROMETHEUS_PUSHGATEWAY: "http://pushgateway.monitoring:9091"
  SCAN_PROJECTS: "dwh,library"
---
apiVersion: v1
kind: Secret
metadata:
  name: epss-secrets
  namespace: argo
type: Opaque
stringData:
  HARBOR_USER: "admin"
  HARBOR_PASSWORD: "<password>"
```

### 3.2 CronWorkflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: epss-daily-scan
  namespace: argo
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: "Forbid"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  workflowSpec:
    workflowTemplateRef:
      name: epss-scan
```

### 3.3 WorkflowTemplate — Stage 1

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: epss-scan
  namespace: argo
spec:
  entrypoint: scan-pipeline

  templates:
    - name: scan-pipeline
      dag:
        tasks:
          - name: scan-and-push
            template: epss-scan

    - name: epss-scan
      container:
        image: python:3.11-slim
        command: [python, /scripts/scan.py]
        envFrom:
          - configMapRef:
              name: epss-config
          - secretRef:
              name: epss-secrets
        volumeMounts:
          - name: scripts
            mountPath: /scripts

  volumes:
    - name: scripts
      configMap:
        name: epss-scripts
        defaultMode: 0755
```

### 3.4 scan.py (Stage 1 主要邏輯)

```python
#!/usr/bin/env python3
"""
Stage 1: Scan all Harbor images, enrich with EPSS, push metrics.
No report files — metrics go to Prometheus, Grafana displays.
"""
import requests, json, os, subprocess, time
from datetime import datetime

HARBOR_URL = os.environ['HARBOR_URL']
HARBOR_USER = os.environ['HARBOR_USER']
HARBOR_PASS = os.environ['HARBOR_PASSWORD']
EPSS_API = os.environ['EPSS_API']
PUSHGATEWAY = os.environ['PROMETHEUS_PUSHGATEWAY']
PROJECTS = os.environ.get('SCAN_PROJECTS', 'dwh').split(',')

def list_images():
    images = []
    for project in PROJECTS:
        repos = requests.get(
            f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories",
            auth=(HARBOR_USER, HARBOR_PASS), verify=False
        ).json()
        for repo in repos:
            name = repo['name']
            artifacts = requests.get(
                f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories/{name}/artifacts",
                auth=(HARBOR_USER, HARBOR_PASS), verify=False,
                params={'page_size': 5}
            ).json()
            for a in artifacts:
                tag = a.get('tags', [{}])[0].get('name', 'latest') if a.get('tags') else 'latest'
                images.append({
                    'project': project,
                    'repo': name,
                    'tag': tag,
                    'full': f"{HARBOR_URL.split('//')[1]}/{name}:{tag}"
                })
    return images

def trivy_scan(image):
    try:
        proc = subprocess.run(
            ['trivy', 'image', '--format', 'json',
             '--severity', 'CRITICAL,HIGH', '--scanners', 'vuln', image],
            capture_output=True, text=True, timeout=600
        )
        if proc.returncode in (0, 1):
            vulns = []
            for r in json.loads(proc.stdout).get('Results', []):
                for v in r.get('Vulnerabilities', []):
                    vulns.append({
                        'cve': v['VulnerabilityID'],
                        'pkg': v['PkgName'],
                        'cvss': v.get('CVSS', {}).get('nvd', {}).get('V3Score', 0),
                        'fixed': v.get('FixedVersion', '')
                    })
            return vulns
    except:
        pass
    return []

def query_epss(cve_list):
    epss = {}
    for i in range(0, len(cve_list), 50):
        batch = cve_list[i:i+50]
        try:
            resp = requests.get(EPSS_API, params={'cve': ','.join(batch)}, timeout=30)
            for item in resp.json().get('data', []):
                epss[item['cve']] = {'score': item['epss'], 'percentile': item['percentile']}
        except:
            pass
        time.sleep(0.5)  # rate limit
    return epss

def push_metrics(results):
    lines = []
    ts = datetime.now().strftime('%Y%m%d%H%M%S')

    for r in results:
        img = r['image'].replace('/', '_').replace(':', '_')
        vulns = r.get('enriched_vulns', [])

        critical = [v for v in vulns if v.get('epss', 0) >= 0.7]
        high = [v for v in vulns if 0.2 <= v.get('epss', 0) < 0.7]

        lines.append(f'epss_vuln_critical{{image="{img}"}} {len(critical)}')
        lines.append(f'epss_vuln_high{{image="{img}"}} {len(high)}')

        # Per CVE metrics (for Grafana table)
        for v in vulns:
            lines.append(
                f'epss_vuln_epss_score{{image="{r["image"]}",'
                f'cve="{v["cve"]}",pkg="{v["pkg"]}",'
                f'cvss="{v.get("cvss",0)}"}} {v.get("epss", 0):.4f}'
            )

    # Global
    total_crit = sum(1 for r in results for v in r.get('enriched_vulns', []) if v.get('epss', 0) >= 0.7)
    total_high = sum(1 for r in results for v in r.get('enriched_vulns', []) if 0.2 <= v.get('epss', 0) < 0.7)
    lines.append(f'epss_global_critical {total_crit}')
    lines.append(f'epss_global_high {total_high}')
    lines.append(f'epss_images_scanned {len(results)}')

    body = '\n'.join(lines) + '\n'
    url = f"{PUSHGATEWAY}/metrics/job/epss_scan/instance/{ts}"
    requests.put(url, data=body, timeout=10)
    print(f"Pushed {len(lines)} metrics")

def main():
    print(f"[{datetime.now()}] Starting EPSS scan...")
    images = list_images()
    print(f"Found {len(images)} images")

    results = []
    for img in images:
        print(f"Scanning {img['full']}...")
        vulns = trivy_scan(img['full'])
        if not vulns:
            continue

        cve_ids = [v['cve'] for v in vulns]
        epss_data = query_epss(cve_ids)

        for v in vulns:
            v['epss'] = epss_data.get(v['cve'], {}).get('score', 0.01)

        results.append({
            'image': img['full'],
            'project': img['project'],
            'repo': img['repo'],
            'enriched_vulns': vulns
        })

    push_metrics(results)
    print(f"Done. {len(results)} images scanned.")

if __name__ == '__main__':
    main()
```

---

## Phase 4: Stage 2 — Auto-Fix Workflow

### 4.1 WorkflowTemplate

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: epss-auto-fix
  namespace: argo
spec:
  entrypoint: fix-pipeline
  arguments:
    parameters:
      - name: image
        description: "Full image reference (e.g. dwh/dagster-platform:latest)"
      - name: dockerfile-url
        description: "Git URL of Dockerfile (optional)"
        value: ""
      - name: base-image
        description: "Base image to rebuild from"
        value: ""

  templates:
    - name: fix-pipeline
      dag:
        tasks:
          - name: build
            template: build-image
          - name: scan-verify
            template: trivy-verify
            dependencies: [build]
          - name: push
            template: push-to-harbor
            dependencies: [scan-verify]
          - name: sync
            template: argocd-sync
            dependencies: [push]

    - name: build-image
      retryStrategy:
        limit: 2
      container:
        image: gcr.io/kaniko-project/executor:v1.23.2
        args:
          - --dockerfile=/workspace/Dockerfile
          - --context=dir:///workspace
          - --destination={{workflow.parameters.image}}
          - --cache=true
          - --cache-repo=harbor.paulhome.local/cache
        env:
          - name: DOCKER_CONFIG
            value: /kaniko/.docker
        volumeMounts:
          - name: docker-config
            mountPath: /kaniko/.docker
            readOnly: true
          - name: workspace
            mountPath: /workspace

    - name: trivy-verify
      container:
        image: aquasec/trivy:0.58.0
        command: [trivy]
        args:
          - image
          - --exit-code, "1"
          - --severity, CRITICAL,HIGH
          - --ignore-unfixed
          - "{{workflow.parameters.image}}"

    - name: push-to-harbor
      container:
        image: curlimages/curl:8.5.0
        command: [sh, -c]
        args:
          - |
            # Trigger Harbor rescan
            PROJECT=$(echo $IMAGE | cut -d/ -f1)
            REPO=$(echo $IMAGE | cut -d/ -f1,2)
            TAG=$(echo $IMAGE | cut -d: -f2)
            curl -sk -u $HARBOR_USER:$HARBOR_PASS \
              -X POST "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories/$REPO/artifacts/$TAG/scan"
        env:
          - name: IMAGE
            value: "{{workflow.parameters.image}}"
          - name: HARBOR_URL
            valueFrom:
              configMapKeyRef:
                name: epss-config
                key: HARBOR_URL
          - name: HARBOR_USER
            valueFrom:
              secretKeyRef:
                name: epss-secrets
                key: HARBOR_USER
          - name: HARBOR_PASS
            valueFrom:
              secretKeyRef:
                name: epss-secrets
                key: HARBOR_PASSWORD

    - name: argocd-sync
      container:
        image: argoproj/argocd-cli:v2.12.0
        command: [sh, -c]
        args:
          - |
            APP=$(echo $IMAGE | cut -d/ -f1)
            argocd app sync "$APP" --force
        env:
          - name: IMAGE
            value: "{{workflow.parameters.image}}"
          - name: ARGOCD_SERVER
            value: "argocd-server.argocd.svc.cluster.local"

  volumes:
    - name: docker-config
      secret:
        secretName: harbor-registry-creds
    - name: workspace
      emptyDir: {}
```

### 4.2 觸發 Stage 2

```bash
# CLI — 人睇完 Dashboard，記低 image name，執行：
argo submit epss-auto-fix \
  --parameter image="dwh/dagster-platform:latest" \
  -n argo

# Web UI
# argo-workflows.luban.paulhome.local
# → Templates → epss-auto-fix → Submit
# → 填 image name → Submit
```

---

## 完整流程

```
每日 02:00                              人手觸發
    │                                      │
    ▼                                      ▼
┌─────────────┐                      ┌─────────────┐
│ CronWorkflow│                      │  Workflow   │
│ epss-scan   │                      │ epss-fix    │
└──────┬──────┘                      └──────┬──────┘
       │                                     │
       ▼                                     ▼
  Trivy scan                           Build image
       │                              (Kaniko)
       ▼                                     │
  EPSS enrich                                ▼
       │                              Trivy verify
       ▼                                     │
  Push metrics ──▶ Prometheus                ▼
                         │             Push harbor
                         ▼                   │
                    Grafana Dashboard        ▼
                         │             ArgoCD Sync
                         ▼
                    ┌──────────┐
                    │ 人 review │
                    │ 記低 image │
                    │ name      │
                    └────┬─────┘
                         │
                         ▼
                  argo submit epss-auto-fix \
                    --parameter image="xxx"
```

---

## 時間線

| Phase | 內容 | 預計時間 |
|-------|------|----------|
| Phase 1 | 安裝 ArgoWorkflows | 30 min |
| Phase 2 | Pushgateway + Grafana Dashboard | 1 hr |
| Phase 3 | Stage 1 — Scan CronWorkflow | 2 hr |
| Phase 4 | Stage 2 — Fix Workflow | 2 hr |
| **Total** | | **~5.5 hr** |

# EPSS Patch Pipeline — ArgoWorkflows + Grafana 方案

## 概覽

利用 EPSS (Exploit Prediction Scoring System) 機率評分，自動化 Harbor image 嘅漏洞掃描、風險評分、報告生成、同自動修復。

兩階段 ArgoWorkflow 設計 + Grafana Dashboard 可視化：
1. **Stage 1 (CronWorkflow)**: 每日自動 Trivy scan → EPSS enrichment → 出 report + push metrics → Grafana 顯示
2. **Stage 2 (人工觸發 Workflow)**: 人 review report → import fix-candidates.json → rebuild + verify + push + ArgoCD sync

---

## 架構

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           整體架構                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌────────── Stage 1: DAILY SCAN (CronWorkflow) ───────────────────┐   │
│  │                                                                   │   │
│  │  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────────────┐  │   │
│  │  │ Harbor  │──▶│ Trivy   │──▶│ EPSS    │──▶│ Risk Scorer     │  │   │
│  │  │ List    │   │ Scan    │   │ Enrich  │   │ EPSS×CVSS×ctx   │  │   │
│  │  └─────────┘   └─────────┘   └─────────┘   └───────┬─────────┘  │   │
│  │                                                      │            │   │
│  │                              ┌────────────────────────┼────────┐  │   │
│  │                              ▼                        ▼        │  │   │
│  │                     ┌──────────────┐        ┌──────────────┐   │  │   │
│  │                     │ Report Files │        │   Prometheus  │   │  │   │
│  │                     │ (NFS PVC)    │        │   Pushgateway │   │  │   │
│  │                     │ .md + .json  │        │   (metrics)   │   │  │   │
│  │                     └──────────────┘        └──────┬───────┘   │  │   │
│  │                                                     │           │  │   │
│  │                                             ┌───────▼───────┐   │  │   │
│  │                                             │   Grafana     │   │  │   │
│  │                                             │   Dashboard   │   │  │   │
│  │                                             └───────────────┘   │  │   │
│  └───────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│                       ┌──────────────────────┐                          │
│                       │   Human Review       │                          │
│                       │   ├─ Grafana 睇 dashboard                      │
│                       │   ├─ Report file 睇 details                    │
│                       │   ├─ 標記要修嘅 CVE                             │
│                       │   └─ 生成 fix-candidates.json                  │
│                       └──────────┬───────────┘                          │
│                                  │                                       │
│  ┌────────── Stage 2: AUTO-FIX (Workflow) ─────────────────────────┐   │
│  │                                                                   │   │
│  │  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐         │   │
│  │  │ Import  │──▶│ Build   │──▶│ Trivy   │──▶│ Push    │         │   │
│  │  │ Report  │   │ Kaniko  │   │ Verify  │   │ Harbor  │         │   │
│  │  └─────────┘   └─────────┘   └─────────┘   └────┬────┘         │   │
│  │                                                   │              │   │
│  │                                           ┌───────▼───────┐      │   │
│  │                                           │ ArgoCD Sync   │      │   │
│  │                                           │ 更新 deployment│      │   │
│  │                                           └───────────────┘      │   │
│  └───────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 組件清單

### Stage 1: Scan Report (ArgoWorkflow CronWorkflow)

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-scan | CronWorkflow | argo | 每日凌晨 2 點觸發 |
| epss-scan | WorkflowTemplate | argo | 可重用嘅 scan workflow |
| epss-scan | ServiceAccount | argo | 執行 workflow 嘅 SA |
| epss-scanner | ConfigMap | argo | 配置（Harbor URL、EPSS threshold） |
| epss-scanner | Secret | argo | Harbor credentials |
| epss-reports | PVC | argo | 存放 report（NFS） |
| pushgateway | Deployment | monitoring | Prometheus Pushgateway |
| epss-dashboard | ConfigMap | cattle-monitoring-system | Grafana dashboard JSON |

### Stage 2: Auto-Fix (ArgoWorkflow)

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-auto-fix | WorkflowTemplate | argo | 可重用嘅 fix workflow |
| epss-auto-fix | ServiceAccount | argo | 執行 workflow 嘅 SA |
| kaniko | Secret | argo | Harbor registry credentials |

---

## Phase 1: 安裝 ArgoWorkflows

### 1.1 Namespace + Helm Install
```bash
kubectl create namespace argo

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.enabled=true \
  --set server.ingress.enabled=false \
  --set controller.workflowNamespace=argo \
  --set controller.workflowWorkers=16 \
  --wait
```

### 1.2 Gateway Route (ArgoWorkflows UI)
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

### 1.3 RBAC
```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workflow-role
  namespace: argo
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "secrets", "configmaps", "pvc"]
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
---
# Allow reading Harbor secrets
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workflow-harbor-read
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch", "action"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: workflow-harbor-read-binding
subjects:
  - kind: ServiceAccount
    name: workflow-sa
    namespace: argo
roleRef:
  kind: ClusterRole
  name: workflow-harbor-read
  apiGroup: rbac.authorization.k8s.io
```

---

## Phase 2: Stage 1 — Scan Workflow

### 2.1 ConfigMap + Secret

```yaml
# epss-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: epss-config
  namespace: argo
data:
  HARBOR_URL: "https://ds01-harbor.luban.paulhome.local"
  EPSS_API: "https://api.first.org/data/v1/epss"
  EPSS_THRESHOLD_CRITICAL: "0.7"
  EPSS_THRESHOLD_HIGH: "0.2"
  SCAN_PROJECTS: "dwh,library"
  PROMETHEUS_PUSHGATEWAY: "http://pushgateway.monitoring:9091"
---
# epss-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: epss-secrets
  namespace: argo
type: Opaque
stringData:
  HARBOR_USER: "admin"
  HARBOR_PASSWORD: "<harbor-admin-password>"
```

### 2.2 CronWorkflow (每日自動)

```yaml
# epss-scan-cronworkflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: epss-daily-scan
  namespace: argo
spec:
  schedule: "0 2 * * *"  # 每日凌晨 2 點
  concurrencyPolicy: "Forbid"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  workflowSpec:
    workflowTemplateRef:
      name: epss-scan
    arguments:
      parameters:
        - name: scan-date
          value: "{{workflowstarttime}}"
```

### 2.3 WorkflowTemplate — Stage 1 Scan

```yaml
# epss-scan-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: epss-scan
  namespace: argo
spec:
  entrypoint: scan-pipeline
  arguments:
    parameters:
      - name: scan-date
        value: "latest"

  templates:
    # ─── Main Pipeline ───
    - name: scan-pipeline
      dag:
        tasks:
          - name: list-images
            template: list-harbor-images
          - name: trivy-scan
            template: trivy-scan
            dependencies: [list-images]
            arguments:
              parameters:
                - name: image-list
                  value: "{{tasks.list-images.outputs.result}}"
            withItems:
              # Dynamic — one task per image
          - name: epss-enrich
            template: epss-enrichment
            dependencies: [trivy-scan]
            arguments:
              parameters:
                - name: scan-results
                  value: "{{tasks.trivy-scan.outputs.result}}"
          - name: risk-score
            template: risk-scorer
            dependencies: [epss-enrich]
            arguments:
              parameters:
                - name: enriched-data
                  value: "{{tasks.epss-enrich.outputs.result}}"
          - name: generate-report
            template: report-generator
            dependencies: [risk-score]
            arguments:
              parameters:
                - name: scored-data
                  value: "{{tasks.risk-score.outputs.result}}"
          - name: push-metrics
            template: push-to-prometheus
            dependencies: [risk-score]
            arguments:
              parameters:
                - name: scored-data
                  value: "{{tasks.risk-score.outputs.result}}"

    # ─── Step 1: List Harbor Images ───
    - name: list-harbor-images
      container:
        image: python:3.11-slim
        command: [python, /scripts/list-images.py]
        envFrom:
          - configMapRef:
              name: epss-config
          - secretRef:
              name: epss-secrets
        volumeMounts:
          - name: scripts
            mountPath: /scripts

    # ─── Step 2: Trivy Scan ───
    - name: trivy-scan
      inputs:
        parameters:
          - name: image-list
      container:
        image: python:3.11-slim
        command: [python, /scripts/trivy-scan.py]
        args: ["--images={{inputs.parameters.image-list}}"]
        envFrom:
          - configMapRef:
              name: epss-config
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: scan-results
            mountPath: /workspace/results
      outputs:
        result:
          path: /workspace/results/scan-output.json

    # ─── Step 3: EPSS Enrichment ───
    - name: epss-enrichment
      inputs:
        parameters:
          - name: scan-results
      container:
        image: python:3.11-slim
        command: [python, /scripts/epss-enrich.py]
        args: ["--input={{inputs.parameters.scan-results}}"]
        envFrom:
          - configMapRef:
              name: epss-config
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: scan-results
            mountPath: /workspace/results
      outputs:
        result:
          path: /workspace/results/enriched-output.json

    # ─── Step 4: Risk Scorer ───
    - name: risk-scorer
      inputs:
        parameters:
          - name: enriched-data
      container:
        image: python:3.11-slim
        command: [python, /scripts/risk-scorer.py]
        args: ["--input={{inputs.parameters.enriched-data}}"]
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: scan-results
            mountPath: /workspace/results
      outputs:
        result:
          path: /workspace/results/scored-output.json

    # ─── Step 5: Report Generator ───
    - name: report-generator
      inputs:
        parameters:
          - name: scored-data
      container:
        image: python:3.11-slim
        command: [python, /scripts/report-gen.py]
        args: ["--input={{inputs.parameters.scored-data}}"]
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: scan-results
            mountPath: /workspace/results
          - name: reports
            mountPath: /reports

    # ─── Step 6: Push Metrics to Prometheus ───
    - name: push-to-prometheus
      inputs:
        parameters:
          - name: scored-data
      container:
        image: python:3.11-slim
        command: [python, /scripts/push-metrics.py]
        args: ["--input={{inputs.parameters.scored-data}}"]
        envFrom:
          - configMapRef:
              name: epss-config
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: scan-results
            mountPath: /workspace/results

  # ─── Volumes ───
  volumes:
    - name: scripts
      configMap:
        name: epss-scripts
        defaultMode: 0755
    - name: scan-results
      emptyDir: {}
    - name: reports
      persistentVolumeClaim:
        claimName: epss-reports
```

### 2.4 Scripts

#### list-images.py
```python
#!/usr/bin/env python3
"""列出 Harbor 所有 project 嘅 image"""
import requests, json, os

HARBOR_URL = os.environ['HARBOR_URL']
HARBOR_USER = os.environ['HARBOR_USER']
HARBOR_PASS = os.environ['HARBOR_PASSWORD']
PROJECTS = os.environ.get('SCAN_PROJECTS', 'dwh').split(',')

images = []
for project in PROJECTS:
    repos = requests.get(
        f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories",
        auth=(HARBOR_USER, HARBOR_PASS), verify=False
    ).json()
    for repo in repos:
        repo_name = repo['name']
        artifacts = requests.get(
            f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories/{repo_name}/artifacts",
            auth=(HARBOR_USER, HARBOR_PASS), verify=False,
            params={'page_size': 5, 'with_tag': 'true'}
        ).json()
        for a in artifacts:
            tag = a.get('tags', [{}])[0].get('name', 'latest') if a.get('tags') else 'latest'
            images.append({
                'project': project,
                'repo': repo_name,
                'tag': tag,
                'full': f"{HARBOR_URL.split('//')[1]}/{repo_name}:{tag}"
            })

# Output for next step
with open('/tmp/images.json', 'w') as f:
    json.dump(images, f)
print(json.dumps([i['full'] for i in images]))
```

#### trivy-scan.py
```python
#!/usr/bin/env python3
"""Trivy scan 所有 image"""
import subprocess, json, sys

images = json.loads(sys.argv[1].replace('--images=', ''))
results = []

for img in images:
    try:
        proc = subprocess.run(
            ['trivy', 'image', '--format', 'json',
             '--severity', 'CRITICAL,HIGH,MEDIUM',
             '--scanners', 'vuln', img],
            capture_output=True, text=True, timeout=600
        )
        if proc.returncode in (0, 1):  # 1 = vulnerabilities found
            scan = json.loads(proc.stdout)
            vulns = []
            for r in scan.get('Results', []):
                for v in r.get('Vulnerabilities', []):
                    vulns.append({
                        'cve': v['VulnerabilityID'],
                        'pkg': v['PkgName'],
                        'installed': v.get('InstalledVersion', ''),
                        'fixed': v.get('FixedVersion', ''),
                        'cvss': v.get('CVSS', {}).get('nvd', {}).get('V3Score', 0),
                        'severity': v.get('Severity', 'UNKNOWN')
                    })
            results.append({'image': img, 'vulns': vulns})
    except Exception as e:
        results.append({'image': img, 'error': str(e)})

with open('/tmp/scan-results.json', 'w') as f:
    json.dump(results, f)
print(json.dumps(results))
```

#### epss-enrich.py
```python
#!/usr/bin/env python3
"""EPSS enrichment — 將 CVE list 同 EPSS score 做 join"""
import requests, json, sys, os

EPSS_API = os.environ['EPSS_API']
scan_results = json.loads(sys.argv[1].replace('--input=', ''))

def query_epss_batch(cve_list):
    epss = {}
    for i in range(0, len(cve_list), 50):
        batch = cve_list[i:i+50]
        try:
            resp = requests.get(EPSS_API, params={','.join(batch): ''}, timeout=30)
            # EPSS API format: ?cve=CVE-2024-1234,CVE-2024-5678
            for item in resp.json().get('data', []):
                epss[item['cve']] = {
                    'score': item['epss'],
                    'percentile': item['percentile']
                }
        except:
            pass
    return epss

for result in scan_results:
    cve_ids = [v['cve'] for v in result.get('vulns', [])]
    epss_data = query_epss_batch(cve_ids)
    for vuln in result.get('vulns', []):
        epss = epss_data.get(vuln['cve'], {}).get('score', 0.01)
        vuln['epss'] = epss
        vuln['epss_percentile'] = epss_data.get(vuln['cve'], {}).get('percentile', 0)

with open('/tmp/enriched-results.json', 'w') as f:
    json.dump(scan_results, f)
print(json.dumps(scan_results))
```

#### risk-scorer.py
```python
#!/usr/bin/env python3
"""風險評分 — EPSS × CVSS × Asset Weight"""
import json, sys

data = json.loads(sys.argv[1].replace('--input=', ''))

def classify(score):
    if score >= 0.5: return 'CRITICAL'
    elif score >= 0.2: return 'HIGH'
    elif score >= 0.05: return 'MEDIUM'
    else: return 'LOW'

for result in data:
    for vuln in result.get('vulns', []):
        epss = vuln.get('epss', 0.01)
        cvss = vuln.get('cvss', 0)
        risk = round(epss * (cvss / 10.0), 4)
        vuln['risk_score'] = risk
        vuln['risk_level'] = classify(risk)
    result['summary'] = {
        'total': len(result.get('vulns', [])),
        'critical': sum(1 for v in result.get('vulns', []) if v.get('risk_level') == 'CRITICAL'),
        'high': sum(1 for v in result.get('vulns', []) if v.get('risk_level') == 'HIGH'),
        'medium': sum(1 for v in result.get('vulns', []) if v.get('risk_level') == 'MEDIUM'),
        'low': sum(1 for v in result.get('vulns', []) if v.get('risk_level') == 'LOW'),
    }

with open('/tmp/scored-results.json', 'w') as f:
    json.dump(data, f)
print(json.dumps(data))
```

#### push-metrics.py
```python
#!/usr/bin/env python3
"""Push metrics to Prometheus via Pushgateway"""
import json, sys, os, requests
from datetime import datetime

PUSHGATEWAY = os.environ.get('PROMETHEUS_PUSHGATEWAY', 'http://pushgateway.monitoring:9091')
data = json.loads(sys.argv[1].replace('--input=', ''))

# Build Prometheus metrics
metrics = []
now = datetime.now().strftime('%Y%m%d%H%M%S')

for result in data:
    image = result['image'].replace('/', '_').replace(':', '_')
    summary = result.get('summary', {})

    metrics.append(f'epss_vuln_total{{image="{image}"}} {summary.get("total", 0)}')
    metrics.append(f'epss_vuln_critical{{image="{image}"}} {summary.get("critical", 0)}')
    metrics.append(f'epss_vuln_high{{image="{image}"}} {summary.get("high", 0)}')
    metrics.append(f'epss_vuln_medium{{image="{image}"}} {summary.get("medium", 0)}')
    metrics.append(f'epss_vuln_low{{image="{image}"}} {summary.get("low", 0)}')

    # Top EPSS score per image
    top_epss = max((v.get('epss', 0) for v in result.get('vulns', [])), default=0)
    metrics.append(f'epss_top_score{{image="{image}"}} {top_epss}')

# Global metrics
total_critical = sum(r.get('summary', {}).get('critical', 0) for r in data)
total_high = sum(r.get('summary', {}).get('high', 0) for r in data)
metrics.append(f'epss_global_critical_total {total_critical}')
metrics.append(f'epss_global_high_total {total_high}')
metrics.append(f'epss_images_scanned {len(data)}')

# Push to Pushgateway
body = '\n'.join(metrics) + '\n'
url = f"{PUSHGATEWAY}/metrics/job/epss_scan/instance/{now}"
requests.put(url, data=body, timeout=10)
print(f"Pushed {len(metrics)} metrics to {PUSHGATEWAY}")
```

#### report-gen.py
```python
#!/usr/bin/env python3
"""生成 Markdown + JSON report"""
import json, sys, os
from datetime import datetime
from pathlib import Path

data = json.loads(sys.argv[1].replace('--input=', ''))
today = datetime.now().strftime('%Y-%m-%d')
report_dir = Path(f'/reports/{today}')
report_dir.mkdir(parents=True, exist_ok=True)

# ─── Markdown Report ───
lines = [f"# EPSS Patch Report — {today}\n"]

total_vulns = sum(r.get('summary', {}).get('total', 0) for r in data)
total_crit = sum(r.get('summary', {}).get('critical', 0) for r in data)
total_high = sum(r.get('summary', {}).get('high', 0) for r in data)

lines.append("## Executive Summary\n")
lines.append(f"- Images scanned: **{len(data)}**")
lines.append(f"- Total CVEs: **{total_vulns}**")
lines.append(f"- 🔴 Critical (EPSS >= 0.7): **{total_crit}**")
lines.append(f"- 🟠 High (EPSS 0.2-0.7): **{total_high}**\n")

# Top 10 highest risk
all_vulns = []
for r in data:
    for v in r.get('vulns', []):
        v['image'] = r['image']
        all_vulns.append(v)
top10 = sorted(all_vulns, key=lambda x: x.get('risk_score', 0), reverse=True)[:10]

lines.append("## 🔴 Top 10 Highest Risk\n")
lines.append("| # | CVE | Image | CVSS | EPSS | Risk | Package | Fix |")
lines.append("|---|-----|-------|------|------|------|---------|-----|")
for i, v in enumerate(top10, 1):
    lines.append(
        f"| {i} | {v['cve']} | {v['image'].split('/')[-1]} | "
        f"{v.get('cvss',0)} | {v.get('epss',0):.4f} | "
        f"{v.get('risk_score',0):.4f} | {v['pkg']} | {v.get('fixed', 'N/A')} |"
    )

# Per-image detail
for result in data:
    if not result.get('vulns'):
        continue
    lines.append(f"\n## {result['image']}\n")
    lines.append("| CVE | Package | CVSS | EPSS | Risk | Level | Fix |")
    lines.append("|-----|---------|------|------|------|-------|-----|")
    for v in sorted(result['vulns'], key=lambda x: x.get('risk_score', 0), reverse=True):
        emoji = {'CRITICAL': '🔴', 'HIGH': '🟠', 'MEDIUM': '🟡', 'LOW': '🟢'}
        lines.append(
            f"| {v['cve']} | {v['pkg']} | {v.get('cvss',0)} | "
            f"{v.get('epss',0):.4f} | {v.get('risk_score',0):.4f} | "
            f"{emoji.get(v.get('risk_level',''), '')} {v.get('risk_level','')} | "
            f"{v.get('fixed', 'N/A')} |"
        )

(report_dir / 'report.md').write_text('\n'.join(lines))
(report_dir / 'report.json').write_text(json.dumps(data, indent=2))

# Fix candidates template
fix_candidates = {
    'generated': today,
    'reviewed': False,
    'reviewer': '',
    'approved_fixes': []
}
(report_dir / 'fix-candidates.json').write_text(json.dumps(fix_candidates, indent=2))

print(f"Reports generated: {report_dir}")
```

---

## Phase 3: Grafana Dashboard

### 3.1 Prometheus Pushgateway 安裝

```yaml
# pushgateway.yaml (Helm or raw manifest)
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

### 3.2 Grafana Dashboard ConfigMap

```yaml
# epss-dashboard-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-epss
  namespace: cattle-monitoring-system
  labels:
    grafana_dashboard: "1"  # Rancher Monitoring auto-imports
data:
  epss-patch-dashboard.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "title": "EPSS Patch Pipeline",
      "uid": "epss-patch",
      "tags": ["epss", "security", "harbor"],
      "timezone": "browser",
      "panels": [
        {
          "title": "🔴 Critical CVEs (EPSS >= 0.7)",
          "type": "stat",
          "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
          "targets": [{
            "expr": "sum(epss_vuln_critical)",
            "legendFormat": "Critical"
          }],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "red", "value": 1 }
                ]
              }
            }
          }
        },
        {
          "title": "🟠 High CVEs (EPSS 0.2-0.7)",
          "type": "stat",
          "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 },
          "targets": [{
            "expr": "sum(epss_vuln_high)",
            "legendFormat": "High"
          }],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "orange", "value": 1 }
                ]
              }
            }
          }
        },
        {
          "title": "📊 Images Scanned",
          "type": "stat",
          "gridPos": { "h": 6, "w": 6, "x": 12, "y": 0 },
          "targets": [{
            "expr": "epss_images_scanned",
            "legendFormat": "Images"
          }]
        },
        {
          "title": "📈 Total CVEs by Risk Level",
          "type": "piechart",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
          "targets": [
            { "expr": "sum(epss_vuln_critical)", "legendFormat": "Critical" },
            { "expr": "sum(epss_vuln_high)", "legendFormat": "High" },
            { "expr": "sum(epss_vuln_medium)", "legendFormat": "Medium" },
            { "expr": "sum(epss_vuln_low)", "legendFormat": "Low" }
          ]
        },
        {
          "title": "🖼️ CVEs per Image (Top 10)",
          "type": "barchart",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
          "targets": [{
            "expr": "topk(10, epss_vuln_total)",
            "legendFormat": "{{image}}"
          }]
        },
        {
          "title": "🎯 Top EPSS Scores by Image",
          "type": "bargauge",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 14 },
          "targets": [{
            "expr": "topk(10, epss_top_score)",
            "legendFormat": "{{image}}"
          }],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 0.2 },
                  { "color": "orange", "value": 0.5 },
                  { "color": "red", "value": 0.7 }
                ]
              },
              "max": 1.0
            }
          }
        },
        {
          "title": "📉 Scan History (7 days)",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 22 },
          "targets": [
            { "expr": "epss_global_critical_total", "legendFormat": "Critical" },
            { "expr": "epss_global_high_total", "legendFormat": "High" }
          ]
        }
      ],
      "time": { "from": "now-7d", "to": "now" },
      "refresh": "1h"
    }
```

### 3.3 Grafana Dashboard Layout

```
┌───────────────┬───────────────┬───────────────┬───────────────┐
│  🔴 Critical  │  🟠 High      │  📊 Images    │  📈 Total     │
│     3         │     12        │     6         │     147       │
│   (stat)      │   (stat)      │   (stat)      │   (stat)      │
├───────────────┴───────────────┼───────────────┴───────────────┤
│                               │                               │
│  📈 CVEs by Risk Level        │  🖼️ CVEs per Image (Top 10)  │
│     (piechart)                │     (barchart)                │
│                               │                               │
├───────────────────────────────┴───────────────────────────────┤
│                                                               │
│  🎯 Top EPSS Scores by Image (bargauge)                      │
│  dagster-platform  ████████████████████░░░░  0.92             │
│  comp              █████████████████░░░░░░░  0.85             │
│  cms               ███████████████░░░░░░░░░  0.78             │
│                                                               │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  📉 Scan History (timeseries)                                 │
│  ── Critical ── High ── (over 7 days)                        │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

---

## Phase 4: Stage 2 — Auto-Fix Workflow

### 4.1 WorkflowTemplate — Stage 2 Fix

```yaml
# epss-auto-fix-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: epss-auto-fix
  namespace: argo
spec:
  entrypoint: fix-pipeline
  arguments:
    parameters:
      - name: fix-candidates-path
        description: "Path to fix-candidates.json"
        value: "/reports/latest/fix-candidates.json"
      - name: dry-run
        value: "false"

  templates:
    # ─── Main Pipeline ───
    - name: fix-pipeline
      dag:
        tasks:
          - name: import-report
            template: import-and-validate
          - name: build-images
            template: build-image
            dependencies: [import-report]
            arguments:
              parameters:
                - name: image-config
                  value: "{{tasks.import-report.outputs.parameters.approved}}"
          - name: trivy-verify
            template: trivy-verify
            dependencies: [build-images]
          - name: push-harbor
            template: push-to-harbor
            dependencies: [trivy-verify]
            when: "{{workflow.parameters.dry-run}} == false"
          - name: argocd-sync
            template: sync-deployment
            dependencies: [push-harbor]
            when: "{{workflow.parameters.dry-run}} == false"

    # ─── Step 1: Import & Validate ───
    - name: import-and-validate
      container:
        image: python:3.11-slim
        command: [python, /scripts/validate-fix.py]
        args:
          - "--input={{workflow.parameters.fix-candidates-path}}"
          - "--output=/tmp/approved.json"
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: reports
            mountPath: /reports
      outputs:
        parameters:
          - name: approved
            valueFrom:
              path: /tmp/approved.json

    # ─── Step 2: Build (Kaniko) ───
    - name: build-image
      inputs:
        parameters:
          - name: image-config
      retryStrategy:
        limit: 2
      container:
        image: gcr.io/kaniko-project/executor:v1.23.2
        args:
          - --dockerfile=/workspace/Dockerfile
          - --context=dir:///workspace
          - --destination={{inputs.parameters.image-config}}
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

    # ─── Step 3: Trivy Verify ───
    - name: trivy-verify
      container:
        image: aquasec/trivy:0.58.0
        command: [trivy]
        args:
          - image
          - --exit-code, "1"
          - --severity, CRITICAL,HIGH
          - --ignore-unfixed
          - "{{inputs.parameters.image-config}}"

    # ─── Step 4: Push to Harbor ───
    - name: push-to-harbor
      container:
        image: curlimages/curl:8.5.0
        command: [sh, -c]
        args:
          - |
            # Trigger Harbor scan
            curl -sk -u $HARBOR_USER:$HARBOR_PASS \
              -X POST "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories/$REPO/artifacts/$TAG/scan"
        envFrom:
          - configMapRef:
              name: epss-config
          - secretRef:
              name: epss-secrets

    # ─── Step 5: ArgoCD Sync ───
    - name: sync-deployment
      container:
        image: argoproj/argocd-cli:v2.12.0
        command: [sh, -c]
        args:
          - |
            argocd app sync "$APP_NAME" --force
        env:
          - name: ARGOCD_SERVER
            value: "argocd-server.argocd.svc.cluster.local"

  volumes:
    - name: scripts
      configMap:
        name: epss-fix-scripts
        defaultMode: 0755
    - name: reports
      persistentVolumeClaim:
        claimName: epss-reports
    - name: docker-config
      secret:
        secretName: harbor-registry-creds
    - name: workspace
      emptyDir: {}
```

### 4.2 觸發 Stage 2

```bash
# CLI
argo submit epss-auto-fix \
  --parameter fix-candidates-path=/reports/2026-08-26/fix-candidates.json \
  --parameter dry-run=false

# Web UI
# argo-workflows.luban.paulhome.local → Templates → epss-auto-fix → Submit
```

---

## Phase 5: Notification (可選)

```yaml
# ArgoWorkflow  completed 之後 send notification
- name: notify
  template: send-notification
  dependencies: [argocd-sync]
  container:
    image: curlimages/curl:8.5.0
    command: [sh, -c]
    args:
      - |
        curl -X POST $WEBHOOK_URL \
          -H "Content-Type: application/json" \
          -d '{"text": "EPSS Auto-Fix Complete: $(cat /tmp/summary.json)"}'
```

---

## 時間線

| Phase | 內容 | 預計時間 | 狀態 |
|-------|------|----------|------|
| Phase 1 | 安裝 ArgoWorkflows + RBAC + Gateway | 30 min | ⬜ Pending |
| Phase 2 | Stage 1 — Scan Workflow (CronWorkflow) | 3-4 hr | ⬜ Pending |
| Phase 3 | Grafana Dashboard + Pushgateway | 1-2 hr | ⬜ Pending |
| Phase 4 | Stage 2 — Auto-Fix Workflow | 3-4 hr | ⬜ Pending |
| Phase 5 | Notification | 30 min | ⬜ Pending |
| **Total** | | **~9 hr** | |

---

## 測試計劃

### Stage 1
- [ ] 手動觸發 scan workflow，確認 report 生成
- [ ] 確認 Prometheus metrics 正確 push
- [ ] Grafana dashboard 正確顯示數據
- [ ] CronWorkflow 每日自動觸發

### Stage 2
- [ ] Dry-run 模式，確認 validate 步驟通過
- [ ] 用 dev image 做 full run
- [ ] 確認 ArgoCD sync 正確更新 deployment

### E2E
- [ ] Stage 1 → 人工 review → Stage 2 完整流程
- [ ] 回滾測試

---

## 風險同 Mitigation

| 風險 | Mitigation |
|------|------------|
| EPSS API 限流 | Batch query + retry + backoff |
| Trivy scan 大 image 超時 | Timeout 600s + skip |
| Kaniko build 失敗 | Retry limit 2 + ArgoCD rollback |
| 新 image 引入 bug | Stage 2 先 staging，再 prod |
| Pushgateway 資料遺失 | 定期 backup / 長期存儲 |

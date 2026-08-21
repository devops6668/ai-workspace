# EPSS Patch Pipeline — ArgoWorkflows 方案

## 概覽

利用 EPSS (Exploit Prediction Scoring System) 機率評分，自動化 Harbor image 嘅漏洞掃描、風險評分、報告生成、同自動修復。

兩階段設計：
1. **Stage 1 (自動)**: 每日 Trivy scan → EPSS enrichment → 出 report
2. **Stage 2 (人工觸發)**: 人 review report → import fix-candidates.json → ArgoWorkflow 自動 rebuild + verify + push + ArgoCD sync

---

## 架構

```
┌─────────────────────────────────────────────────────────────────────┐
│                        整體架構                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────── Stage 1: DAILY SCAN (CronJob) ──────────────────┐   │
│  │                                                               │   │
│  │  Harbor ──▶ Trivy Scan ──▶ EPSS Query ──▶ Risk Score ──▶    │   │
│  │                                                 │             │   │
│  │                                          Report Generator     │   │
│  │                                                 │             │   │
│  │                                    ┌────────────▼───────────┐ │   │
│  │                                    │ reports/YYYY-MM-DD/    │ │   │
│  │                                    │  ├── report.md         │ │   │
│  │                                    │  ├── report.json       │ │   │
│  │                                    │  └── raw/              │ │   │
│  │                                    └────────────────────────┘ │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                  │                                   │
│                       ┌──────────▼──────────┐                       │
│                       │   Human Review      │                       │
│                       │   ├─ 睇 report      │                       │
│                       │   ├─ 標記要修嘅 CVE  │                       │
│                       │   └─ 生成 fix.json  │                       │
│                       └──────────┬──────────┘                       │
│                                  │                                   │
│  ┌──────────── Stage 2: AUTO-FIX (ArgoWorkflow) ───────────────┐   │
│  │                                                               │   │
│  │  fix-candidates.json ──▶ Validate ──▶ Build ──▶ Scan ──▶    │   │
│  │                                                    │          │   │
│  │                                              Push to Harbor   │   │
│  │                                                    │          │   │
│  │                                              ArgoCD Sync      │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 組件清單

### Stage 1: Scan Report

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-scanner | CronJob | harbor-sec | 每日凌晨 2 點跑 |
| epss-scanner | ServiceAccount | harbor-sec | 執行掃描嘅 SA |
| epss-scanner | ConfigMap | harbor-sec | 配置（Harbor URL、EPSS threshold） |
| epss-scanner | PVC | harbor-sec | 存放 report 同 scan results |
| reports | NFS PVC | harbor-sec | 長期存放報告（對外可讀） |

### Stage 2: Auto-Fix

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-auto-fix | WorkflowTemplate | argo | 可重用嘅 workflow template |
| epss-auto-fix | ServiceAccount | argo | 執行 workflow 嘅 SA |
| kaniko | Secret | argo | Harbor registry credentials |
| epss-auto-fix | ConfigMap | argo | Harbor URL、ArgoCD app name mapping |
| epss-auto-fix | ServiceAccount | harbor | 推 image 用嘅 SA |

---

## Phase 1: 安裝 ArgoWorkflows

### 1.1 Namespace
```bash
kubectl create namespace argo
```

### 1.2 Helm Install
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.enabled=true \
  --set server.ingress.enabled=true \
  --set server.ingress.host=argo-workflows.luban.paulhome.local \
  --set controller.workflowNamespace=argo \
  --set controller.workflowWorkers=16 \
  --wait
```

### 1.3 RBAC
```yaml
# argo-workflow-rbac.yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: argo
  name: workflow-role
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "secrets", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "cronworkflows"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "taskruns"]
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
# Allow workflow SA to access harbor namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: harbor
  name: workflow-harbor-role
rules:
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list"]
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workflow-harbor-binding
  namespace: harbor
subjects:
  - kind: ServiceAccount
    name: workflow-sa
    namespace: argo
roleRef:
  kind: Role
  name: workflow-harbor-role
  apiGroup: rbac.authorization.k8s.io
```

### 1.4 Gateway Route
```yaml
# ArgoWorkflows UI exposure via Gateway API
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

## Phase 2: Stage 1 — Scan Report Pipeline

### 2.1 ConfigMap
```yaml
# epss-scanner-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: epss-scanner-config
  namespace: harbor-sec
data:
  HARBOR_URL: "https://ds01-harbor.luban.paulhome.local"
  HARBOR_USER: "admin"
  EPSS_API: "https://api.first.org/data/v1/epss"
  EPSS_THRESHOLD_CRITICAL: "0.7"
  EPSS_THRESHOLD_HIGH: "0.2"
  SCAN_PROJECTS: "dwh,library"
  REPORT_DIR: "/reports"
```

### 2.2 Secrets
```yaml
# epss-scanner-secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: epss-scanner-secrets
  namespace: harbor-sec
type: Opaque
stringData:
  HARBOR_PASSWORD: "<harbor-admin-password>"
```

### 2.3 PVC
```yaml
# epss-scanner-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: epss-reports
  namespace: harbor-sec
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 5Gi
```

### 2.4 CronJob
```yaml
# epss-scanner-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: epss-scanner
  namespace: harbor-sec
spec:
  schedule: "0 2 * * *"  # 每日凌晨 2 點
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: epss-scanner
          containers:
            - name: epss-scanner
              image: python:3.11-slim
              command: ["/scripts/scan-and-report.sh"]
              envFrom:
                - configMapRef:
                    name: epss-scanner-config
                - secretRef:
                    name: epss-scanner-secrets
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                - name: reports
                  mountPath: /reports
          volumes:
            - name: scripts
              configMap:
                name: epss-scanner-scripts
                defaultMode: 0755
            - name: reports
              persistentVolumeClaim:
                claimName: epss-reports
          restartPolicy: OnFailure
```

### 2.5 掃描腳本（主要邏輯）

```python
#!/usr/bin/env python3
"""
EPSS Scanner — Stage 1 主要 script
1. 從 Harbor 攞所有 image
2. Trivy scan
3. EPSS enrichment
4. 風險評分
5. 出 report
"""

import requests
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

# Config
HARBOR_URL = os.environ['HARBOR_URL']
HARBOR_USER = os.environ['HARBOR_USER']
HARBOR_PASS = os.environ['HARBOR_PASSWORD']
EPSS_API = os.environ['EPSS_API']
EPSS_CRIT = float(os.environ.get('EPSS_THRESHOLD_CRITICAL', '0.7'))
EPSS_HIGH = float(os.environ.get('EPSS_THRESHOLD_HIGH', '0.2'))
PROJECTS = os.environ.get('SCAN_PROJECTS', 'dwh').split(',')
REPORT_DIR = Path(os.environ.get('REPORT_DIR', '/reports'))

def get_harbor_images():
    """列出所有 project 入面嘅 image"""
    images = []
    for project in PROJECTS:
        resp = requests.get(
            f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories",
            auth=(HARBOR_USER, HARBOR_PASS),
            verify=False
        )
        for repo in resp.json():
            repo_name = repo['name']
            artifacts_resp = requests.get(
                f"{HARBOR_URL}/api/v2.0/projects/{project}/repositories/{repo_name}/artifacts",
                auth=(HARBOR_USER, HARBOR_PASS),
                verify=False,
                params={'page_size': 5}
            )
            for artifact in artifacts_resp.json():
                tag = artifact.get('tags', [{}])[0].get('name', 'latest')
                images.append({
                    'project': project,
                    'repo': repo_name,
                    'tag': tag,
                    'digest': artifact['digest'],
                    'full': f"{HARBOR_URL.split('//')[1]}/{repo_name}:{tag}"
                })
    return images

def trivy_scan(image_ref):
    """Trivy 掃描單個 image"""
    result = subprocess.run(
        ['trivy', 'image', '--format', 'json', '--severity', 'CRITICAL,HIGH,MEDIUM',
         '--scanners', 'vuln', image_ref],
        capture_output=True, text=True, timeout=600
    )
    return json.loads(result.stdout) if result.returncode == 0 else None

def query_epss_batch(cve_list):
    """批量查詢 EPSS score"""
    epss_data = {}
    # EPSS API 支持批量，每次最多 50 個
    for i in range(0, len(cve_list), 50):
        batch = cve_list[i:i+50]
        cve_param = ','.join(batch)
        try:
            resp = requests.get(
                f"{EPSS_API}",
                params={'cve': cve_param},
                timeout=30
            )
            for item in resp.json().get('data', []):
                epss_data[item['cve']] = {
                    'score': item['epss'],
                    'percentile': item['percentile']
                }
        except Exception as e:
            print(f"EPSS query error: {e}")
    return epss_data

def calculate_risk(epss, cvss, asset_weight=1.0):
    """計算 composite risk score"""
    cvss_norm = cvss / 10.0
    return round(epss * cvss_norm * asset_weight, 4)

def classify_risk(risk_score):
    """風險分類"""
    if risk_score >= 0.5:
        return 'CRITICAL'
    elif risk_score >= 0.2:
        return 'HIGH'
    elif risk_score >= 0.05:
        return 'MEDIUM'
    else:
        return 'LOW'

def generate_report(scan_results, report_dir):
    """生成報告"""
    today = datetime.now().strftime('%Y-%m-%d')
    report_path = report_dir / today
    report_path.mkdir(parents=True, exist_ok=True)

    # Markdown report
    md_lines = [
        f"# EPSS Patch Report — {today}\n",
        "## Executive Summary\n",
    ]

    total_cves = sum(len(r['vulns']) for r in scan_results)
    critical = sum(1 for r in scan_results for v in r['vulns'] if v['risk_level'] == 'CRITICAL')
    high = sum(1 for r in scan_results for v in r['vulns'] if v['risk_level'] == 'HIGH')

    md_lines.append(f"- Total images scanned: {len(scan_results)}")
    md_lines.append(f"- Total CVEs found: {total_cves}")
    md_lines.append(f"- 🔴 Critical (EPSS >= 0.7): {critical}")
    md_lines.append(f"- 🟠 High (EPSS 0.2-0.7): {high}\n")

    # Per-image breakdown
    for result in scan_results:
        md_lines.append(f"\n## {result['image']}\n")
        md_lines.append("| CVE | Package | CVSS | EPSS | Risk | Fix Available |")
        md_lines.append("|-----|---------|------|------|------|---------------|")
        for v in sorted(result['vulns'], key=lambda x: x['risk_score'], reverse=True):
            emoji = {'CRITICAL': '🔴', 'HIGH': '🟠', 'MEDIUM': '🟡', 'LOW': '🟢'}
            md_lines.append(
                f"| {v['cve']} | {v['package']} | {v['cvss']} | "
                f"{v['epss']:.4f} | {emoji.get(v['risk_level'], '')} {v['risk_level']} | "
                f"{v.get('fixed_version', 'N/A')} |"
            )

    # Write markdown
    (report_path / 'report.md').write_text('\n'.join(md_lines))

    # Write JSON
    (report_path / 'report.json').write_text(json.dumps(scan_results, indent=2))

    # Write fix candidates (auto-generated, for human review)
    fix_candidates = {
        'generated': today,
        'auto_suggested': [
            {
                'image': r['full'],
                'repo': r['repo'],
                'cves': [v['cve'] for v in r['vulns'] if v['risk_level'] == 'CRITICAL'],
                'all_critical_high': [
                    {'cve': v['cve'], 'epss': v['epss'], 'cvss': v['cvss'],
                     'risk_score': v['risk_score'], 'fixed_version': v.get('fixed_version')}
                    for v in r['vulns'] if v['risk_level'] in ('CRITICAL', 'HIGH')
                ]
            }
            for r in scan_results
            if any(v['risk_level'] in ('CRITICAL', 'HIGH') for v in r['vulns'])
        ],
        'approved_fixes': []  # 人工填
    }
    (report_path / 'fix-candidates.json').write_text(
        json.dumps(fix_candidates, indent=2)
    )

    return report_path

def main():
    print(f"[{datetime.now()}] Starting EPSS scan...")
    images = get_harbor_images()
    print(f"Found {len(images)} images to scan")

    scan_results = []
    for img in images:
        print(f"Scanning {img['full']}...")
        scan = trivy_scan(img['full'])
        if not scan:
            continue

        # Extract CVEs
        cve_list = []
        for result in scan.get('Results', []):
            for vuln in result.get('Vulnerabilities', []):
                cve_list.append({
                    'cve': vuln['VulnerabilityID'],
                    'package': vuln['PkgName'],
                    'installed': vuln.get('InstalledVersion', ''),
                    'fixed': vuln.get('FixedVersion', ''),
                    'cvss': vuln.get('CVSS', {}).get('nvd', {}).get('V3Score',
                           vuln.get('Severity', 'UNKNOWN')),
                    'severity': vuln.get('Severity', 'UNKNOWN')
                })

        if not cve_list:
            continue

        # EPSS enrichment
        cve_ids = [v['cve'] for v in cve_list]
        epss_data = query_epss_batch(cve_ids)

        # Risk scoring
        for vuln in cve_list:
            epss = epss_data.get(vuln['cve'], {}).get('score', 0.01)
            vuln['epss'] = epss
            vuln['risk_score'] = calculate_risk(epss, vuln['cvss'])
            vuln['risk_level'] = classify_risk(vuln['risk_score'])
            vuln['fixed_version'] = vuln['fixed']

        scan_results.append({
            'image': img['full'],
            'project': img['project'],
            'repo': img['repo'],
            'tag': img['tag'],
            'digest': img['digest'],
            'vulns': cve_list,
            'scan_time': datetime.now().isoformat()
        })

    # Generate report
    report_path = generate_report(scan_results, REPORT_DIR)
    print(f"Report generated: {report_path}")
    print(f"  - report.md")
    print(f"  - report.json")
    print(f"  - fix-candidates.json")

if __name__ == '__main__':
    main()
```

---

## Phase 3: Stage 2 — ArgoWorkflow Auto-Fix

### 3.1 WorkflowTemplate

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
        description: "Path to fix-candidates.json in shared PVC"
        value: "/reports/2026-08-26/fix-candidates.json"
      - name: dry-run
        description: "If true, only validate without pushing"
        value: "false"

  templates:
    # ─── Main Pipeline ───
    - name: fix-pipeline
      dag:
        tasks:
          - name: import-and-validate
            template: import-validate
          - name: build-images
            template: build-image
            dependencies: [import-and-validate]
            arguments:
              parameters:
                - name: image-name
                  value: "{{tasks.import-and-validate.outputs.parameters.approved-images}}"
            withItems:
              # Dynamic list from import-validate output
          - name: trivy-verify
            template: trivy-verify
            dependencies: [build-images]
            arguments:
              parameters:
                - name: new-image
                  value: "{{tasks.build-images.outputs.parameters.built-image}}"
          - name: push-to-harbor
            template: push-harbor
            dependencies: [trivy-verify]
            when: "{{workflow.parameters.dry-run}} == false"
            arguments:
              parameters:
                - name: image
                  value: "{{tasks.build-images.outputs.parameters.built-image}}"
          - name: sync-argocd
            template: sync-app
            dependencies: [push-to-harbor]
            when: "{{workflow.parameters.dry-run}} == false"

    # ─── Step 1: Import & Validate ───
    - name: import-validate
      inputs:
        parameters:
          - name: fix-candidates-path
      container:
        image: python:3.11-slim
        command: [python, /scripts/validate-fix-candidates.py]
        args:
          - "--input={{inputs.parameters.fix-candidates-path}}"
          - "--output=/tmp/approved.json"
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: reports
            mountPath: /reports
      outputs:
        parameters:
          - name: approved-images
            valueFrom:
              path: /tmp/approved.json

    # ─── Step 2: Build Image (Kaniko) ───
    - name: build-image
      inputs:
        parameters:
          - name: image-name
          - name: dockerfile-content
      retryStrategy:
        limit: 2
      container:
        image: gcr.io/kaniko-project/executor:v1.23.2
        args:
          - --dockerfile=/workspace/Dockerfile
          - --context=dir:///workspace
          - --destination={{inputs.parameters.image-name}}
          - --cache=true
          - --cache-repo=harbor.paulhome.local/cache
          - --snapshot-mode=redo
        env:
          - name: DOCKER_CONFIG
            value: /kaniko/.docker
        volumeMounts:
          - name: docker-config
            mountPath: /kaniko/.docker
            readOnly: true
          - name: workspace
            mountPath: /workspace
      outputs:
        parameters:
          - name: built-image
            value: "{{inputs.parameters.image-name}}"

    # ─── Step 3: Trivy Verify ───
    - name: trivy-verify
      inputs:
        parameters:
          - name: new-image
      container:
        image: aquasec/trivy:0.58.0
        command: [trivy]
        args:
          - image
          - --exit-code
          - "1"
          - --severity
          - CRITICAL,HIGH
          - --ignore-unfixed
          - "{{inputs.parameters.new-image}}"

    # ─── Step 4: Push to Harbor ───
    - name: push-harbor
      inputs:
        parameters:
          - name: image
      container:
        image: curlimages/curl:8.5.0
        command: [sh, -c]
        args:
          - |
            # Trigger Harbor scan on pushed image
            curl -sk -u $HARBOR_USER:$HARBOR_PASS \
              -X POST "$HARBOR_URL/api/v2.0/projects/$(echo $IMAGE | cut -d/ -f2)/repositories/$(echo $IMAGE | cut -d/ -f1,2)/artifacts/$(echo $IMAGE | cut -d: -f2)/scan"
        env:
          - name: IMAGE
            value: "{{inputs.parameters.image}}"
          - name: HARBOR_URL
            valueFrom:
              configMapKeyRef:
                name: epss-scanner-config
                key: HARBOR_URL
          - name: HARBOR_USER
            valueFrom:
              secretKeyRef:
                name: epss-scanner-secrets
                key: HARBOR_USER
          - name: HARBOR_PASS
            valueFrom:
              secretKeyRef:
                name: epss-scanner-secrets
                key: HARBOR_PASSWORD

    # ─── Step 5: ArgoCD Sync ───
    - name: sync-app
      container:
        image: argoproj/argocd-cli:v2.12.0
        command: [sh, -c]
        args:
          - |
            # Sync all apps that use the rebuilt images
            for app in $(cat /tmp/approved.json | python3 -c "import sys,json; [print(a['argocd_app']) for a in json.load(sys.stdin) if a.get('argocd_app')]"); do
              argocd app sync "$app" --force
            done
        env:
          - name: ARGOCD_SERVER
            value: "argocd-server.argocd.svc.cluster.local"
          - name: ARGOCD_AUTH_TOKEN
            valueFrom:
              secretKeyRef:
                name: argo-workflows-server-sso
                key: admin.password
                optional: true

  # ─── Volume Definitions ───
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

### 3.2 觸發 Workflow

```bash
# 方式一：Argo CLI
argo submit epss-auto-fix \
  --parameter fix-candidates-path=/reports/2026-08-26/fix-candidates.json \
  --parameter dry-run=false \
  -n argo

# 方式二：HTTP API
curl -X POST argo-workflows.luban.paulhome.local/api/v1/workflows/argo/epss-auto-fix \
  -H "Content-Type: application/json" \
  -d '{
    "arguments": {
      "parameters": [
        {"name": "fix-candidates-path", "value": "/reports/2026-08-26/fix-candidates.json"},
        {"name": "dry-run", "value": "false"}
      ]
    }
  }'

# 方式三：Web UI
# Browser → argo-workflows.luban.paulhome.local
# → Templates → epss-auto-fix → Submit
```

---

## Phase 4: 整合 ArgoCD

### 4.1 Report 做為 ArgoCD Application

```yaml
# reports-app.yaml (讓 ArgoCD 管理 report 產生嘅 deployment update)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: epss-patch-reports
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/devops6668/paul-ai-worksapce
    targetRevision: main
    path: k8s-ctl-deploy/epss-patch
  destination:
    server: https://kubernetes.default.svc
    namespace: harbor-sec
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 4.2 Image Update Automation (可選)

```yaml
# ArgoCD Image Updater — 自動更新 image tag
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-image-updater-config
  namespace: argocd
data:
  registries.conf: |
    registries:
      - name: harbor
        api_url: https://ds01-harbor.luban.paulhome.local
        credentials: pullsecret:argocd/harbor-creds
        default: true
```

---

## Phase 5: Notification (可選)

### 5.1 Email Notification

```yaml
# epss-notify-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: epss-notify
  namespace: harbor-sec
spec:
  schedule: "0 8 * * *"  # 每日朝早 8 點 send report
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: notify
              image: curlimages/curl:8.5.0
              command: [sh, -c]
              args:
                - |
                  # Send report via email/Slack/WhatsApp
                  curl -X POST https://hooks.slack.com/services/xxx \
                    -d '{"text": "EPSS Report: $(cat /reports/$(date +%Y-%m-%d)/report.md | head -20)"}'
          volumes:
            - name: reports
              persistentVolumeClaim:
                claimName: epss-reports
```

---

## 時間線

| Phase | 內容 | 預計時間 | 狀態 |
|-------|------|----------|------|
| Phase 1 | 安裝 ArgoWorkflows | 30 min | ⬜ Pending |
| Phase 2 | Stage 1 — Scan Report | 2-3 hr | ⬜ Pending |
| Phase 3 | Stage 2 — ArgoWorkflow Auto-Fix | 3-4 hr | ⬜ Pending |
| Phase 4 | ArgoCD 整合 | 1 hr | ⬜ Pending |
| Phase 5 | Notification | 30 min | ⬜ Pending |
| **Total** | | **~8 hr** | |

---

## 測試計劃

### Unit Test
- [ ] EPSS API 批量查詢正確性
- [ ] Risk score 計算邏輯
- [ ] Report 格式生成

### Integration Test
- [ ] Stage 1: CronJob 跑一次，確認 report 生成
- [ ] Stage 2: Dry-run workflow，確認 validate 步驟通過
- [ ] Stage 2: Full run（用 dev image），確認 rebuild + push + scan

### E2E Test
- [ ] 整個 pipeline 從 scan 到 ArgoCD sync
- [ ] 回滾測試（如果新 image 有問題）

---

## 風險同 Mitigation

| 風險 | 影響 | Mitigation |
|------|------|------------|
| EPSS API 限流 | 批量查詢失敗 | 加 retry + exponential backoff |
| Trivy scan 大 image 超時 | 掃描失敗 | 設 timeout + skip large images |
| Kaniko build 失敗 | Image 冇修到 | ArgoCD 自動 rollback |
| 新 image 引入新 bug | Production 影響 | Stage 2 先跑 staging，確認後再 prod |
| ArgoWorkflow pod 資源不足 | Workflow 卡住 | 設 resource limits + PriorityClass |

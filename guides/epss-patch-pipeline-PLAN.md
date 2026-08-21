# EPSS Patch Pipeline — 全自動方案 (v4)

## Table of Contents

- [概覽](#概覽)
- [架構](#架構)
- [兩層 Patch 策略](#兩層-patch-策略)
- [組件](#組件)
- [Phase 1: 安裝 ArgoWorkflows](#phase-1-安裝-argoworkflows)
- [Phase 2: Config + Secrets](#phase-2-config--secrets)
- [Phase 3: WorkflowTemplate — Layer 1 (ClusterStack Rebase)](#phase-3-workflowtemplate--layer-1-clusterstack-rebase)
- [Phase 4: scan-and-identify.py](#phase-4-scan-and-identifypy)
- [Phase 5: Grafana Dashboards](#phase-5-grafana-dashboards)
  - [Dashboard 1: Security Posture](#dashboard-1-security-posture-cvss-vs-epss-全覽)
  - [Dashboard 2: Auto-Patch Pipeline](#dashboard-2-auto-patch-pipeline)
- [Phase 6: WorkflowTemplate — Stack Rebuild (Auto)](#phase-6-workflowtemplate--stack-rebuild-auto)
- [CronWorkflow](#cronworkflow)
- [完整 Flow](#完整-flow)
- [時間線](#時間線)

---

## 概覽

EPSS 機率評分 + Luban CI flow，分兩層自動修復 Harbor image 漏洞。

```
Layer 1: ClusterStack (base OS CVE)
  CronWorkflow → EPSS scan → EPSS >= 0.7 (base OS) →
  Update ClusterStack → kpack rebase → Rollout restart

Layer 2: Application dep CVE
  Dashboard 顯示 → Developer update dependencies →
  git commit → Luban CI auto rebuild → ArgoCD sync
```

---

## 架構

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌─── Layer 1: ClusterStack Rebase (全自動) ─────────────────┐ │
│  │                                                            │ │
│  │  CronWorkflow (每日 02:00)                                 │ │
│  │  ┌─────────┐   ┌─────────┐   ┌─────────┐                  │ │
│  │  │ Harbor  │──▶│ Trivy   │──▶│ EPSS    │                  │ │
│  │  │ List    │   │ Scan    │   │ Enrich  │                  │ │
│  │  └─────────┘   └─────────┘   └────┬────┘                  │ │
│  │                                    │                        │ │
│  │  Filter: Base OS CVE + EPSS >= 0.7│                        │ │
│  │                                    │                        │ │
│  │  ┌─────────────────────────────────▼──────────────────┐    │ │
│  │  │ Update ClusterStack                               │    │ │
│  │  │   build image: harbor.luban.paulhome.local/...     │    │ │
│  │  │   run image:   harbor.luban.paulhome.local/...     │    │ │
│  │  └─────────────────────────────────┬──────────────────┘    │ │
│  │                                    │                        │ │
│  │  ┌─────────────────────────────────▼──────────────────┐    │ │
│  │  │ kpack rebase all images                            │    │ │
│  │  │   → 所有 image 自動用新版 base                      │    │ │
│  │  └─────────────────────────────────┬──────────────────┘    │ │
│  │                                    │                        │ │
│  │  ┌─────────────────────────────────▼──────────────────┐    │ │
│  │  │ Rollout restart → pods 重新 pull 新版           │    │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌─── Layer 2: Application dep (Developer 處理) ──────────────┐ │
│  │                                                            │ │
│  │  ┌──────────────────────────────────────────────────────┐  │ │
│  │  │ Dashboard 顯示 EPSS >= 0.7 嘅 application dep CVE    │  │ │
│  │  └──────────────────────┬───────────────────────────────┘  │ │
│  │                         │                                   │ │
│  │  Developer 睇 Dashboard，update dependencies              │ │
│  │                         │                                   │ │
│  │  ┌──────────────────────▼───────────────────────────────┐  │ │
│  │  │ git commit (update requirements.txt / pyproject.toml)│  │ │
│  │  └──────────────────────┬───────────────────────────────┘  │ │
│  │                         │                                   │ │
│  │  ┌──────────────────────▼───────────────────────────────┐  │ │
│  │  │ Luban CI auto rebuild → Push Harbor → GitOps update  │  │ │
│  │  └──────────────────────┬───────────────────────────────┘  │ │
│  │                         │                                   │ │
│  │  ┌──────────────────────▼───────────────────────────────┐  │ │
│  │  │ ArgoCD auto-sync → Sandbox (snd-*)                   │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 兩層 Patch 策略

### Layer 1: ClusterStack (Base OS)

```
ClusterStack 控制：
├── build image  → builder 用嘅 base
├── run image    → 最終 image 用嘅 base
└── store        → buildpacks 存放

更新 ClusterStack = 更新 base OS packages
  → kpack rebase 所有 images
  → 所有 image 自動用新版 base
  → 一次更新，全部受益
```

```
ClusterStack 更新流程：

EPSS >= 0.7 (base OS CVE)
    ↓
Update ClusterStack
  ├── build image: harbor.luban.paulhome.local/luban-ci/build:latest
  └── run image:   harbor.luban.paulhome.local/luban-ci/run:latest
    ↓
kpack rebase 所有 affected images
    ↓
All images enjoy 新 base OS
    ↓
Rollout restart → pods 重新 pull 新版
```

### Layer 2: Application Dependencies

```
Application dep 控制：
├── requirements.txt (Python)
├── pyproject.toml (Python)
├── package.json (Node)
└── go.mod (Go)

Developer 更新 dependencies = 修 application CVE
  → git commit → Luban CI auto rebuild
  → 新 image 用新版 dependencies
```

```
Application dep 更新流程：

Developer 睇 Dashboard
    ↓
發現 EPSS >= 0.7 嘅 application CVE
    ↓
Update dependencies
  ├── pip install --upgrade requests
  ├── 或 edit requirements.txt
  └── 或 edit pyproject.toml
    ↓
git commit + push
    ↓
Luban CI auto rebuild
    ↓
Push Harbor → GitOps update
    ↓
ArgoCD sync → Sandbox
```

### 兩層對比

```
                Layer 1: ClusterStack        Layer 2: Application
─────────────────────────────────────────────────────────────────
控制對象        Base OS packages             App dependencies
更新方式        Update ClusterStack          Update source code
觸發 EPSS       EPSS pipeline auto          Developer 睇 Dashboard
Build 方式      kpack rebase (快)            kpack rebuild (慢)
影響範圍        所有 image                   單個 image
自動程度        全自動                       Developer 手動
```

---

## 組件

| 組件 | 類型 | Namespace | 說明 |
|------|------|-----------|------|
| epss-auto-patch | CronWorkflow | argo | 每日凌晨 2 點，Layer 1 全自動 |
| epss-auto-patch | WorkflowTemplate | argo | Layer 1 workflow |
| stack-rebuild | CronWorkflow | argo | 每 6 小時 check upstream |
| stack-rebuild | WorkflowTemplate | argo | Stack rebuild workflow |
| epss-config | ConfigMap | argo | Harbor URL、EPSS API、ClusterStack config |
| epss-secrets | Secret | argo | Harbor credentials |
| epss-stack-digest | ConfigMap | argo | Last known upstream digest |
| workflow-sa | ServiceAccount | argo | 執行 workflow |
| pushgateway | Deployment | monitoring | Prometheus Pushgateway |
| epss-dashboard-security | ConfigMap | cattle-monitoring-system | Dashboard 1: Security Posture |
| epss-dashboard-pipeline | ConfigMap | cattle-monitoring-system | Dashboard 2: Auto-Patch Pipeline |

---

## Phase 1: 安裝 ArgoWorkflows

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

### RBAC

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
  - apiGroups: ["kpack.io"]
    resources: ["images", "builds", "clusterstacks"]
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
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workflow-kpack-role
  namespace: luban-ci
rules:
  - apiGroups: ["kpack.io"]
    resources: ["images", "builds", "clusterstacks"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workflow-kpack-binding
  namespace: luban-ci
subjects:
  - kind: ServiceAccount
    name: workflow-sa
    namespace: argo
roleRef:
  kind: Role
  name: workflow-kpack-role
  apiGroup: rbac.authorization.k8s.io
```

### Gateway Route

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

## Phase 2: Config + Secrets

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
  CLUSTERSTACK_NAME: "luban-stack"
  CLUSTERSTACK_NAMESPACE: "luban-ci"
  BUILD_IMAGE: "harbor.luban.paulhome.local/luban-ci/build:latest"
  RUN_IMAGE: "harbor.luban.paulhome.local/luban-ci/run:latest"
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

---

## Phase 3: WorkflowTemplate — Layer 1 (ClusterStack Rebase)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: epss-auto-patch
  namespace: argo
spec:
  entrypoint: auto-patch-pipeline

  templates:
    # ─── Main Pipeline ───
    - name: auto-patch-pipeline
      dag:
        tasks:
          - name: scan
            template: epss-scan
          - name: identify-base-cve
            template: identify-base-os-cve
            dependencies: [scan]
          - name: update-stack
            template: update-clusterstack
            dependencies: [identify-base-cve]
          - name: rebase-images
            template: kpack-rebase-all
            dependencies: [update-stack]

    # ─── Step 1: Scan ───
    - name: epss-scan
      container:
        image: python:3.11-slim
        command: [python, /scripts/scan-and-identify.py]
        envFrom:
          - configMapRef:
              name: epss-config
          - secretRef:
              name: epss-secrets
        volumeMounts:
          - name: scripts
            mountPath: /scripts
          - name: workdir
            mountPath: /workspace

    # ─── Step 2: Identify Base OS CVE ───
    - name: identify-base-os-cve
      container:
        image: python:3.11-slim
        command: [python, /scripts/identify-base-cve.py]
        volumeMounts:
          - name: workdir
            mountPath: /workspace

    # ─── Step 3: Update ClusterStack ───
    - name: update-clusterstack
      container:
        image: bitnami/kubectl:latest
        command: [sh, -c]
        args:
          - |
            # Update ClusterStack with new build/run images
            cat <<EOF | kubectl apply -f -
            apiVersion: kpack.io/v1alpha1
            kind: ClusterStack
            metadata:
              name: $STACK_NAME
            spec:
              id: io.buildpacks.stacks.jammy
              store:
                name: luban-store
                kind: ClusterStore
              buildImage:
                image: $BUILD_IMAGE
              runImage:
                image: $RUN_IMAGE
            EOF
            echo "ClusterStack updated: $STACK_NAME"
        env:
          - name: STACK_NAME
            valueFrom:
              configMapKeyRef:
                name: epss-config
                key: CLUSTERSTACK_NAME
          - name: BUILD_IMAGE
            valueFrom:
              configMapKeyRef:
                name: epss-config
                key: BUILD_IMAGE
          - name: RUN_IMAGE
            valueFrom:
              configMapKeyRef:
                name: epss-config
                key: RUN_IMAGE

    # ─── Step 4: kpack Rebase All Images ───
    - name: kpack-rebase-all
      container:
        image: bitnami/kubectl:latest
        command: [sh, -c]
        args:
          - |
            # Get all images in luban-ci namespace
            IMAGES=$(kubectl get images -n luban-ci -o jsonpath='{.items[*].metadata.name}')

            for IMAGE in $IMAGES; do
              echo "Rebasing $IMAGE..."
              # Trigger rebase by annotating the image
              kubectl annotate image $IMAGE \
                -n luban-ci \
                kpack.io/force-rebase="true" \
                --overwrite
              echo "Rebase triggered for $IMAGE"
            done

            echo "All images rebased with new ClusterStack"
        env:
          - name: STACK_NAME
            valueFrom:
              configMapKeyRef:
                name: epss-config
                key: CLUSTERSTACK_NAME

  volumes:
    - name: scripts
      configMap:
        name: epss-scripts
        defaultMode: 0755
    - name: workdir
      emptyDir: {}
```

---

## Phase 4: scan-and-identify.py

```python
#!/usr/bin/env python3
"""
EPSS Scan + Identify — Layer 1 (Base OS CVE)
1. Scan all Harbor images
2. EPSS enrich
3. Identify base OS CVEs with EPSS >= 0.7
4. Push metrics to Prometheus
"""
import requests, json, os, subprocess, time
from datetime import datetime

HARBOR_URL = os.environ['HARBOR_URL']
HARBOR_USER = os.environ['HARBOR_USER']
HARBOR_PASS = os.environ['HARBOR_PASSWORD']
EPSS_API = os.environ['EPSS_API']
PUSHGATEWAY = os.environ.get('PROMETHEUS_PUSHGATEWAY', '')
SCAN_PROJECTS = os.environ.get('SCAN_PROJECTS', 'dwh').split(',')
EPSS_THRESHOLD = 0.7

# Base OS packages (typically vulnerable)
BASE_OS_PACKAGES = [
    'openssl', 'libssl', 'curl', 'libcurl', 'wget',
    'linux-libc', 'libc6', 'libgcrypt', 'gnutls',
    'zlib', 'libpng', 'libjpeg', 'libtiff',
    'openssh', 'openssh-server', 'openssh-client',
    'python3', 'python3-pip', 'nodejs', 'npm',
    'bash', 'coreutils', 'systemd', 'dbus',
    'krb5', 'libkrb5', 'samba', 'smbclient',
    'nss', 'nspr', 'libxml2', 'libxslt',
    'apt', 'dpkg', 'rpm', 'yum'
]

def list_images():
    images = []
    for project in SCAN_PROJECTS:
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
                        'installed': v.get('InstalledVersion', ''),
                        'fixed': v.get('FixedVersion', ''),
                        'cvss': v.get('CVSS', {}).get('nvd', {}).get('V3Score', 0),
                        'is_base_os': v['PkgName'] in BASE_OS_PACKAGES
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
                epss[item['cve']] = item['epss']
        except:
            pass
        time.sleep(0.5)
    return epss

def push_metrics(results, base_os_rebuild_list):
    if not PUSHGATEWAY:
        return
    lines = []
    ts = datetime.now().strftime('%Y%m%d%H%M%S')

    for r in results:
        img = r['image'].replace('/', '_').replace(':', '_')
        base_os_cves = [v for v in r.get('vulns', []) if v.get('is_base_os') and v.get('epss', 0) >= EPSS_THRESHOLD]
        app_cves = [v for v in r.get('vulns', []) if not v.get('is_base_os') and v.get('epss', 0) >= EPSS_THRESHOLD]

        lines.append(f'epss_image_base_os_cve{{image="{r["image"]}"}} {len(base_os_cves)}')
        lines.append(f'epss_image_app_cve{{image="{r["image"]}"}} {len(app_cves)}')
        lines.append(f'epss_image_epss_max{{image="{r["image"]}"}} {r.get("max_epss", 0)}')

    total_base_os = sum(1 for r in results for v in r.get('vulns', []) if v.get('is_base_os') and v.get('epss', 0) >= EPSS_THRESHOLD)
    total_app = sum(1 for r in results for v in r.get('vulns', []) if not v.get('is_base_os') and v.get('epss', 0) >= EPSS_THRESHOLD)
    lines.append(f'epss_global_base_os_critical {total_base_os}')
    lines.append(f'epss_global_app_critical {total_app}')
    lines.append(f'epss_images_scanned {len(results)}')
    lines.append(f'epss_images_rebase {len(base_os_rebuild_list)}')

    body = '\n'.join(lines) + '\n'
    url = f"{PUSHGATEWAY}/metrics/job/epss_scan/instance/{ts}"
    requests.put(url, data=body, timeout=10)

def main():
    print(f"[{datetime.now()}] Starting EPSS scan...")
    images = list_images()
    print(f"Found {len(images)} images")

    results = []
    base_os_rebuild_list = []

    for img in images:
        print(f"Scanning {img['full']}...")
        vulns = trivy_scan(img['full'])
        if not vulns:
            continue

        cve_ids = [v['cve'] for v in vulns]
        epss_data = query_epss(cve_ids)

        for v in vulns:
            v['epss'] = epss_data.get(v['cve'], 0.01)

        epss_scores = [v['epss'] for v in vulns]
        max_epss = max(epss_scores) if epss_scores else 0

        # Identify base OS CVEs with EPSS >= threshold
        base_os_critical = [v for v in vulns if v['is_base_os'] and v['epss'] >= EPSS_THRESHOLD]
        app_critical = [v for v in vulns if not v['is_base_os'] and v['epss'] >= EPSS_THRESHOLD]

        results.append({
            'image': img['full'],
            'project': img['project'],
            'repo': img['repo'],
            'vulns': vulns,
            'total_vulns': len(vulns),
            'max_epss': max_epss,
            'base_os_critical': base_os_critical,
            'app_critical': app_critical
        })

        if base_os_critical:
            base_os_rebuild_list.append({
                'image': img['repo'],
                'base_os_cves': [v['cve'] for v in base_os_critical]
            })

    # Push metrics
    push_metrics(results, base_os_rebuild_list)

    # Summary
    print(f"\n{'='*60}")
    print(f"Scan complete: {len(results)} images scanned")
    print(f"Base OS CVEs (EPSS >= {EPSS_THRESHOLD}): {len(base_os_rebuild_list)} images")
    print(f"{'='*60}")

    # Save lists
    with open('/workspace/base-os-rebuild-list.json', 'w') as f:
        json.dump(base_os_rebuild_list, f, indent=2)

if __name__ == '__main__':
    main()
```

---

## Phase 5: Grafana Dashboards

### Dashboard 1: Security Posture (CVSS vs EPSS 全覽)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-epss-security
  namespace: cattle-monitoring-system
  labels:
    grafana_dashboard: "1"
data:
  epss-security-posture.json: |
    {
      "uid": "epss-security-posture",
      "title": "EPSS Security Posture — All Images",
      "tags": ["epss", "security", "cvss"],
      "panels": [
        {
          "title": "📊 Image Security Overview",
          "description": "每行一個 Image，顯示最高 CVSS 同 EPSS",
          "type": "table",
          "gridPos": { "h": 12, "w": 24, "x": 0, "y": 0 },
          "targets": [
            {
              "expr": "epss_image_cvss_max",
              "legendFormat": "{{image}}",
              "format": "table",
              "instant": true
            },
            {
              "expr": "epss_image_epss_max",
              "legendFormat": "{{image}}",
              "format": "table",
              "instant": true
            },
            {
              "expr": "epss_image_base_os_cve",
              "legendFormat": "{{image}}",
              "format": "table",
              "instant": true
            },
            {
              "expr": "epss_image_app_cve",
              "legendFormat": "{{image}}",
              "format": "table",
              "instant": true
            }
          ],
          "transformations": [
            { "id": "merge", "config": {} },
            {
              "id": "organize",
              "config": {
                "excludeByName": { "Time": true, "__name__": true },
                "renameByName": {
                  "image": "Image",
                  "Value": "Score"
                }
              }
            }
          ]
        },
        {
          "title": "🔴 Base OS CVE (EPSS >= 0.7) — ClusterStack Rebase",
          "type": "table",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
          "targets": [{
            "expr": "epss_image_base_os_cve",
            "format": "table",
            "instant": true
          }],
          "transformations": [
            {
              "id": "filterByValue",
              "options": {
                "conditions": [{
                  "fieldName": "Value",
                  "operator": { "gte": 1 },
                  "type": "number"
                }]
              }
            }
          ],
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
          "title": "🟡 Application CVE (EPSS >= 0.7) — Developer 要 Update",
          "type": "table",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
          "targets": [{
            "expr": "epss_image_app_cve",
            "format": "table",
            "instant": true
          }],
          "transformations": [
            {
              "id": "filterByValue",
              "options": {
                "conditions": [{
                  "fieldName": "Value",
                  "operator": { "gte": 1 },
                  "type": "number"
                }]
              }
            }
          ],
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
          "title": "📈 Scan History (7 days)",
          "type": "timeseries",
          "gridPos": { "h": 6, "w": 24, "x": 0, "y": 20 },
          "targets": [
            { "expr": "epss_global_base_os_critical", "legendFormat": "Base OS CVE" },
            { "expr": "epss_global_app_critical", "legendFormat": "Application CVE" },
            { "expr": "epss_images_scanned", "legendFormat": "Images Scanned" }
          ]
        }
      ],
      "time": { "from": "now-7d", "to": "now" },
      "refresh": "1h"
    }
```

### Dashboard 1 Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  📊 Image Security Overview (Table)                             │
├─────────────────────────────────────────────────────────────────┤
│ Image                  │ Max EPSS │ Base OS │ App    │ Status  │
│ dwh/dagster-platform   │ 0.92     │ 3       │ 2      │ 🔴 AUTO │
│ dwh/comp               │ 0.85     │ 2       │ 1      │ 🔴 AUTO │
│ dwh/cms                │ 0.78     │ 1       │ 0      │ 🟡 DEV  │
│ dwh/ewallet            │ 0.45     │ 0       │ 0      │ 🟢 OK   │
└─────────────────────────────────────────────────────────────────┘

┌───────────────────────────┬───────────────────────────────────┐
│ 🔴 Base OS CVE            │ 🟡 Application CVE                │
│ (ClusterStack Rebase)    │ (Developer Update)                │
├───────────────────────────┼───────────────────────────────────┤
│ Image        │ CVEs       │ Image        │ CVEs              │
│ dagster      │ 3          │ dagster      │ 2                 │
│ comp         │ 2          │ comp         │ 1                 │
│ cms          │ 1          │              │                   │
└───────────────────────────┴───────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 📉 Scan History (7 days)                                        │
│ ── Base OS CVE ── Application CVE ── Images Scanned ──         │
└─────────────────────────────────────────────────────────────────┘
```

### Dashboard 2: Auto-Patch Pipeline

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-epss-pipeline
  namespace: cattle-monitoring-system
  labels:
    grafana_dashboard: "1"
data:
  epss-auto-patch.json: |
    {
      "uid": "epss-auto-patch",
      "title": "EPSS Auto-Patch Pipeline (Layer 1: ClusterStack Rebase)",
      "tags": ["epss", "security", "pipeline"],
      "panels": [
        {
          "title": "🔄 Images Rebased",
          "type": "stat",
          "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
          "targets": [{
            "expr": "epss_images_rebase",
            "legendFormat": "Rebased"
          }]
        },
        {
          "title": "🔴 Base OS Critical CVEs",
          "type": "stat",
          "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 },
          "targets": [{
            "expr": "epss_global_base_os_critical",
            "legendFormat": "Base OS"
          }]
        },
        {
          "title": "📊 Images Scanned",
          "type": "stat",
          "gridPos": { "h": 6, "w": 8, "x": 16, "y": 0 },
          "targets": [{
            "expr": "epss_images_scanned",
            "legendFormat": "Scanned"
          }]
        },
        {
          "title": "📈 Scan History",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 6 },
          "targets": [
            { "expr": "epss_global_base_os_critical", "legendFormat": "Base OS CVE" },
            { "expr": "epss_images_scanned", "legendFormat": "Scanned" },
            { "expr": "epss_images_rebase", "legendFormat": "Rebased" }
          ]
        }
      ],
      "time": { "from": "now-7d", "to": "now" },
      "refresh": "1h"
    }
```

---

## Phase 6: WorkflowTemplate — Stack Rebuild (Auto)

### 概覽

當 Amazon Linux 2023 有 security update 時，自動 rebuild stack images (base, run, build) 並 push 到本地 Harbor。

```
CronWorkflow (每 6 小時 check)
    ↓
Check upstream digest 有冇變
    ├── 有變 → Rebuild stack images → Push Harbor → Update ClusterStack → kpack rebase
    └── 冇變 → Skip
```

### 架構

```
┌─────────────────────────────────────────────────────────────────┐
│  Stack Rebuild CronWorkflow (每 6 小時)                          │
│                                                                 │
│  Step 1: Check upstream digest                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ docker manifest inspect public.ecr.aws/.../amazonlinux    │  │
│  │ 比較 current digest vs last known digest                   │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│              ┌───────────┴───────────┐                          │
│              │ Digest changed?       │                          │
│              │ Yes → Continue        │                          │
│              │ No  → Skip            │                          │
│              └───────────┬───────────┘                          │
│                          │                                      │
│  Step 2: Build stack images (Kaniko)                            │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ 2a. Build base image                                     │  │
│  │     FROM public.ecr.aws/.../amazonlinux:2023-minimal     │  │
│  │     + dnf upgrade + shadow-utils + ca-certificates        │  │
│  │     → harbor.../luban-ci/luban-base:al2023               │  │
│  │                                                          │  │
│  │ 2b. Build run image                                      │  │
│  │     FROM harbor.../luban-ci/luban-base:al2023            │  │
│  │     + USER cnb                                           │  │
│  │     → harbor.../luban-ci/luban-run:al2023                │  │
│  │                                                          │  │
│  │ 2c. Build build image                                    │  │
│  │     FROM harbor.../luban-ci/luban-base:al2023            │  │
│  │     + git, gcc, make, openssl-devel, etc.                │  │
│  │     → harbor.../luban-ci/luban-build:al2023              │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│  Step 3: Update ClusterStack                                    │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ kubectl patch clusterstack luban-stack                   │  │
│  │   buildImage: harbor.../luban-build:al2023               │  │
│  │   runImage: harbor.../luban-run:al2023                   │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│  Step 4: kpack rebase all images                                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ kubectl annotate image ... kpack.io/force-rebase=true    │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│  Step 5: Rollout restart all snd-* deployments                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ imagePullPolicy: Always → pods 重新 pull 新版             │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### WorkflowTemplate

```yaml
# stack-rebuild-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: stack-rebuild
  namespace: argo
spec:
  entrypoint: stack-rebuild-pipeline

  templates:
    - name: stack-rebuild-pipeline
      dag:
        tasks:
          - name: check-upstream
            template: check-upstream-digest
          - name: build-base
            template: build-image
            dependencies: [check-upstream]
            arguments:
              parameters:
                - name: image-name
                  value: "harbor.luban.paulhome.local/luban-ci/luban-base:al2023"
                - name: dockerfile-path
                  value: "/workspace/stack/base/Dockerfile"
          - name: build-run
            template: build-image
            dependencies: [build-base]
            arguments:
              parameters:
                - name: image-name
                  value: "harbor.luban.paulhome.local/luban-ci/luban-run:al2023"
                - name: dockerfile-path
                  value: "/workspace/stack/run/Dockerfile"
          - name: build-build
            template: build-image
            dependencies: [build-base]
            arguments:
              parameters:
                - name: image-name
                  value: "harbor.luban.paulhome.local/luban-ci/luban-build:al2023"
                - name: dockerfile-path
                  value: "/workspace/stack/build/Dockerfile"
          - name: update-clusterstack
            template: update-clusterstack
            dependencies: [build-run, build-build]
          - name: rebase-images
            template: kpack-rebase-all
            dependencies: [update-clusterstack]
          - name: restart-pods
            template: rollout-restart
            dependencies: [rebase-images]

    # ─── Step 1: Check Upstream Digest ───
    - name: check-upstream-digest
      container:
        image: python:3.11-slim
        command: [python, /scripts/check-upstream.py]
        envFrom:
          - configMapRef:
              name: epss-config
        volumeMounts:
          - name: scripts
            mountPath: /scripts

    # ─── Step 2: Build Image (Kaniko) ───
    - name: build-image
      inputs:
        parameters:
          - name: image-name
          - name: dockerfile-path
      retryStrategy:
        limit: 2
      container:
        image: gcr.io/kaniko-project/executor:v1.23.2
        args:
          - --dockerfile={{inputs.parameters.dockerfile-path}}
          - --context=dir:///workspace/luban-ci
          - --destination={{inputs.parameters.image-name}}
          - --cache=true
          - --cache-repo=harbor.luban.paulhome.local/cache
        env:
          - name: DOCKER_CONFIG
            value: /kaniko/.docker
        volumeMounts:
          - name: docker-config
            mountPath: /kaniko/.docker
            readOnly: true
          - name: workspace
            mountPath: /workspace/luban-ci

    # ─── Step 3: Update ClusterStack ───
    - name: update-clusterstack
      container:
        image: bitnami/kubectl:latest
        command: [sh, -c]
        args:
          - |
            kubectl patch clusterstack luban-stack --type=merge -p='{
              "spec": {
                "buildImage": {
                  "image": "harbor.luban.paulhome.local/luban-ci/luban-build:al2023"
                },
                "runImage": {
                  "image": "harbor.luban.paulhome.local/luban-ci/luban-run:al2023"
                }
              }
            }'
            echo "ClusterStack updated"

    # ─── Step 4: kpack Rebase All Images ───
    - name: kpack-rebase-all
      container:
        image: bitnami/kubectl:latest
        command: [sh, -c]
        args:
          - |
            IMAGES=$(kubectl get images -n luban-ci -o jsonpath='{.items[*].metadata.name}')
            for IMAGE in $IMAGES; do
              echo "Rebasing $IMAGE..."
              kubectl annotate image $IMAGE \
                -n luban-ci \
                kpack.io/force-rebase="true" \
                --overwrite
            done
            echo "All images rebased"

    # ─── Step 5: Rollout Restart All snd-* Deployments ───
    - name: rollout-restart
      container:
        image: bitnami/kubectl:latest
        command: [sh, -c]
        args:
          - |
            # Get all snd-* namespaces
            NAMESPACES=$(kubectl get ns -o name | grep snd- | cut -d/ -f2)

            for NS in $NAMESPACES; do
              echo "Restarting deployments in $NS..."
              DEPLOYMENTS=$(kubectl get deployments -n $NS -o name 2>/dev/null)
              for DEPLOY in $DEPLOYMENTS; do
                echo "  Restarting $DEPLOY..."
                kubectl rollout restart $DEPLOY -n $NS
              done
            done

            # Wait for rollout to complete
            echo "Waiting for rollouts to complete..."
            for NS in $NAMESPACES; do
              DEPLOYMENTS=$(kubectl get deployments -n $NS -o name 2>/dev/null)
              for DEPLOY in $DEPLOYMENTS; do
                kubectl rollout status $DEPLOY -n $NS --timeout=300s
              done
            done

            echo "All deployments restarted with new base image"

  volumes:
    - name: scripts
      configMap:
        name: stack-rebuild-scripts
        defaultMode: 0755
    - name: docker-config
      secret:
        secretName: harbor-registry-creds
    - name: workspace
      emptyDir: {}
```

### check-upstream.py

```python
#!/usr/bin/env python3
"""
Check if upstream Amazon Linux 2023 has been updated.
Compare digest with last known digest stored in ConfigMap.
"""
import requests, json, os, subprocess, sys

UPSTREAM_IMAGE = "public.ecr.aws/amazonlinux/amazonlinux:2023-minimal"
HARBOR_URL = os.environ.get('HARBOR_URL', 'https://ds01-harbor.luban.paulhome.local')
LAST_DIGEST_CM = "epss-stack-digest"

def get_upstream_digest():
    """Get current upstream image digest"""
    try:
        result = subprocess.run(
            ['docker', 'manifest', 'inspect', UPSTREAM_IMAGE],
            capture_output=True, text=True, timeout=30
        )
        data = json.loads(result.stdout)
        return data.get('config', {}).get('digest', '')
    except:
        # Fallback: use crane or skopeo
        try:
            result = subprocess.run(
                ['crane', 'digest', UPSTREAM_IMAGE],
                capture_output=True, text=True, timeout=30
            )
            return result.stdout.strip()
        except:
            return None

def get_last_digest():
    """Get last known digest from ConfigMap"""
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'configmap', LAST_DIGEST_CM,
             '-n', 'argo', '-o', 'jsonpath={.data.digest}'],
            capture_output=True, text=True, timeout=10
        )
        return result.stdout.strip()
    except:
        return None

def save_digest(digest):
    """Save current digest to ConfigMap"""
    yaml = f"""
apiVersion: v1
kind: ConfigMap
metadata:
  name: {LAST_DIGEST_CM}
  namespace: argo
data:
  digest: "{digest}"
"""
    subprocess.run(
        ['kubectl', 'apply', '-f', '-'],
        input=yaml, text=True, timeout=10
    )

def main():
    print(f"Checking upstream: {UPSTREAM_IMAGE}")

    current_digest = get_upstream_digest()
    if not current_digest:
        print("ERROR: Could not fetch upstream digest")
        sys.exit(1)

    last_digest = get_last_digest()
    print(f"Current:  {current_digest}")
    print(f"Last:     {last_digest}")

    if current_digest != last_digest:
        print("UPDATE AVAILABLE — triggering rebuild")
        save_digest(current_digest)
        sys.exit(0)  # Continue workflow
    else:
        print("NO UPDATE — skipping rebuild")
        sys.exit(1)  # Skip workflow (will show as "Failed" but that's OK)

if __name__ == '__main__':
    main()
```

### Stack Rebuild CronWorkflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: stack-rebuild-check
  namespace: argo
spec:
  schedule: "0 */6 * * *"  # 每 6 小時 check
  concurrencyPolicy: "Forbid"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  workflowSpec:
    workflowTemplateRef:
      name: stack-rebuild
```

### Stack Rebuild Flow

```
每 6 小時 (自動)
    │
    ▼
┌─────────────────────────────────────────────────────┐
│ Step 1: Check upstream digest                       │
│   Amazon Linux 2023 digest 有冇變？                  │
└─────────────────────┬───────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          │ Changed?              │
          │ Yes → Continue        │
          │ No  → Skip            │
          └───────────┬───────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Step 2: Build stack images (Kaniko)                 │
│   2a. Build base image (FROM amazonlinux:2023)      │
│   2b. Build run image (FROM base + USER cnb)        │
│   2c. Build build image (FROM base + build deps)    │
│   → Push to Harbor (luban-ci/luban-base|run|build)  │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Step 3: Update ClusterStack                         │
│   buildImage: harbor.../luban-build:al2023          │
│   runImage: harbor.../luban-run:al2023              │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Step 4: kpack rebase all images                     │
│   所有 image latest 用新版 base                      │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Step 5: Rollout restart all snd-* deployments       │
│   imagePullPolicy: Always → pods 重新 pull 新版     │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Step 6: Verify                                      │
│   kubectl describe pod | grep Image                 │
│   確認 pods 用緊新版 base                            │
└─────────────────────────────────────────────────────┘
```

**注意：** `imagePullPolicy: Always` 確保 restart 時 pull 最新版，冇 cache 問題。

---

## CronWorkflow

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: epss-daily-auto-patch
  namespace: argo
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: "Forbid"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3
  workflowSpec:
    workflowTemplateRef:
      name: epss-auto-patch
```

---

## 完整 Flow

```
每日 02:00 (自動)
    │
    ▼
┌─────────────────────────────────────────────────────┐
│ Layer 1: ClusterStack Rebase (全自動)               │
│                                                     │
│ Step 1: Scan                                        │
│   Harbor → Trivy → EPSS                             │
│                                                     │
│ Step 2: Identify Base OS CVE                        │
│   EPSS >= 0.7 + is_base_os = true                   │
│                                                     │
│ Step 3: Update ClusterStack                         │
│   build image + run image                           │
│                                                     │
│ Step 4: kpack rebase all images                     │
│   所有 image latest 用新版 base                      │
│                                                     │
│ Step 5: Rollout restart all snd-* deployments       │
│   imagePullPolicy: Always → pods 重新 pull 新版     │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│ Layer 2: Application dep (Developer 處理)            │
│                                                     │
│ Dashboard 顯示 EPSS >= 0.7 嘅 application CVE       │
│     ↓                                               │
│ Developer update dependencies                       │
│     ↓                                               │
│ git commit → Luban CI auto rebuild                  │
│     ↓                                               │
│ ArgoCD sync → Sandbox                               │
└─────────────────────────────────────────────────────┘
                      │
                      ▼
              Grafana Dashboard
              顯示兩層嘅 scan + rebuild 結果
```

---

## 時間線

| Phase | 內容 | 預計時間 |
|-------|------|----------|
| Phase 1 | 安裝 ArgoWorkflows | 30 min |
| Phase 2 | Config + Secrets | 15 min |
| Phase 3 | WorkflowTemplate (Layer 1) | 2 hr |
| Phase 4 | scan-and-identify.py | 1 hr |
| Phase 5 | Grafana Dashboards (2 個) | 1 hr |
| Phase 6 | Stack Rebuild Workflow | 2 hr |
| **Total** | | **~6.5 hr** |

# k8s-ctl-deploy — Tekton Pipeline 部署方案

## 概覽

將 `k8s-ctl-deploy.sh` 封裝成 Tekton Task，配合 Tekton Dashboard 讓團隊自助操作 namespace 生命週期（stop/start/status/stop-deploy/start-deploy/clean），唔使 SSH 上機。

---

## 架構

```
方式一：Tekton Dashboard UI (recommended)
Browser → tekton.luban.paulhome.local → Tekton Dashboard
  → Pipelines → k8s-ctl-pipeline → Create → 填參數 → Start
  → k8s-ctl-eventlistener Task (curl to EventListener)
    → EventListener (devops:8080)
    → Trigger (filter X-K8sCtl-Event: run)
    → TriggerTemplate → TaskRun (serviceAccountName: pipeline-runner)
      → k8s-ctl Task (inline script)
  → State files → PVC (/workspace/state)

方式二：直接 call EventListener (從 pod 內部)
curl → el-k8s-ctl-eventlistener.devops:8080
  → Trigger → TriggerTemplate → TaskRun (pipeline-runner SA)
  → k8s-ctl Task (inline script)
```

Namespace: `devops`（Task, Pipeline, PVC, EventListener 全部喺 devops）
ServiceAccount: `pipeline-runner`
Gateway: luban-gateway (Envoy), hostname: tekton.luban.paulhome.local
EventListener: http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080

---

## 組件

| 組件 | 名稱 | Namespace | 說明 |
|------|------|-----------|------|
| Task | k8s-ctl | devops | 主要執行腳本（inline script） |
| Task | k8s-ctl-eventlistener | devops | Wrapper — call EventListener 建 TaskRun |
| Pipeline | k8s-ctl-pipeline | devops | Dashboard 入口 → call k8s-ctl-eventlistener |
| PVC | k8s-ctl-state | devops | State files persistent storage |
| TriggerTemplate | k8s-ctl-trigger-template | devops | 建 TaskRun（指定 pipeline-runner SA） |
| Trigger | k8s-ctl-trigger | devops | Filter header X-K8sCtl-Event: run |
| EventListener | k8s-ctl-eventlistener | devops | HTTP endpoint :8080 |
| SA | pipeline-runner | devops | 有齊 k8s-ctl + Triggers RBAC |

---

## Phase 1: 安裝 Tekton Pipelines + Dashboard ✅

### 已安裝版本

| Component          | Version  | 安裝日期       |
|--------------------|----------|----------------|
| Tekton Pipelines   | v1.6.0   | 2026-08-18     |
| Tekton Dashboard   | v0.63.1  | 2026-08-18     |

### 安裝步驟

```bash
# 1. Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# 2. Tekton Dashboard
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# 3. 驗證
kubectl -n tekton-pipelines get pods
kubectl get crd tasks.tekton.dev
```

### PodSecurity 調整

Tekton 內部 `prepare` init container 需要 root 權限，但 `tekton-pipelines` namespace 預設 `enforce=restricted`。
已改為 `enforce=baseline`（允許大部分容器）+ `audit/warn=restricted`（記錄違規但唔 block）：

```bash
kubectl label ns tekton-pipelines pod-security.kubernetes.io/enforce-  # 移除 restricted
kubectl label ns tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### 安裝資源

| Component            | CPU        | Memory     |
|----------------------|------------|------------|
| pipelines-controller | 200-500m   | 256Mi-512Mi |
| pipelines-webhook    | 50-100m    | 128Mi      |
| dashboard            | 50-100m    | 128Mi      |

---

## Phase 2: 修改 k8s-ctl-deploy.sh ✅

只改一行，加 K8S_CTL_STATE_DIR 環境變數：

```bash
# 改前:
state_file() { echo "/tmp/${1}-state.json"; }

# 改後:
state_file() { echo "${K8S_CTL_STATE_DIR:-/tmp}/${1}-state.json"; }
```

Tekton Task 設 `K8S_CTL_STATE_DIR=/workspace/state`，PVC mount 到 /workspace/state，
腳本自動用 PVC 嘅路徑，本地執行時依然用 /tmp（向後兼容）。

---

## Phase 3: Dockerfile + Image Build + Push ✅

### Dockerfile

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 ca-certificates curl && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/kubectl && \
    apt-get upgrade -y && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY k8s-ctl-deploy.sh /usr/local/bin/k8s-ctl-deploy.sh
RUN chmod +x /usr/local/bin/k8s-ctl-deploy.sh

# Non-root user (required by PodSecurity)
RUN useradd -u 1001 -m appuser
USER 1001
```

### 為什麼用 debian:bookworm-slim 而唔係 bitnami/kubectl?

bitnami/kubectl 係 distroless base，冇 apk/apt-get — 無法安裝 python3。
改用 debian:bookworm-slim 自裝 kubectl (官方 binary) + python3。

### Build & Push

```bash
# 從 repo root build
docker build -f k8s-ctl-deploy/Dockerfile \
  -t harbor.luban.paulhome.local/otel-poc/k8s-ctl-deploy:latest .

docker push harbor.luban.paulhome.local/otel-poc/k8s-ctl-deploy:latest
```

> **注意:** harbor 入面 `k8s-ctl` project 未建立，暫時用 `otel-poc` project。
> 要建立 `k8s-ctl` project 的話，去 Harbor UI → Projects → New Project。

### Image 資訊

- Registry: harbor.luban.paulhome.local/otel-poc/k8s-ctl-deploy:latest
- Base: debian:bookworm-slim
- kubectl: 最新 stable (從 dl.k8s.io 安裝)
- python3: Debian bookworm 內建
- 用戶: appuser (UID 1001, non-root)

---

## Phase 4: RBAC + Tekton Task + PVC ✅

### 4.1 ServiceAccount + RBAC (tekton/rbac.yaml)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: k8s-ctl-sa
  namespace: tekton-pipelines
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-ctl-role
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "delete"]
  - apiGroups: ["argoproj.io"]
    resources: ["applications", "applications/status"]
    verbs: ["get", "list", "patch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-ctl-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: k8s-ctl-role
subjects:
  - kind: ServiceAccount
    name: k8s-ctl-sa
    namespace: tekton-pipelines
```

### 4.2 Tekton Task (tekton/task.yaml)

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: k8s-ctl
  namespace: tekton-pipelines
  labels:
    app.kubernetes.io/part-of: k8s-ctl-deploy
spec:
  description: >
    Namespace lifecycle controller — stop/start/status/deploy operations
    for snd-*/prd-* namespaces with ArgoCD sync-policy control.
  params:
    - name: action
      type: string
      description: "Command: start | stop | status | stop-deploy | start-deploy | restart | clean"
    - name: target
      type: string
      description: "Namespace name or prefix (e.g., snd-dwh, snd, all)"
    - name: deploy-name
      type: string
      default: ""
      description: "Deployment name (required for stop-deploy / start-deploy only)"
    - name: replicas
      type: string
      default: "1"
      description: "Replica count for start-deploy (default: 1)"
  workspaces:
    - name: state
      mountPath: /workspace/state
      optional: false
  steps:
    - name: k8s-ctl
      image: harbor.luban.paulhome.local/otel-poc/k8s-ctl-deploy:latest
      env:
        - name: K8S_CTL_STATE_DIR
          value: /workspace/state
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
      command:
        - /bin/bash
      args:
        - -euo
        - pipefail
        - -c
        - |
          ACTION="$(params.action)"
          TARGET="$(params.target)"
          DEPLOY="$(params.deploy-name)"
          REPLICAS="$(params.replicas)"

          echo "=== k8s-ctl-deploy ==="
          echo "action:    $ACTION"
          echo "target:    $TARGET"
          echo "deploy:    $DEPLOY"
          echo "replicas:  $REPLICAS"
          echo "======================"

          case "$ACTION" in
            stop-deploy|start-deploy)
              if [[ -z "$DEPLOY" ]]; then
                echo "ERROR: deploy-name is required for $ACTION"
                exit 1
              fi
              /usr/local/bin/k8s-ctl-deploy.sh "$ACTION" "$DEPLOY" "$TARGET" "$REPLICAS"
              ;;
            start|stop|status|clean)
              /usr/local/bin/k8s-ctl-deploy.sh "$ACTION" "$TARGET"
              ;;
            *)
              echo "ERROR: unknown action '$ACTION'"
              echo "Valid: start, stop, status, stop-deploy, start-deploy, clean"
              exit 1
              ;;
          esac
```

> **注意:** Tekton v1 Task 唔支持 step 級 `resources` (CPU/memory limits)，
> 亦唔支持 `podTemplate` (只限 TaskRun)。PodSecurity 透過 namespace label 處理。

### 4.3 Pipeline (tekton/pipeline.yaml)

將 Task 封裝成 Pipeline，令 Tekton Dashboard 可以直接由 UI 啟動：

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: k8s-ctl-pipeline
  namespace: tekton-pipelines
  labels:
    app.kubernetes.io/part-of: k8s-ctl-deploy
spec:
  description: >
    Namespace lifecycle pipeline — stop/start/status/deploy operations
    for snd-*/prd-* namespaces with ArgoCD sync-policy control.
  params:
    - name: action
      type: string
      description: "Command: start | stop | status | stop-deploy | start-deploy | restart | clean"
    - name: target
      type: string
      description: "Namespace name or prefix (e.g., snd-dwh, snd, all)"
    - name: deploy-name
      type: string
      default: ""
      description: "Deployment name (required for stop-deploy / start-deploy only)"
    - name: replicas
      type: string
      default: "1"
      description: "Replica count for start-deploy (default: 1)"
  workspaces:
    - name: state
  tasks:
    - name: run-k8s-ctl
      taskRef:
        name: k8s-ctl
        kind: Task
      params:
        - name: action
          value: $(params.action)
        - name: target
          value: $(params.target)
        - name: deploy-name
          value: $(params.deploy-name)
        - name: replicas
          value: $(params.replicas)
      workspaces:
        - name: state
          workspace: state
```

> Pipeline 只係 thin wrapper，所有邏輯都喺 Task 入面。
> 將來可以加 pre-check / post-check steps（例如 stop 前先 check 有冇 running pods）。

### 4.4 PVC for State Persistence (tekton/pvc.yaml)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: k8s-ctl-state
  namespace: tekton-pipelines
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Mi
```

---

## Phase 5: HTTPRoute — expose Tekton Dashboard ✅

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  parentRefs:
    - name: luban-gateway
      namespace: gateway
      sectionName: luban-local
    - name: luban-gateway
      namespace: gateway
      sectionName: luban-public
  hostnames:
    - "tekton.luban.paulhome.local"
  rules:
    - backendRefs:
        - name: tekton-dashboard
          port: 9097
      matches:
        - path:
            type: PathPrefix
            value: /
```

DNS: `*.luban.paulhome.local` 已經 wildcard 指向 luban-gateway (192.168.48.111)。

瀏覽器: `https://tekton.luban.paulhome.local`

> **注意:** 初始設定時 `parentRefs` 錯用 `namespace: default`，導致 HTTPRoute 冇被 Gateway 接受（404）。
> 正確嘅 Gateway 喺 `gateway` namespace，需要指定 `sectionName` (luban-local / luban-public)。

---

## 團隊使用流程

### 用 Dashboard

1. 開瀏覽器 → `tekton.luban.paulhome.local`
2. 左邊 Tasks → 選 `k8s-ctl`
3. 右上角 `Start` → 填參數:
   - action: `status`
   - target: `snd-dwh`
4. 按 Run → 即時睇 TaskRun logs
5. 之後想 stop/start: 再 run，action 換成 `stop` / `start`

### 用 CLI (tkn)

```bash
tkn task start k8s-ctl \
  --param action=status \
  --param target=snd-dwh \
  --workspace name=state,pvc=k8s-ctl-state
```

---

## 參數速查

| action        | target | deploy-name | replicas | 說明                                    |
|---------------|--------|-------------|----------|----------------------------------------|
| stop          | ns     | -           | -        | 停晒成個 NS (snd: autosync off + scale 0) |
| start         | ns     | -           | -        | 開返成個 NS (prd: scale 1; snd: autosync on) |
| status        | ns     | -           | -        | 顯示 NS 狀態                            |
| stop-deploy   | ns     | deploy名    | -        | 停一個 deployment (snd: 只熄 owning app autosync) |
| start-deploy  | ns     | deploy名    | 1        | 開一個 deployment (只 scale, 唔掂 autosync) |
| restart       | ns     | -           | -        | Rollout restart 所有 Deployments/StatefulSets/DaemonSets |
| clean         | ns     | -           | -        | 清理 Succeeded/Failed pods              |

---

## 實際安裝順序 (已完成)

```
Phase 1  裝 Tekton Pipelines v1.6.0 + Dashboard v0.63.1   ✅
Phase 2  改 k8s-ctl-deploy.sh (state_file env var)         ✅
Phase 3  打 image (debian + kubectl + python3) + push      ✅
         → harbor.luban.paulhome.local/otel-poc/k8s-ctl-deploy:latest
Phase 4  RBAC + Task + PVC                                 ✅
Phase 5  HTTPRoute → tekton.luban.paulhome.local            ✅
Phase 6  EventListener + TriggerTemplate + devops NS       ✅
```

### Live 驗證

TaskRun `status snd-dwh` → **Succeeded** ✓
- Pod: prepare + step-k8s-ctl both Running
- Output: 完整 snd-dwh status (deployments + argocd apps)
- Image pull: harbor.luban.paulhome.local 正常
- RBAC: pipeline-runner 能操作 namespaces, deployments, argoproj.io applications
- EventListener: curl → 202 → TaskRun created with serviceAccountName: pipeline-runner ✓
- Dashboard: k8s-ctl-pipeline → k8s-ctl-eventlistener → EventListener → TaskRun (pipeline-runner) ✓

### EventListener API 用法

```bash
# Status
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"status","target":"snd-dwh"}'

# Stop
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"stop","target":"snd-dwh"}'

# Start
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"start","target":"snd-dwh"}'

# Stop single deployment
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"stop-deploy","target":"snd-dwh","deploy-name":"ewallet"}'

# Start single deployment
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"start-deploy","target":"snd-dwh","deploy-name":"ewallet","replicas":"1"}'

# Rollout restart all in namespace
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"restart","target":"snd-dwh"}'
```

---

## 注意事項

- Tekton TaskRun pod 係 ephemeral，state files 靠 PVC persist
- 每次 TaskRun 完結後 pod 刪除，但 PVC 入面嘅 state files 保留
- 如果 PVC 已經有某個 ns 嘅 state file，下次 stop 會覆蓋
- snd-* stop 會 disable ArgoCD autosync (patch Application CR)，想還原用 start ns
- prd-* 完全唔掂 ArgoCD，只管理 replicas
- PodSecurity: enforce=baseline (Tekton prepare container 需要) + audit/warn=restricted
- Image: debian:bookworm-slim (唔係 bitnami/kubectl — distroless base 冇 package manager)
- Harbor project: 暫用 otel-poc，要建 k8s-ctl project 去 Harbor UI
- DNS: tekton.luban.paulhome.local 已經通（wildcard *.luban.paulhome.local）
- TriggerTemplate 必須 create TaskRun（唔係 PipelineRun）— 否則會 infinite loop
  (PipelineRun → wrapper Task → EventListener → PipelineRun → ...)

---

# Mesh Demo — stop-crash-deployment Pipeline

## Overview

Auto-detect and stop crash-looping deployments via Tekton Pipeline + Triggers.

## Architecture

```
Tekton UI → Pipeline → Wrapper Task (curl) → EventListener
→ Trigger (CEL filter) → TriggerTemplate → TaskRun (pipeline-runner SA) → Task
```

## Resources (NS: devops)

| Resource | Name | Description |
|----------|------|-------------|
| Task | stop-crash-deployment-task | Core logic: scan pods, stop crash deployment |
| Task | stop-crash-eventlistener | Wrapper: curl to EventListener, wait for TaskRun |
| Pipeline | stop-crash-deployment-pipeline | Pipeline for Tekton UI |
| Trigger | stop-crash-trigger | CEL interceptor: filter X-StopCrash-Event: run |
| TriggerTemplate | stop-crash-trigger-template | Creates TaskRun with pipeline-runner SA |
| EventListener | stop-crash-eventlistener | Webhook endpoint |

## Parameters

| Param | Type | Description |
|-------|------|-------------|
| namespace | string | Target namespace (e.g. snd-demo3) |
| restart-count | string | Restart threshold (e.g. 3) |

## Usage

### From Tekton UI
1. Open Tekton Dashboard
2. Select Pipeline: `stop-crash-deployment-pipeline`
3. Click "Create"
4. Enter params:
   - namespace: snd-demo3
   - restart-count: 3
5. Click "Create Run"

### From curl
```bash
curl -X POST http://el-stop-crash-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-StopCrash-Event: run" \
  -d '{"namespace":"snd-demo3","restart-count":"3"}'
```

## Task Logic (stop-crash-deployment-task)

```
1. Get all deployments in namespace
2. For each deployment:
   a. Get pods via label selector
   b. Check restart count of each pod
   c. If restarts >= threshold:
      - Scale deployment to 0
      - If NS starts with "snd-*":
        - Find ArgoCD app for this NS
        - Disable auto-sync (set automated: null)
      - Break (stop after first match)
```

## Key Points

### Why wrapper task?
- Tekton UI runs pipeline with default SA (no cross-NS permissions)
- Wrapper task calls EventListener
- EventListener creates TaskRun with pipeline-runner SA
- pipeline-runner SA has cluster-wide permissions

### Why TaskRun not PipelineRun?
- TriggerTemplate creates TaskRun (not PipelineRun)
- Prevents infinite loop: Pipeline → Task → EventListener → PipelineRun → Pipeline → ...

### CEL Interceptor
Filters requests by header:
```
header.match('X-StopCrash-Event', 'run')
```

## Troubleshooting

### "No deployments found"
- Check SA permissions: `kubectl auth can-i list deployments -n <NS> --as=system:serviceaccount:devops:pipeline-runner`
- Ensure pipeline-runner SA has ClusterRoleBinding

### TaskRun not created
- Check EventListener pod logs: `kubectl logs -n devops -l eventlistener=stop-crash-eventlistener`
- Verify CEL header: `X-StopCrash-Event: run`

### Infinite loop
- TriggerTemplate must create TaskRun, not PipelineRun
- PipelineRun would re-trigger the pipeline → loop

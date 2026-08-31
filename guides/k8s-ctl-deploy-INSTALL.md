# k8s-ctl-deploy — Cluster Installation Guide

> Complete step-by-step guide to deploy the k8s-ctl namespace lifecycle pipeline on a new Kubernetes cluster.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1: Install Tekton Pipelines + Dashboard](#3-step-1-install-tekton-pipelines--dashboard)
4. [Step 2: Create Namespace](#4-step-2-create-namespace)
5. [Step 3: Build & Push Docker Image](#5-step-3-build--push-docker-image)
6. [Step 4: RBAC — ServiceAccount + ClusterRole](#6-step-4-rbac--serviceaccount--clusterrole)
7. [Step 5: PVC for State Persistence](#7-step-5-pvc-for-state-persistence)
8. [Step 6: Tekton Task — k8s-ctl](#8-step-6-tekton-task--k8s-ctl)
9. [Step 7: Tekton Task — Wrapper (EventListener caller)](#9-step-7-tekton-task--wrapper-eventlistener-caller)
10. [Step 8: Tekton Pipeline](#10-step-8-tekton-pipeline)
11. [Step 9: Triggers — TriggerTemplate + Trigger + EventListener](#11-step-9-triggers--triggertemplate--trigger--eventlistener)
12. [Step 10: HTTPRoute (optional)](#12-step-10-httproute-optional)
13. [Verification](#13-verification)
14. [Usage](#14-usage)
15. [Parameters Reference](#15-parameters-reference)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. Architecture Overview

```
Tekton Dashboard UI
  → Pipeline: k8s-ctl-pipeline
    → Task: k8s-ctl-eventlistener (wrapper — curl to EventListener)
      → EventListener: el-k8s-ctl-eventlistener.devops:8080
        → Trigger: k8s-ctl-trigger (CEL filter: X-K8sCtl-Event: run)
          → TriggerTemplate: k8s-ctl-trigger-template
            → TaskRun (serviceAccountName: pipeline-runner)
              → Task: k8s-ctl (inline script — all logic)
                → PVC: k8s-ctl-state (state files)
```

**Why wrapper Task?**
- Tekton Dashboard runs Pipeline with default SA (no cross-NS permissions)
- Wrapper Task calls EventListener
- EventListener creates TaskRun with `pipeline-runner` SA (cluster-wide permissions)

**Why TaskRun (not PipelineRun) in TriggerTemplate?**
- TriggerTemplate MUST create TaskRun, NOT PipelineRun
- PipelineRun → wrapper Task → EventListener → PipelineRun → ... (infinite loop!)
- TaskRun breaks the loop

**Resources overview:**

| Resource | Name | Namespace | Purpose |
|----------|------|-----------|---------|
| Namespace | devops | — | All resources live here |
| ServiceAccount | pipeline-runner | devops | Cluster-wide k8s-ctl permissions |
| ClusterRole | k8s-ctl-role | — | RBAC rules |
| ClusterRoleBinding | k8s-ctl-binding | — | Bind SA to ClusterRole |
| PVC | k8s-ctl-state | devops | State file persistence |
| Task | k8s-ctl | devops | Core logic (inline script) |
| Task | k8s-ctl-eventlistener | devops | Wrapper — calls EventListener |
| Pipeline | k8s-ctl-pipeline | devops | Dashboard entry point |
| TriggerTemplate | k8s-ctl-trigger-template | devops | Creates TaskRun |
| Trigger | k8s-ctl-trigger | devops | CEL filter |
| EventListener | k8s-ctl-eventlistener | devops | HTTP endpoint :8080 |

---

## 2. Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Kubernetes | 1.25+ | PodSecurity admission |
| kubectl | 1.25+ | Configured for target cluster |
| Docker / buildah | — | For building the image |
| Container registry | — | Harbor, Docker Hub, GHCR, etc. |
| ArgoCD (optional) | v2/v3 | Only if managing snd-* namespaces with autosync |

**Check cluster readiness:**

```bash
# Verify cluster access
kubectl cluster-info

# Check available StorageClasses (need one for PVC)
kubectl get sc

# Check PodSecurity (Tekton needs enforce=baseline on tekton-pipelines ns)
kubectl get ns tekton-pipelines -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "tekton-pipelines ns not yet created"
```

---

## 3. Step 1: Install Tekton Pipelines + Dashboard

### 3.1 Install Tekton Pipelines

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

### 3.2 Install Tekton Dashboard

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

### 3.3 Verify

```bash
kubectl -n tekton-pipelines get pods
# All pods should be Running/Completed

kubectl get crd tasks.tekton.dev
# Should return the CRD
```

### 3.4 PodSecurity Adjustment

Tekton's `prepare` init container needs root privileges. The `tekton-pipelines` namespace defaults to `enforce=restricted`. Change to `enforce=baseline`:

```bash
kubectl label ns tekton-pipelines pod-security.kubernetes.io/enforce- 2>/dev/null  # remove if exists
kubectl label ns tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

> **Note:** `enforce=baseline` allows most containers. `audit/warn=restricted` logs violations without blocking.

### 3.5 Resource estimates

| Component | CPU | Memory |
|-----------|-----|--------|
| pipelines-controller | 200-500m | 256Mi-512Mi |
| pipelines-webhook | 50-100m | 128Mi |
| dashboard | 50-100m | 128Mi |

---

## 4. Step 2: Create Namespace

```bash
kubectl create namespace devops
```

---

## 5. Step 3: Build & Push Docker Image

### 5.1 Files needed

- `Dockerfile`
- `k8s-ctl-deploy.sh`

### 5.2 Dockerfile

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

# Non-root user (required by PodSecurity restricted policy)
RUN useradd -u 1001 -m appuser
USER 1001
```

> **Why debian:bookworm-slim?** bitnami/kubectl is distroless — no apt-get, can't install python3. This image includes kubectl (official binary) + python3.

### 5.3 Build & Push

```bash
# Set your registry path
REGISTRY="your-registry.example.com/your-project/k8s-ctl-deploy:latest"

# Build
docker build -t "$REGISTRY" .

# Push
docker push "$REGISTRY"
```

### 5.4 Update Task image reference

After pushing, update the image in `tekton/task.yaml` (Step 6):

```yaml
      image: your-registry.example.com/your-project/k8s-ctl-deploy:latest
```

---

## 6. Step 4: RBAC — ServiceAccount + ClusterRole

Apply `tekton/rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: devops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-ctl-role
rules:
  # Namespace discovery
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list"]
  # Scalable resources (stop/start/scale)
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "patch", "update"]
  # Scale subresource (kubectl scale uses patch on /scale subresource)
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["get", "patch", "update"]
  # Pod cleanup (cmd_clean)
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "delete"]
  # ArgoCD Applications (get/list/patch)
  - apiGroups: ["argoproj.io"]
    resources: ["applications", "applications/status"]
    verbs: ["get", "list", "patch"]
  # CRD check (argocd_crd_exists)
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
    name: pipeline-runner
    namespace: devops
```

```bash
kubectl apply -f tekton/rbac.yaml
```

### Verify RBAC

```bash
kubectl auth can-i list deployments -A --as=system:serviceaccount:devops:pipeline-runner
# yes

kubectl auth can-i list statefulsets -A --as=system:serviceaccount:devops:pipeline-runner
# yes

kubectl auth can-i list daemonsets -A --as=system:serviceaccount:devops:pipeline-runner
# yes
```

---

## 7. Step 5: PVC for State Persistence

Apply `tekton/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: k8s-ctl-state
  namespace: devops
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path  # Change to your StorageClass
  resources:
    requests:
      storage: 10Mi
```

```bash
kubectl apply -f tekton/pvc.yaml
```

> **Note:** Change `storageClassName` to match your cluster. Run `kubectl get sc` to see available StorageClasses.

---

## 8. Step 6: Tekton Task — k8s-ctl

This is the core task with the full inline script. Apply `tekton/task.yaml`.

> **Important:** Before applying, update the `image:` field (line ~33) to your registry path:
> ```yaml
>       image: your-registry.example.com/your-project/k8s-ctl-deploy:latest
> ```

```bash
kubectl apply -f tekton/task.yaml
```

### Verify Task

```bash
kubectl get task k8s-ctl -n devops
```

---

## 9. Step 7: Tekton Task — Wrapper (EventListener caller)

Apply `tekton/task-eventlistener.yaml`:

```bash
kubectl apply -f tekton/task-eventlistener.yaml
```

---

## 10. Step 8: Tekton Pipeline

Apply `tekton/pipeline.yaml`:

```bash
kubectl apply -f tekton/pipeline.yaml
```

### Verify Pipeline

```bash
kubectl get pipeline k8s-ctl-pipeline -n devops
```

---

## 11. Step 9: Triggers — TriggerTemplate + Trigger + EventListener

Apply `tekton/triggers.yaml`:

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: k8s-ctl-trigger-template
  namespace: devops
spec:
  params:
    - name: action
      description: "Command: start | stop | status | stop-deploy | start-deploy | restart | clean"
    - name: target
      description: "Namespace name or prefix (e.g., snd-dwh, snd, all)"
    - name: deploy-name
      description: "Deployment name (required for stop-deploy / start-deploy only)"
      default: ""
    - name: replicas
      description: "Replica count for start-deploy (default: 1)"
      default: "1"
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: TaskRun           # ← MUST be TaskRun, NOT PipelineRun!
      metadata:
        generateName: k8s-ctl-run-
        namespace: devops
      spec:
        serviceAccountName: pipeline-runner
        taskRef:
          kind: Task
          name: k8s-ctl
        params:
          - name: action
            value: $(tt.params.action)
          - name: target
            value: $(tt.params.target)
          - name: deploy-name
            value: $(tt.params.deploy-name)
          - name: replicas
            value: $(tt.params.replicas)
        workspaces:
          - name: state
            persistentVolumeClaim:
              claimName: k8s-ctl-state
---
apiVersion: triggers.tekton.dev/v1beta1
kind: Trigger
metadata:
  name: k8s-ctl-trigger
  namespace: devops
spec:
  interceptors:
    - ref:
        name: "cel"
      params:
        - name: "filter"
          value: >-
            header.match('X-K8sCtl-Event', 'run')
  bindings:
    - name: action
      value: $(body.action)
    - name: target
      value: $(body.target)
    - name: deploy-name
      value: $(body.deploy-name)
    - name: replicas
      value: $(body.replicas)
  template:
    ref: k8s-ctl-trigger-template
---
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: k8s-ctl-eventlistener
  namespace: devops
spec:
  serviceAccountName: pipeline-runner
  triggers:
    - triggerRef: k8s-ctl-trigger
```

```bash
kubectl apply -f tekton/triggers.yaml
```

### Verify Triggers

```bash
kubectl get triggertemplate k8s-ctl-trigger-template -n devops
kubectl get trigger k8s-ctl-trigger -n devops
kubectl get eventlistener k8s-ctl-eventlistener -n devops

# Check EventListener pod is running
kubectl get pods -n devops -l eventlistener=k8s-ctl-eventlistener
```

---

## 12. Step 10: HTTPRoute (optional)

If you have Gateway API (Istio/Envoy) and want to expose the Tekton Dashboard externally:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  parentRefs:
    - name: <your-gateway>
      namespace: <gateway-namespace>
      sectionName: <section-name>
  hostnames:
    - "tekton.<your-domain>"
  rules:
    - backendRefs:
        - name: tekton-dashboard
          port: 9097
      matches:
        - path:
            type: PathPrefix
            value: /
```

> **Note:** Adjust `parentRefs`, `hostnames`, and `sectionName` to match your cluster's Gateway setup.

---

## 13. Verification

### Full status check

```bash
echo "=== Namespace ==="
kubectl get ns devops

echo "=== RBAC ==="
kubectl get sa pipeline-runner -n devops
kubectl get clusterrole k8s-ctl-role
kubectl get clusterrolebinding k8s-ctl-binding

echo "=== PVC ==="
kubectl get pvc k8s-ctl-state -n devops

echo "=== Tasks ==="
kubectl get task -n devops

echo "=== Pipeline ==="
kubectl get pipeline -n devops

echo "=== Triggers ==="
kubectl get triggertemplate,trigger,eventlistener -n devops

echo "=== EventListener Pod ==="
kubectl get pods -n devops -l eventlistener=k8s-ctl-eventlistener
```

### Test with a simple action

```bash
# Test via EventListener curl
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"status","target":"all"}'

# Verify TaskRun was created
kubectl get taskrun -n devops --sort-by=.metadata.creationTimestamp | tail -5
```

### Test from Tekton Dashboard

1. Open browser → `tekton.<your-domain>` (or port-forward)
2. Go to Pipelines → `k8s-ctl-pipeline`
3. Click "Create"
4. Enter params: `action=status`, `target=all`
5. Click "Create Run"
6. Watch logs in real-time

---

## 14. Usage

### From Tekton Dashboard

1. Open Tekton Dashboard
2. Select Pipeline: `k8s-ctl-pipeline`
3. Click "Create" → fill params → "Create Run"

### From curl (internal)

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

# Restart (rollout restart)
curl -X POST http://el-k8s-ctl-eventlistener.devops.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -H "X-K8sCtl-Event: run" \
  -d '{"action":"restart","target":"snd-dwh"}'

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
```

### From CLI (tkn)

```bash
tkn task start k8s-ctl \
  --param action=status \
  --param target=all \
  --workspace name=state,pvc=k8s-ctl-state
```

---

## 15. Parameters Reference

| action | target | deploy-name | replicas | Description |
|--------|--------|-------------|----------|-------------|
| stop | ns | - | - | Stop all (snd: autosync off + scale 0; prd: save + scale 0) |
| start | ns | - | - | Start all (prd: restore replicas; snd: autosync on) |
| status | ns | - | - | Show namespace status |
| stop-deploy | ns | deploy-name | - | Stop single deployment (snd: disable owning app autosync) |
| start-deploy | ns | deploy-name | 1 | Start single deployment (scale only, no autosync touch) |
| restart | ns | - | - | Rollout restart all Deployments/StatefulSets/DaemonSets |
| clean | ns | - | - | Delete Succeeded/Failed pods |

**target values:**
- `all` — all snd-*/prd-* namespaces
- `snd` — all snd-* namespaces
- `prd` — all prd-* namespaces
- `snd-dwh` — specific namespace
- `snd-dwh-prod` — specific namespace (prefix match)

---

## 16. Troubleshooting

### TaskRun not created

```bash
# Check EventListener pod logs
kubectl logs -n devops -l eventlistener=k8s-ctl-eventlistener --tail=100

# Verify EventListener is ready
kubectl get eventlistener k8s-ctl-eventlistener -n devops -o yaml | grep -A5 status
```

### TaskRun fails with RBAC error

```bash
# Check SA permissions
kubectl auth can-i list namespaces --as=system:serviceaccount:devops:pipeline-runner
kubectl auth can-i list deployments -A --as=system:serviceaccount:devops:pipeline-runner

# Verify ClusterRoleBinding
kubectl get clusterrolebinding k8s-ctl-binding -o yaml
```

### TaskRun fails with ImagePullBackOff

```bash
# Check image reference in Task
kubectl get task k8s-ctl -n devops -o jsonpath='{.spec.steps[0].image}'

# Test pull from a node
docker pull <your-image>

# If using private registry, ensure imagePullSecret is configured
```

### EventListener returns 404

```bash
# Check EventListener service
kubectl get svc -n devops -l eventlistener=k8s-ctl-eventlistener

# Verify ServiceAccount
kubectl get eventlistener k8s-ctl-eventlistener -n devops -o jsonpath='{.spec.serviceAccountName}'
```

### Infinite loop (TaskRuns keep creating)

**Root cause:** TriggerTemplate creates PipelineRun instead of TaskRun.

**Fix:** Ensure TriggerTemplate has `kind: TaskRun` (not PipelineRun):

```yaml
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: TaskRun           # ← MUST be TaskRun
```

### PVC pending

```bash
# Check PVC status
kubectl get pvc k8s-ctl-state -n devops

# Check available StorageClasses
kubectl get sc

# Update PVC storageClassName if needed
```

### Dashboard shows no Pipelines

```bash
# Verify Pipeline exists
kubectl get pipeline -n devops

# Check Dashboard is pointing to correct namespace
kubectl get svc tekton-dashboard -n tekton-pipelines
```

---

## Quick Install (all-in-one)

If you want to apply everything at once after customizing the image path:

```bash
# 1. Install Tekton
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# 2. Fix PodSecurity
kubectl label ns tekton-pipelines pod-security.kubernetes.io/enforce- 2>/dev/null
kubectl label ns tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# 3. Create namespace
kubectl create namespace devops

# 4. Apply all resources (edit image path in task.yaml first!)
kubectl apply -f tekton/rbac.yaml
kubectl apply -f tekton/pvc.yaml
kubectl apply -f tekton/task.yaml
kubectl apply -f tekton/task-eventlistener.yaml
kubectl apply -f tekton/pipeline.yaml
kubectl apply -f tekton/triggers.yaml
```

---

## File Structure

```
k8s-ctl-deploy/
├── Dockerfile
├── k8s-ctl-deploy.sh
├── PLAN.md
├── mesh-demo-README.md
└── tekton/
    ├── rbac.yaml              (SA + ClusterRole + ClusterRoleBinding)
    ├── pvc.yaml               (State persistence)
    ├── task.yaml              (Core task — inline script)
    ├── task-eventlistener.yaml (Wrapper task — curl to EventListener)
    ├── pipeline.yaml          (Dashboard entry point)
    └── triggers.yaml          (TriggerTemplate + Trigger + EventListener)
```

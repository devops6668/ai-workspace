# Mesh Demo - GitOps + ArgoCD + Tekton Pipeline

## Overview
Redesigned mesh-demo from single manifest to full GitOps workflow with ArgoCD deployment and Tekton pipeline for crash recovery.

## Date: 2026-08-20

---

## 1. Azure DevOps Repos (per namespace)

| Repo | URL |
|------|-----|
| mesh-demo-snd-demo1 | https://dev.azure.com/paulbeyond/demo/_git/mesh-demo-snd-demo1 |
| mesh-demo-snd-demo2 | https://dev.azure.com/paulbeyond/demo/_git/mesh-demo-snd-demo2 |
| mesh-demo-snd-demo3 | https://dev.azure.com/paulbeyond/demo/_git/mesh-demo-snd-demo3 |
| mesh-demo-prd-demo1 | https://dev.azure.com/paulbeyond/demo/_git/mesh-demo-prd-demo1 |
| mesh-demo-prd-demo2 | https://dev.azure.com/paulbeyond/demo/_git/mesh-demo-prd-demo2 |

Each repo structure (Kustomize):
```
├── namespace.yaml
├── deploy-1-deployment.yaml
├── deploy-1-service.yaml
├── deploy-1-httproute.yaml
├── deploy-2-deployment.yaml
├── deploy-2-service.yaml
├── deploy-2-httproute.yaml
├── deploy-3-deployment.yaml
├── deploy-3-service.yaml
├── deploy-3-httproute.yaml
└── kustomization.yaml
```

Local path: `/home/devops/Documents/mesh-demo-repos/mesh-demo-{ns}/`

---

## 2. ArgoCD Applications

| App | NS | Repo | Sync |
|-----|----|------|------|
| mesh-demo-snd-demo1 | snd-demo1 | mesh-demo-snd-demo1 | auto |
| mesh-demo-snd-demo2 | snd-demo2 | mesh-demo-snd-demo2 | auto |
| mesh-demo-snd-demo3 | snd-demo3 | mesh-demo-snd-demo3 | manual |
| mesh-demo-prd-demo1 | prd-demo2 | mesh-demo-prd-demo1 | manual |
| mesh-demo-prd-demo2 | prd-demo2 | mesh-demo-prd-demo2 | auto |

Note: prd-demo1 deploys to prd-demo2 namespace (intentional).

---

## 3. Namespaces & Deployments

| NS | Deployments | Status |
|----|-------------|--------|
| snd-demo1 | deploy-1, deploy-2, deploy-3 | All Running |
| snd-demo2 | deploy-1, deploy-2, deploy-3 | All Running |
| snd-demo3 | deploy-1, deploy-2, deploy-3 | deploy-1,2 Running; deploy-3 CrashLoop |
| prd-demo1 | (none - deploys to prd-demo2) | - |
| prd-demo2 | deploy-1, deploy-2, deploy-3 | All Running |

Image: `harbor.luban.paulhome.local/mesh-demo/app1:latest`

---

## 4. Tekton Pipeline (NS: devops)

### Resources
| Resource | Name |
|----------|------|
| Pipeline | stop-crash-deployment-pipeline |
| Task (actual work) | stop-crash-deployment-task |
| Task (wrapper) | stop-crash-eventlistener |
| Trigger | stop-crash-trigger |
| TriggerTemplate | stop-crash-trigger-template |
| EventListener | stop-crash-eventlistener |

### Flow
```
Tekton UI → Pipeline → Wrapper Task (curl) → EventListener
→ Trigger (CEL filter: X-StopCrash-Event: run)
→ TriggerTemplate → TaskRun (pipeline-runner SA) → Task
```

### Parameters
- `namespace`: Target namespace (e.g. snd-demo3)
- `restart-count`: Restart threshold (e.g. 3)

### Logic
1. Scan all deployments in namespace
2. Check pod restart counts
3. If restarts >= threshold → scale deployment to 0
4. If NS starts with `snd-*` → also disable ArgoCD auto-sync

### Usage (from Tekton UI)
Pipeline: `stop-crash-deployment-pipeline`
Params:
  - namespace: snd-demo3
  - restart-count: 3

### Usage (curl)
```bash
curl -X POST http://el-stop-crash-eventlistener.devops.svc.cluster.local:8080   -H "Content-Type: application/json"   -H "X-StopCrash-Event: run"   -d '{"namespace":"snd-demo3","restart-count":"3"}'
```

---

## 5. k3s Registry Config

File: `/etc/rancher/k3s/registries.yaml`
```yaml
mirrors:
  "harbor.luban.paulhome.local":
    endpoint:
      - "https://harbor.luban.paulhome.local"
configs:
  "harbor.luban.paulhome.local":
    tls:
      ca_file: "/etc/rancher/k3s/certs/harbor.luban.paulhome.local.crt"
```

CA cert: `/etc/rancher/k3s/certs/harbor.luban.paulhome.local.crt`

---

## 6. Known Issues & Fixes

### Image Pull Failures
- Harbor blobs were garbage collected → rebuilt and pushed images
- k3s couldn't trust Harbor TLS → added registries.yaml + CA cert

### Immutable Selector
- Kustomize `commonLabels` adds labels to Deployment selector
- Deployment spec.selector is immutable → removed commonLabels from kustomization.yaml

### Infinite Loop
- TriggerTemplate was creating PipelineRun → caused loop
- Fix: Changed TriggerTemplate to create TaskRun instead

### RBAC
- Pipeline runs in devops namespace need `pipeline-runner` SA
- SA has ClusterRoleBinding to `k8s-ctl-role` (get/list/patch deployments)

---

## 7. File Locations

| File | Path |
|------|------|
| Task | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-deployment-task.yaml |
| Pipeline | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-deployment-pipeline.yaml |
| Wrapper Task | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-eventlistener-task.yaml |
| Trigger | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-trigger.yaml |
| TriggerTemplate | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-trigger-template.yaml |
| EventListener | /home/devops/Documents/mesh-demo-repos/tekton/stop-crash-eventlistener.yaml |

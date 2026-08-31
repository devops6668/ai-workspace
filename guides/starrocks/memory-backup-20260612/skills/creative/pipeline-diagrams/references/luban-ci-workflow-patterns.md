# Luban CI Workflow Patterns

Source: https://github.com/metasync/luban-ci v1.3.3+
Local: /root/Luban/luban-ci-v1.3.2/

## Three-Phase Diagram Structure (User Specified)

1. **PROJECT CREATION** — Only `luban-project-setup-template`
2. **SANDBOX BOOTSTRAP** — dagster-platform + code-location (snd)
3. **SANDBOX CI PIPELINE** — Developer → kpack → ArgoCD
4. **PRODUCTION BOOTSTRAP** — dagster-platform + code-location (prd)
5. **PRODUCTION PROMOTION** — `promotion-workflow`
6. **PRODUCTION DEPLOYMENT** — Manual ArgoCD sync (infra → platform → code-location)

## Template Reference

### 1. luban-project-setup-template (Admin Cluster)
**Trigger**: Project Admin | **File**: `manifests/workflows/luban-project-workflow-template.yaml`
**Steps** (sequential):
1. `git-project-setup` — Create git repo + admin/developer OIDC groups
2. `harbor-project-setup` — Create Harbor project (public/private)
3. `ci-infra-provision` — Create ci-{project} namespace + RBAC (via `ci-infra-provision-template`)
4. `argocd-project` — Create AppProjects for snd + prd (via `argocd-project-setup-template`)
5. `namespace-provision` — Create snd-{project} + prd-{project} namespaces (via `namespace-provision-template`)

**Params**: `project_name`, `environments` (default: ["snd","prd"]), `git_organization`, `git_provider`, `developer_group`, `admin_group`, `registry_visibility`

### 2. luban-dagster-platform-setup-template (Worker Cluster)
**Trigger**: Project Admin | **File**: `manifests/workflows/luban-dagster-platform-setup-template.yaml`
**Steps** (DAG):
1. `generate-config` — Generate config.yaml with otel settings
2. `provision-gitops-repo` — Create `{app_name}-gitops` repo (via `gitops-repo-provision-template`)
3. `setup-argocd-app` — Create ArgoCD App → deploy to {env}-{project} (via `argocd-app-setup-template`)
4. `provision-source-repo` — Optional: scaffold source code repo

**Params**: `project_name`, `app_name` (default: dagster-platform), `environment` (snd/prd), `git_organization`, `git_provider`, `setup_source_repo`

### 3. luban-dagster-dbt-starrocks-code-location-setup-template (Worker Cluster)
**Trigger**: Project Admin | **File**: `manifests/workflows/luban-dagster-dbt-starrocks-code-location-workflow-template.yaml`
**Steps** (DAG):
1. `generate-config` — Generate config.yaml with dagster_component_type=code-location
2. `provision-gitops-repo` — Create `{app_name}-gitops` repo
3. `setup-argocd-app` — Create ArgoCD App
4. `register-code-location` — Register gRPC code-server location with Dagster Platform
5. `provision-source-repo` — Optional: scaffold source code repo

**Params**: `project_name`, `app_name` (required), `environment`, `git_organization`, `git_provider`, `setup_source_repo`, `default_env`

### 4. luban-ci-kpack-workflow-template (CI Pipeline)
**Trigger**: Git Push → ArgoEvents → Sensor → Dispatcher | **File**: `manifests/workflows/luban-ci-kpack-workflow-template.yaml`
**Pipeline**:
```
ci-pipeline
  ├─ when: git_ref !~ refs/tags/ → build-push (mode=commit) → kpack build → git-update → ArgoCD sync → sandbox
  └─ when: git_ref =~ refs/tags/ → build-push (mode=tag) → kpack build → git-update → ArgoCD sync → sandbox
```
**build-push**: Runs `kpack_apply_image_spec.sh {mode} {sub_path}` + `kpack_wait_build.sh`
**git-update**: Commits to gitops repo: updates `app/overlays/snd/overlay.yaml` with new image tag

### 5. luban-promotion-workflow-template (Promotion)
**Trigger**: Manual | **File**: `manifests/workflows/luban-promotion-workflow-template.yaml`
**Action**: `luban-provisioner promote --project-name {p} --app-name {a}`
Extracts verified sandbox image tag → updates prd overlay → PR to gitops repo

## Key Scripts (in gitops-utils image)

| Script | Purpose |
|--------|---------|
| `kpack_apply_image_spec.sh {mode}` | Apply kpack ImageSpec (commit vs tag mode) |
| `kpack_wait_build.sh` | Poll kpack Build until ready, output image_tag |
| `gitops_update_repo.sh` | Update gitops repo overlays |
| `argo_dispatch_ci_pipeline.sh` | Submit ci-pipeline workflow |

## Role Mapping

| Action | Role |
|--------|------|
| Project setup bootstrap | Project Admin |
| Platform bootstrap | Project Admin |
| Code-location bootstrap | Project Admin |
| Code development | Project Developer |
| Platform promotion | Project Admin |
| Code-location promotion | Project Developer |
| Production ArgoCD sync | Project Admin |

## Namespace Naming Convention

| Pattern | Cluster | Purpose |
|---------|---------|---------|
| `luban-ci` | Admin | Core CI infrastructure |
| `ci-{project}` | Admin | Project CI workflows |
| `snd-{project}` | Worker | Sandbox applications |
| `prd-{project}` | Worker | Production applications |

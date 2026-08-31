# Argo Workflows v4 — Workflow Template CA Cert Injection

Session context: Paul Wong's luban-ci project (v1.3.2 → v1.3.3) needed `luban-ca-cert` injection into multiple workflow templates for on-prem TLS verification.

## What Changed in v1.3.2 → v1.3.3

Single commit: `8392746 fix(workflows): mount luban-ca-cert for git HTTPS`

### Files modified (manifests/workflows/)
1. `luban-project-workflow-template.yaml` — added CA env vars + volumeMount for git provisioner step
2. `luban-python-app-workflow-template.yaml` — removed root-level `volumes: luban-ca-cert` (moved to referenced template)
3. `luban-dagster-platform-setup-template.yaml` — removed root-level `volumes: luban-ca-cert` (moved to referenced template)
4. `luban-dagster-code-location-workflow-template.yaml` — added CA env vars + volumeMount for git clone step
5. `luban-dagster-dbt-starrocks-code-location-workflow-template.yaml` — added CA env vars + volumeMount for git clone step

### What was added to git-provisioner / git-clone steps
- `SSL_CERT_FILE` → secret `luban-ca-cert` key `ssl_cert_file`
- `REQUESTS_CA_BUNDLE` → secret `luban-ca-cert` key `requests_ca_bundle`
- `GIT_SSL_CAINFO` → secret `luban-ca-cert` key `git_ssl_cainfo`
- `CURL_CA_BUNDLE` → secret `luban-ca-cert` key `curl_ca_bundle`
- Volume mount at `/var/run/luban/ca` readOnly

### Why the volume removals were needed
Argo Workflows v4 enforces `templateReferencing: Strict` mode. Under strict mode, volumes declared in the **calling** template don't apply to templates referenced via `templateRef`. Volumes must be declared in the **referenced** template itself. This was partially fixed in v1.3.2 for kpack workflow, and extended in v1.3.3 to project + dagster templates.

## Common CA Bundle Keys Reference

| Secret Key | Env Var | Purpose |
|-----------|---------|---------|
| `ssl_cert_file` | `SSL_CERT_FILE` | Python ssl module, urllib |
| `requests_ca_bundle` | `REQUESTS_CA_BUNDLE` | Python requests library |
| `git_ssl_cainfo` | `GIT_SSL_CAINFO` | Git CLI HTTPS verification |
| `curl_ca_bundle` | `CURL_CA_BUNDLE` | curl HTTPS verification |

## Related Commits (v1.3.x)
- `5161c42` — kpack: add optional private CA support (first pass — kpack only)
- `ae5641c` — workflows: move orchestration into gitops-utils 0.4.0
- `acc7fde` — fix kpack services indentation and promotion CA volume
- `07d450a` — TLS: central luban-ca-cert for on-prem workflows (earlier)

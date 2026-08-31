# Argo Workflows v4 templateReferencing: Strict — volumes must live in referenced templates

When Argo Controller ConfigMap sets `templateReferencing: Strict` (v4+ default), `templateRef` references enforce that the **referenced** template declares its own volumes. The parent template that uses `templateRef` CANNOT declare volumes for the child.

## The Bug Pattern

```yaml
# ❌ WRONG — volumes declared in parent template that uses templateRef
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: parent-workflow
spec:
  volumes:
    - name: luban-ca-cert
      secret:
        secretName: luban-ca-cert
        optional: true
  templateRef:
    template: child-template
    name: child-workflow-template
```

This fails with validation errors under `templateReferencing: Strict`.

## The Fix

Move volumes to the **referenced** template itself (the child):

```yaml
# ✅ CORRECT — volumes declared in the child template
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: child-workflow-template
spec:
  volumes:
    - name: luban-ca-cert
      secret:
        secretName: luban-ca-cert
        optional: true
```

And mount them in the steps:

```yaml
  steps:
    - - name: do-thing
        template: do-thing-template
        volumeMounts:
          - name: luban-ca-cert
            mountPath: /var/run/luban/ca
            readOnly: true
```

## How to Diagnose

If Argo validates a template and rejects it, check:
1. Does the template use `templateRef`?
2. Are volumes declared in the parent (caller) template?
3. If yes → move volumes to the referenced child template.

## Real-World Example (luban-ci v1.3.2 → v1.3.3)

Commit `8392746` fixed this in the luban-ci project:

- **Removed** `volumes: luban-ca-cert` from `luban-python-app-workflow-template.yaml` and `luban-dagster-platform-setup-template.yaml` (both referenced child templates)
- **Added** `volumes` + `volumeMounts` to `luban-project-workflow-template.yaml` and `luban-dagster-code-location-workflow-template.yaml` (direct templates, not using `templateRef` for those workflow steps)

## Key Rule

> Under `templateReferencing: Strict`, volumes must be declared **where they're used**, not in the template that calls them via `templateRef`.

## Workaround (not recommended)

Set `templateReferencing: Override` in the Argo Controller ConfigMap. This defeats the security model but is useful for quick debugging.

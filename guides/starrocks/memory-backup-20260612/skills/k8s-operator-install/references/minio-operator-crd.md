# MinIO Operator CRD Discovery

## CRDs

| CRD Name | Group | Version |
|---|---|---|
| `tenants.minio.min.io` | `minio.min.io` | v2 |
| `policybindings.sts.min.io` | `sts.min.io` | (varies) |

## Version Mismatch

The Helm chart (`minio-tenant-csi/minio-operator` v4.3.7) contains the operator Deployment and tenant example, but **does NOT bundle the CRDs**. CRDs are only available via kustomize:

```bash
kubectl kustomize "github.com/minio/operator?ref=v7.1.1" | kubectl apply -f -
```

Verify CRDs were created:
```bash
kubectl get crd | grep minio
# tenants.minio.min.io
# policybindings.sts.min.io
```

## Tenant Spec Highlights

- `spec.requestAutoCert: true` — automatic TLS certificate generation
- `spec.credsSecret.name` — Kubernetes Secret with `username`/`password` for minio admin
- `spec.pools[].servers` — number of MinIO servers per pool
- `spec.pools[].volumeClaimTemplate.spec.storageClassName` — adjust to available StorageClass
- `spec.pools[].securityContext.fsGroupChangePolicy: OnRootMismatch` — prevents expensive recursive permission changes on large volumes
- `spec.pools[].containerSecurityContext` — security hardening (non-root, no privilege escalation, drop ALL capabilities)

## Ports

| Service | Port | Protocol |
|---|---|---|
| MinIO API | 9000 | HTTPS (default) / HTTP |
| Console | 9443 | HTTPS |
| Console (HTTP) | 9090 | HTTP |
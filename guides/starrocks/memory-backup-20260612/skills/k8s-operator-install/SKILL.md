---
name: k8s-operator-install
description: "Install and document Kubernetes operators — operator deployment, CRD creation, cluster provisioning via CR, access, scaling, and upgrades."
version: 1.0.0
author: agent
license: MIT
---

# K8s Operator Installation & Documentation

Produce installation guides for K8s operators and capture the patterns for future reuse.

## Workflow

1. **Fetch upstream docs** — prefer raw markdown (GitHub `.md`) over rendered pages.
   - Pattern: `curl -sL https://raw.githubusercontent.com/<org>/<repo>/main/docs/en/<topic>.md`
   - Fallback: `curl -sL https://docs.<service>.io/docs/<path>/` then parse HTML if no raw md exists.
   - If the rendered page is JS-heavy, try the GitHub source directly (editor path usually mirrors `docs/en/`).
   - Also fetch example manifests and API reference files — they contain real YAML specs the agent needs.

2. **Gather artifacts** — collect CRD YAML, operator deployment YAML, and at least one cluster CR example.
   - Typical URLs: `deploy/*.yaml`, `examples/**/*.yaml`, `doc/api.md` in the operator repo.
   - Key fields to extract: CRD name, operator namespace, component specs (FE/BE/CN or equivalent), service types.

3. **Produce the guide** — structure as:
   - Prerequisites (cluster version, tools)
   - Operator installation (CRD → deployment → verify)
   - Cluster deployment (CR creation, YAML structure)
   - Access patterns (internal ClusterIP, external LoadBalancer/NodePort)
   - Management operations (upgrade, scale out, scale in, auto-scaling)
   - FAQ (common errors with fixes)
   - Appendix (resource list, API reference links)

4. **Save output** — write the guide to the user's specified workspace directory (respect `owner:group` permissions). If no workspace specified, default to current working directory.

## Operator Installation Methods

Three canonical patterns:

1. **Helm** — most common. Check `helm template <release> <chart> --namespace <ns>` output for `kind: CustomResourceDefinition`. Some charts (e.g., `minio-tenant-csi/minio-operator` v4.3.7) bundle the operator but NOT the CRDs.
2. **Kustomize** — often the official docs' canonical install path. CRDs are always included.
   ```bash
   kubectl kustomize "github.com/<org>/<repo>?ref=<version>" | kubectl apply -f -
   ```
3. **Direct YAML** — some operators expose a single URL.
   ```bash
   kubectl apply -f https://operator.example.com/install.yaml
   ```

**Always verify:** `kubectl kustomize ... | grep 'kind: CustomResourceDefinition'` to confirm CRDs are included.

## Creating Tenant / Custom Resources

After the operator is running, create tenant resources via YAML:

```yaml
apiVersion: <operator-group>/<version>
kind: <ResourceKind>
metadata:
  name: <name>
  namespace: <tenant-ns>
spec:
  # Operator-specific spec fields
```

**Generic pattern:**
1. Check available CRDs: `kubectl get crd | grep <operator-name>`
2. Find example YAMLs: GitHub examples directory or `helm template` output
3. Adapt to local storage: Replace `storageClassName` with available classes
4. Create namespace first: `kubectl create namespace <tenant-ns>`
5. Apply: `kubectl apply -f <resource>.yaml`
6. Verify: `kubectl get pods -n <tenant-ns>`

## Authoring Install Guides (Bilingual)

When creating installation guides:

1. **Structure:**
   - Architecture overview (ASCII diagram)
   - Prerequisites (cluster version, tools, available StorageClasses)
   - Operator installation (3 methods: Helm, kustomize, direct YAML)
   - Tenant/resource creation (minimal YAML + field explanation table)
   - Verification steps
   - Access methods (port-forward + NodePort for k3s)
   - Management operations (upgrade, scale, delete)
   - Troubleshooting FAQ
   - Appendix: resource list, ports, commands

2. **Language variants:** Always produce BOTH English and Chinese versions. Content is identical except for comments, UI text, and terminology (e.g., "存算分離" vs "storage-compute separation"). File naming: `<name>-guide.md` (Chinese) and `<name>-guide-en.md` (English).

3. **Key fields table:** Always include a table mapping important YAML fields to their purpose.

4. **k3s-specific notes:**
   - `local-path` (default) for single-node homelab
   - `nfs-csi` for multi-node persistent storage
   - `LoadBalancer` type Services often don't get external IP on k3s — use `NodePort` instead
   - Warn about StorageClass availability before providing YAML

5. **Output:** Save to workspace directory with correct ownership (`chown devops:devops`).

## Pitfalls

- **CRD annotation limit** — `kubectl apply` on large CRDs can fail with `Too long: must have at most 262144 bytes`. Use `kubectl create -f` for first install, `kubectl replace -f` for updates.
- **JS-rendered docs sites** — Docusaurus/React docs won't parse well via `curl`. Always look for the raw `.md` source on GitHub first.
- **Component names vary** — some operators use FE/BE/CN, others use controller/worker/query-engine. Map terminology to what the upstream docs actually use.
- **Shared-data (存算分離) mode replaces BE with CN** — in StarRocks shared-data mode, BE nodes are replaced by CN (Compute Node). CN handles query execution only; data resides in remote storage (S3/MinIO). The CR uses `starRocksCnSpec` instead of `starRocksBeSpec`. FE config via ConfigMap must set `run_mode = shared_data`.
- **Helm chart may omit CRDs or be outdated** — some charts (e.g., `minio-tenant-csi/minio-operator` v4.3.7) bundle the operator but NOT the CRDs. Also, the Helm chart version may lag the actual operator version (e.g., MinIO Operator v7.1.1 but Helm chart only v4.3.7). **Always check the operator's official docs** — MinIO docs now recommend kustomize install via `kubectl kustomize "github.com/minio/operator?ref=v7.1.1"`.
- **CN autoscaling** — StarRocks CN autoscaling uses `autoScalingPolicy.hpaPolicy` in the CR. `scaleDown.selectPolicy: Disabled` prevents aggressive scale-down. CN cache storage (`cn-cache`) is optional — set `storageVolumes: []` for stateless scaling.
- **MinIO TLS with cert-manager** — set `requestAutoCert: false` and use `externalCertSecret` (and optionally `externalCaCertSecret`) in the tenant spec to reference a cert-manager managed TLS certificate. The cert-manager `Certificate` resource creates a `kubernetes.io/tls` secret that the MinIO operator mounts into pods. Console ports: 9443 (HTTPS), 9090 (HTTP). API port: 9000.
- **DirectPV** — for local disk management with MinIO, install via `kubectl apply -f https://directpv.min.io` then label nodes.
- **Nginx Ingress for MinIO** — add `nginx.ingress.kubernetes.io/proxy-body-size: "0"` and `proxy-read/send-timeout: "3600"` for large file uploads. Set `backend-protocol: "HTTP"` since Ingress→cluster is HTTP even if client→Ingress is HTTPS.
- **Envoy Gateway** — uses Gateway API (`HTTPRoute` + `TLSPolicy`) instead of standard Ingress resources. The `parentRefs` field binds to the gateway instance by name.

## References

- `references/minio-operator-crd.md` — MinIO Operator CRD discovery, version mismatch between Helm and kustomize, tenant spec highlights

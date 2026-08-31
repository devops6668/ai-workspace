# OSSM 2 Gateway Migration to Injection — Pre-Migration Steps

> **Purpose:** Migrate gateways from SMCP-defined management to gateway injection before upgrading to OSSM 3.
> **Source:** Red Hat OpenShift Service Mesh 2.x Documentation, Section 2.15.2 — "Migrate from SMCP-Defined gateways to gateway injection"
> **Link:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/service_mesh/service-mesh-2-x#ossm-migrating-from-smcp-defined-gateways-to-gateway-injection

---

## When to Apply This Guide

Apply these steps **only if** your OSSM 2 gateway is still managed by the `ServiceMeshControlPlane` resource (SMCP). If your gateway is already a standalone Deployment using gateway injection (as described in your main migration guide's Phase 4), skip this document.

To check if your gateway is SMCP-managed:

```bash
oc get smcp basic -n istio-system -o jsonpath='{.spec.gateways}' | python3 -m json.tool
```

If the output contains `ingress:` with deployment configuration, your gateway is SMCP-managed and you need these steps.

---

## Prerequisites

- Logged in to OpenShift as `cluster-admin`
- OSSM 2 Operator installed and running
- ServiceMeshControlPlane resource deployed with an ingress gateway
- `istioctl` tool installed (matching your OSSM 2 Istio version)

---

## Step 1: Create the Canary Gateway Deployment

Create a new gateway Deployment that uses gateway injection. Deploy it in the **same namespace** as the SMCP-defined gateway (`istio-system`).

```yaml
# canary-gateway.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway-canary
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
      istio: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
      labels:
        app: istio-ingressgateway
        istio: ingressgateway
        sidecar.istio.io/inject: "true"
    spec:
      containers:
      - name: istio-proxy
        image: auto
      serviceAccountName: istio-ingressgateway
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-ingressgateway
  namespace: istio-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: istio-system
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: istio-ingressgateway-secret-reader
  namespace: istio-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: secret-reader
subjects:
- kind: ServiceAccount
  name: istio-ingressgateway
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gatewayingress
  namespace: istio-system
spec:
  podSelector:
    matchLabels:
      istio: ingressgateway
  ingress:
  - {}
  policyTypes:
  - Ingress
```

> **Notes:**
> 1. The gateway injection deployment must be in the **same namespace** as the SMCP-defined gateway.
> 2. The pod template labels must include **all label selectors** from the existing Service object (`app: istio-ingressgateway, istio: ingressgateway`).
> 3. The NetworkPolicy grants external access to the new gateway. This is required when `spec.security.manageNetworkPolicy` is set to `true` (the default).

Apply it:

```bash
oc apply -f canary-gateway.yaml
```

---

## Step 2: Verify the Canary Gateway

Confirm the new gateway is running and handling requests:

```bash
# Check pods are running
oc get pods -n istio-system -l app=istio-ingressgateway

# Check access logs (if configured in SMCP)
oc logs -n istio-system deployment/istio-ingressgateway-canary -c istio-proxy

# Verify with istioctl
istioctl ps -n istio-system | grep canary
```

---

## Step 3: Gradually Shift Traffic

Scale up the canary gateway and scale down the old SMCP-managed gateway:

```bash
# Increase canary replicas
oc scale -n istio-system deployment/istio-ingressgateway-canary --replicas 3

# Decrease old gateway replicas (via SMCP patch)
oc patch smcp basic -n istio-system --type json \
  -p '[{"op": "replace", "path": "/spec/gateways/ingress/runtime/deployment/replicas", "value": 0}]'
```

> **Repeat incrementally:** Adjust replica counts until the canary handles all traffic. Monitor the old gateway's logs to confirm traffic has shifted.

---

## Step 4: Detach the Service Object from SMCP Management

After confirming the canary gateway handles all traffic, detach the existing `istio-ingressgateway` Service from the SMCP so it won't be deleted when the old gateway is disabled.

```bash
# Remove the managed-by label
oc label service -n istio-system istio-ingressgateway app.kubernetes.io/managed-by-

# Remove ownerReferences (prevents garbage collection)
oc patch service -n istio-system istio-ingressgateway --type='json' \
  -p '[{"op": "remove", "path": "/metadata/ownerReferences"}]'
```

---

## Step 5: Disable the Old SMCP-Managed Gateway

Disable the old gateway in the SMCP:

```bash
oc patch smcp basic -n istio-system --type='json' \
  -p '[{"op": "replace", "path": "/spec/gateways/ingress/enabled", "value": false}]'
```

> **Note:** When the old ingress gateway Service is disabled, it is **not deleted**. You may save this Service object to a file for reference.
>
> The `/spec/gateways/ingress/enabled` path is available if you explicitly set it. If using the default value, patch `/spec/gateways/enabled` for both ingress and egress.

---

## Step 6: Verify the Migration

```bash
# Confirm old gateway is disabled
oc get smcp basic -n istio-system -o jsonpath='{.spec.gateways.ingress.enabled}'
# Should output: false

# Confirm canary gateway is handling traffic
oc get pods -n istio-system -l app=istio-ingressgateway
# Should show only the canary deployment

# Test endpoints
for i in 1 2 3 4 5 6 7 8; do
  echo -n "hello-world${i}.devops.local: "
  curl -sk -o /dev/null -w "%{http_code}\n" https://hello-world${i}.devops.local/
done
```

---

## What Comes Next

After completing this gateway injection migration, your environment is ready for the **OSSM 3 migration** described in your main guide (`Step-by-Step Migration Guide_ OpenShift Service Mesh 2 to Service Mesh 3.md`). Specifically:

- The canary gateway Deployment (`istio-ingressgateway-canary`) becomes your new OSSM 3 gateway. You may rename it to `istio-ingressgateway` and move it to the `istio-ingress` namespace as described in Phase 4 of the main guide.
- The TLS Secrets (`hello-world1` through `hello-world8`) must still be copied to the new gateway namespace.
- The OpenShift Routes must still be recreated manually (IOR is not present in OSSM 3).

---

## Troubleshooting

### Gateway pods not starting

Check the injection webhook logs:

```bash
oc logs -n istio-system -l app=istiod --tail=50
```

Verify the `inject.istio.io/templates: gateway` annotation is present in the pod template.

### Traffic not shifting

Check that the Service selector matches the canary deployment labels:

```bash
oc get svc istio-ingressgateway -n istio-system -o yaml
oc get pods -n istio-system -l app=istio-ingressgateway --show-labels
```

### NetworkPolicy blocking access

If `spec.security.manageNetworkPolicy` was `true`, the SMCP auto-created NetworkPolicies. After disabling the old gateway, ensure the new gateway has equivalent network policy access. The `gatewayingress` NetworkPolicy in Step 1 should cover this.

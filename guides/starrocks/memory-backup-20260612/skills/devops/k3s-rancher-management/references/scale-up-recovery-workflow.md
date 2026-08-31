# Scale-Up Recovery Workflow

When restoring a namespace that was fully scaled down (deployments + statefulsets at 0), use this diagnostic workflow to identify and fix all missing dependencies.

## Quick Diagnostic Steps

```bash
# 1. Check ALL resource types, not just deployments
kubectl get deploy,sts -n <namespace>

# 2. Check which services have no backing pods
kubectl get endpoints -n <namespace>

# 3. If a pod is CrashLoopBackOff with "operation not permitted" 
#    in a Cilium cluster without network policies,
#    the target service's endpoint likely doesn't exist
kubectl logs -n <namespace> <crashing-pod> --tail=15
```

## Real Example: Harbor Recovery

When Harbor was fully scaled down (Deployments + StatefulSets at 0):

| Resource Type | Missing Components | Fix |
|--------------|-------------------|-----|
| Deployments | core, jobservice, nginx, portal, registry | `kubectl scale deployment -n harbor --replicas=1 ...` |
| StatefulSets | harbor-database, harbor-redis, harbor-trivy | `kubectl scale statefulset -n harbor --replicas=1 ...` |

### Symptoms

- `harbor-core`: CrashLoopBackOff with `dial tcp <redis-ip>:6379: connect: operation not permitted`
- `harbor-jobservice`: CrashLoopBackOff with `Get "http://harbor-core:80/api/v2.0/internalconfig": connect: operation not permitted`

### Root Cause

Both errors were **not** Cilium policy blocks. The `operation not permitted` error in Cilium kube-proxy-replacement mode means the target ClusterIP has **no endpoints** — the pod backing that service doesn't exist.

### Resolution Order

1. Check endpoints: `kubectl get endpoints -n harbor` → `harbor-redis <none>`, `harbor-database <none>`
2. Check statefulsets: `kubectl get sts -n harbor` → harbor-database (0/0), harbor-redis (0/0), harbor-trivy (0/0)
3. Scale all statefulsets to 1
4. Existing deployments auto-recover once databases are available (may take 1-2 minutes)

### Verification

```bash
# After all statefulsets are Running:
kubectl get endpoints -n harbor    # All should have endpoint IPs
kubectl get pod -n harbor          # All should be 1/1 Running (jobservice may restart a few times)
```

## Key Insight: `operation not permitted` in Cilium

In a Cilium cluster with `kube-proxy-replacement: true` (no kube-proxy), the error `connect: operation not permitted` when dialing a ClusterIP:

1. **Does NOT** mean a CiliumNetworkPolicy is blocking traffic (those return different errors)
2. **Usually** means the backing pod doesn't exist → endpoints are `<none>` → Cilium's BPF kube-proxy replacement can't route the packet
3. **Fix**: Check endpoints first, then find and scale up the missing pod

Exception: Real policy blocks produce `connection refused` or timeouts, not `operation not permitted`.

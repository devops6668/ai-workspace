# Session: Full Cluster Workload Recovery (2026-06-11)

## Context

Homelab k3s cluster (single node: k3s-luban, 192.168.48.111). Cilium with kube-proxy-replacement=true, no kube-proxy. ArgoCD installed via community Helm chart. Harbor installed via Harbor Helm chart.

All workloads had been scaled to 0 for 63-202 days. After scaling Deployments to 1, several services failed to start.

## Harbor Recovery

### Initial Symptom
- harbor-core and harbor-jobservice in CrashLoopBackOff
- Error: `dial tcp <ClusterIP>:6379: connect: operation not permitted` (redis)
- Error: `dial tcp <ClusterIP>:80: connect: operation not permitted` (core from jobservice)

### Investigation
1. Checked CiliumNetworkPolicies — none exist
2. Checked CiliumClusterwideNetworkPolicies — none exist
3. Checked Cilium status — healthy, kube-proxy-replacement=true
4. Checked endpoints → `harbor-redis` had `<none>`, `harbor-database` had `<none>`
5. Found `kubectl get sts -n harbor` showed database, redis, trivy all at 0/0

### Fix
```bash
kubectl scale sts -n harbor --replicas=1 harbor-database harbor-redis harbor-trivy
```

### Timeline
- Redis came up in ~18s → then harbor-core connected successfully → then jobservice connected to core → all Running

### Key Insight
"operation not permitted" with Cilium kube-proxy-replacement = missing service endpoints, NOT network policy blocking.

## ArgoCD Recovery

### Initial Symptom
- All 6 ArgoCD Deployment pods Running
- Application REFRESH had no effect — status was stale (last reconciled 2 days ago)
- `argocd.argoproj.io/refresh: normal` annotation set but nothing processed it

### Investigation
1. `kubectl get deploy -n argocd` → 6 deployments, all 1/1
2. `kubectl get sts -n argocd` → argo-cd-argocd-application-controller at 0/0
3. No application-controller pod exists

### Fix
```bash
kubectl scale sts -n argocd --replicas=1 argo-cd-argocd-application-controller
# After controller started:
kubectl annotate application -n argocd <app> argocd.argoproj.io/refresh-
kubectl annotate application -n argocd <app> argocd.argoproj.io/refresh=normal
```

### Key Insight
ArgoCD application-controller is a StatefulSet, not a Deployment. Without it, refresh/sync operations are silently dropped.

## Cert-manager Recovery
- Scaled deployments to 1 → all 3 pods Running within 34s
- No issues.

## Keycloak Recovery
- Scaled operator deployment + devops-kc and postgresql-db StatefulSets to 1
- All Running within ~65s
- No issues.

## Kpack Recovery
- Scaled controller + webhook deployments to 1
- Images from ghcr.nju.edu.cn mirror pulling for 13+ minutes
- Kpack uses a Chinese ghcr mirror (ghcr.nju.edu.cn) which may be slow

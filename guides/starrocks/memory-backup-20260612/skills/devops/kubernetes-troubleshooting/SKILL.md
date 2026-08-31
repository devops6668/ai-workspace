---
name: kubernetes-troubleshooting
description: "Diagnose Kubernetes services, workloads, and controllers that fail silently or won't start — covering Cilium connectivity, scaled-to-zero resources, ArgoCD controller state, and missing endpoints."
version: 1.0.0
author: Hermes Agent
tags: [kubernetes, troubleshooting, cilium, argocd, networking, workloads]
---

# Kubernetes Troubleshooting

## Overview

Kubernetes services can fail in deceptive ways — pods restart, operations silently drop, or ClusterIP connections return cryptic errors. This skill systematizes diagnosing the most common failure patterns when workloads don't respond.

**Core principle:** When a service won't start or an operation fails silently, check the data path end-to-end: **controller → pod → service → endpoints → connectivity**.

## When to Use

- A workload was scaled to 0 and doesn't come back properly after scaling up
- Pods CrashLoopBackOff with "operation not permitted" or "connection refused" to ClusterIP services
- An ArgoCD application won't refresh, sync, or shows stale status
- `kubectl get endpoints` shows `<none>` for a service you expected to work
- Connections between pods to ClusterIPs fail with no CiliumNetworkPolicy blocking them

---

## Failure Pattern 1: Scaled-to-Zero Workloads

**Trigger:** A namespace's deployments were scaled to 0 (or the namespace was "stopped"), and scaling the deployments back to 1 doesn't bring everything up.

### Diagnosis

```bash
# Check ALL resource types — don't just check Deployments
kubectl get deploy -n <ns>
kubectl get sts -n <ns>
kubectl get endpoints -n <ns>
```

### Root Cause

Many Helm charts (Harbor, Keycloak, etc.) deploy **both Deployments and StatefulSets**. The StatefulSets (database, redis, trivy, etc.) are often scaled to 0 separately and are easy to miss because `kubectl get deploy` doesn't show them.

### Fix

```bash
# Find scaled-to-zero StatefulSets
kubectl get sts -n <ns> | grep 0/0

# Scale them up
kubectl scale sts -n <ns> --replicas=1 <name-1> <name-2>
```

### Verification

```bash
# Check endpoints are populated
kubectl get endpoints -n <ns>

# Check pods are Running
kubectl get pod -n <ns>
```

---

## Failure Pattern 2: "operation not permitted" with Cilium

**Trigger:** Pods CrashLoopBackOff with `dial tcp <ClusterIP>:<port>: connect: operation not permitted`.

### Diagnosis

```bash
# 1. Check if CiliumNetworkPolicies exist (surprisingly, usually NOT the root cause)
kubectl get ciliumnetworkpolicies -A
kubectl get ciliumclusterwidenetworkpolicies

# 2. Check if the TARGET service has endpoints
kubectl get endpoints -n <ns> <service-name>
```

### Root Cause

With Cilium's `kube-proxy-replacement: true`, when a service has **no endpoints** (no backing pod), connecting to its ClusterIP returns `connect: operation not permitted` — NOT `connection refused`. This is a Cilium-specific signal meaning "this ClusterIP has nowhere to send traffic."

The pod backing the service is either:
- Scaled to 0 (see Pattern 1)
- CrashLooping
- Pending (not scheduled, pulling image, etc.)

### Fix

Find and fix why the backing pod isn't running. Once the pod is Ready, the endpoint appears and the error resolves.

### Verification

```bash
kubectl get endpoints -n <ns> <service-name>
# Should show an IP:port, not <none>
```

### Pitfall

Do NOT waste time writing CiliumNetworkPolicies. No policies exist by default in most setups — the error is from missing endpoints, not policy rejection.

---

## Failure Pattern 3: ArgoCD Operations Silently Fail

**Trigger:** ArgoCD UI shows stale application status, refresh doesn't update apps, sync buttons don't respond. The pod listing looks fine (server, repo-server, redis all Running).

### Diagnosis

```bash
# Check if application-controller exists — it is a STATEFULSET, not a Deployment
kubectl get sts -n argocd | grep application-controller
kubectl get pods -n argocd | grep application-controller
```

### Root Cause

ArgoCD's **application-controller** is deployed as a **StatefulSet** (not a Deployment). When ArgoCD was scaled to 0, the application-controller was left at 0 replicas as well. Without it:

- REFRESH operations are silently dropped (no error, no retry)
- Application reconciliation never runs
- `argocd.argoproj.io/refresh: normal` annotations accumulate with no effect

### Fix

```bash
kubectl scale sts -n argocd --replicas=1 argo-cd-argocd-application-controller

# Trigger fresh refresh after controller starts
kubectl annotate application -n argocd <app-name> argocd.argoproj.io/refresh-
kubectl annotate application -n argocd <app-name> argocd.argoproj.io/refresh=normal

# Or refresh all apps
for app in $(kubectl get application -n argocd -o name); do
  name=$(echo "$app" | cut -d/ -f2)
  kubectl annotate application -n argocd "$name" argocd.argoproj.io/refresh- 2>/dev/null
  kubectl annotate application -n argocd "$name" argocd.argoproj.io/refresh=normal
done
```

### Verification

```bash
kubectl logs -n argocd statefulset/argo-cd-argocd-application-controller --tail=20 | grep -E "Refreshing|Update successful|Reconciliation completed"
kubectl get application -n argocd
```

---

## General: Service Endpoint Checklist

When a Kubernetes service isn't reachable, follow this order:

```
1. kubectl get endpoints -n <ns> <service>    ← Backend pods exist?
2. kubectl get pod -n <ns>                     ← Pods Running?
3. kubectl describe pod -n <ns> <pod>          ← Pod events (pulling, error)?
4. kubectl logs -n <ns> <pod> --tail=20        ← Pod errors?
5. kubectl get svc -n <ns> <service> -o yaml   ← selectors match pod labels?
6. kubectl get ciliumnetworkpolicies -A        ← Only check AFTER endpoints
```

Most service issues are caught at step 1 or 2. Start there.

---

## Failure Pattern 4: kpack Build Pods Fail with DNS Errors

**Trigger:** kpack build pods fail at the dependency install step with:
```
Caused by: dns error
Caused by: failed to lookup address information: Name does not resolve
```

**Root Cause:** kpack build containers run with `dnsPolicy: ClusterFirst`, so they resolve DNS through CoreDNS. If a custom PyPI mirror uses a `.local` domain (e.g., `nexus.paulhome.local`), CoreDNS won't resolve it unless explicitly configured — DNS returns `NXDOMAIN` even though the IP is reachable.

### Fix: Add the hostname to CoreDNS NodeHosts

```bash
# 1. Check current NodeHosts
kubectl get cm -n kube-system coredns -o jsonpath='{.data.NodeHosts}'

# 2. Add the missing host entry — the hosts plugin falls through to forward if not found
kubectl patch cm -n kube-system coredns --type merge \
  -p '{"data":{"NodeHosts":"<existing-entries>\n<IP> <hostname>.paulhome.local"}}'

# 3. Restart CoreDNS to pick up the change
kubectl rollout restart -n kube-system deployment/coredns

# 4. Verify from a test pod
kubectl run dns-test --image=busybox:1.36 --restart=Never -- sh -c "nslookup <hostname>.paulhome.local"
```

### Alternative: Add to /etc/hosts on the node

For a more permanent fix outside CoreDNS lifecycle, add the host to the node's `/etc/hosts`.

### Verification

```bash
# Test HTTP connectivity from a pod
kubectl run curl-test --image=curlimages/curl:8.12.1 --restart=Never -- sh -c \
  "curl -s -o /dev/null -w '%{http_code}' http://<hostname>.paulhome.local:<port>/"
```

When encountering a connectivity error from inside a pod:

```bash
# Test from a temporary debug pod
kubectl run debug --image=busybox:1.36 --restart=Never -- sh -c "nc -zv -w5 <ClusterIP> <port>; echo exit:\$?"
kubectl logs debug
kubectl delete pod debug --force --grace-period=0
```

Use the `terminal` tool for all kubectl commands. Use `read_file` for large YAML output that the `terminal` tool would truncate.

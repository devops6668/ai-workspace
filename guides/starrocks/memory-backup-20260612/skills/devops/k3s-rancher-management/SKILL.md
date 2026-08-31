---
name: k3s-rancher-management
description: "Manage K3s clusters and troubleshoot Rancher agent connectivity — start/stop k3s, manage nodes, diagnose cattle-cluster-agent issues, and resolve DNS/CoreDNS problems with external Rancher servers."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [k3s, rancher, kubernetes, devops, troubleshooting, dns]
    related_skills: []
---

# K3s & Rancher Management

Covers day-2 operations for K3s clusters connected to an external Rancher server: starting/stopping, node management after hostname changes, and Rancher agent connectivity troubleshooting.

## K3s Lifecycle

### Start k3s
```bash
systemctl start k3s
systemctl is-active k3s
```

### Enable or disable auto-start at boot
```bash
# Enable (k3s starts automatically after reboot)
systemctl enable k3s

# Disable (must manually start k3s after reboot)
systemctl disable k3s
```

When disabled at boot, the full startup sequence after a reboot is:
```bash
sudo systemctl start k3s                     # Start k3s
kubectl wait --for=condition=ready --all-namespaces --all --timeout=120s   # Wait for all pods to settle
```

### Check status
```bash
k3s kubectl get nodes -o wide
k3s kubectl get pods -A
```

## Node Management

### List nodes
```bash
k3s kubectl get nodes -o wide
```

### Remove a stale node (e.g., after hostname rename)
When a node's hostname was changed and a new node joined with the new name, the old node entry remains in the cluster with stale heartbeats (all conditions `Unknown`). Remove it:

```bash
k3s kubectl delete node <old-node-name>
```

After deletion, pods on the old node terminate and are rescheduled to the remaining nodes.

## Rancher Agent Troubleshooting

### Check agent pod status
```bash
k3s kubectl get pods -n cattle-system -o wide
k3s kubectl describe pod -n cattle-system -l app=cattle-cluster-agent
```

### Check agent logs for connection issues
```bash
# Current logs
k3s kubectl logs -n cattle-system deployment/cattle-cluster-agent --tail=50

# Previous pod logs (if crash-looping)
k3s kubectl logs -n cattle-system deployment/cattle-cluster-agent --previous

# Filter for connection/auth errors
k3s kubectl logs -n cattle-system deployment/cattle-cluster-agent 2>&1 | grep -iE "error|fail|denied|refused|unable|cannot|timeout|connect|dial|tls|cert|token|unauthorized|forbidden|websocket|register"
```

### Check rancher-webhook status
```bash
k3s kubectl logs -n cattle-system deploy/rancher-webhook --tail=20
```

### Check agent service endpoint
```bash
k3s kubectl get svc -n cattle-system cattle-cluster-agent
k3s kubectl get endpoints -n cattle-system cattle-cluster-agent
```

### Verify Rancher server connectivity
```bash
# From the node:
curl -sk https://rancher.paulhome.local/ping
echo | openssl s_client -connect rancher.paulhome.local:443 -servername rancher.paulhome.local 2>&1 | openssl x509 -noout -subject -dates -issuer

# From within the agent pod (if it's Running):
k3s kubectl exec -n cattle-system deploy/cattle-cluster-agent -- sh -c "curl -sk --connect-timeout 5 https://rancher.paulhome.local/ping"
```

### Check credentials secret
```bash
k3s kubectl get secret -n cattle-system cattle-credentials-* -o yaml | grep -A2 "data:"
# Decode: echo '<base64>' | base64 -d
```

## DNS Troubleshooting (CoreDNS + `.local` domains)

The most common cause of Rancher agent crash-looping is **DNS resolution flakiness** for `.local` domains when CoreDNS is the nameserver.

### Symptoms
- Agent pod restarts repeatedly (`Back-off restarting failed container`)
- Previous pod logs show: `ERROR: https://rancher.paulhome.local/ping is not accessible (Could not resolve host: rancher.paulhome.local)`
- Current pod starts successfully but previous ones all failed

### Root cause
The default pod DNS config uses `ndots:5` and search domains:
```
search cattle-system.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.41.0.10
options ndots:5
```

When querying `rancher.paulhome.local`:
1. CoreDNS tries appending each search domain first (because `.local` has fewer than 5 dots)
2. `rancher.paulhome.local.cattle-system.svc.cluster.local` → NXDOMAIN
3. `rancher.paulhome.local.svc.cluster.local` → NXDOMAIN
4. `rancher.paulhome.local.cluster.local` → might get trapped by mDNS or return unexpected results
5. The `.local` TLD triggers mDNS (Avahi) on some systems, which can interfere

This causes intermittent failures because the search-domain expansion order + ndots + mDNS interaction isn't deterministic.

### Fixes

**Fix A: Cluster-wide — CoreDNS NodeHosts (permanent, covers all pods)**

For `.local` domains that should resolve across the entire cluster (e.g., nexus, harbor, rancher), add entries to the CoreDNS `NodeHosts`. This is a single change that fixes resolution for all pods — no need to patch each deployment.

```bash
# 1. Check current entries
kubectl get cm -n kube-system coredns -o jsonpath='{.data.NodeHosts}'

# 2. Add your .local hostname(s) to NodeHosts
kubectl patch cm -n kube-system coredns --type merge \
  -p '{"data":{"NodeHosts":"<existing-entries>\n<IP> <hostname.paulhome.local>"}}'

# 3. Reload CoreDNS to pick up the change
kubectl rollout restart -n kube-system deployment/coredns
kubectl rollout status -n kube-system deployment/coredns --timeout=30s

# 4. Verify from a test pod
kubectl run dns-test --image=busybox:1.36 --restart=Never -- sh -c "nslookup <hostname>.paulhome.local 2>&1"
kubectl logs dns-test
kubectl delete pod dns-test --force --grace-period=0
```

The Corefile uses a `hosts` plugin that reads `NodeHosts` with a `fallthrough` (passes to upstream DNS if not found). After the restart, CoreDNS serves the static entry before falling through to `/etc/resolv.conf`.

> **Caveat**: The `NodeHosts` ConfigMap key may be overwritten by Rancher's cluster-management controller on sync cycles. If it gets reverted, switch to fix B or add a cronjob that re-applies the entry.

**Fix B: Per-deployment `hostAliases` (targeted, survives Rancher sync)**
```bash
k3s kubectl patch deployment -n cattle-system cattle-cluster-agent --patch '{
  "spec": {
    "template": {
      "spec": {
        "hostAliases": [
          {
            "ip": "<RANCHER_SERVER_IP>",
            "hostnames": ["rancher.paulhome.local"]
          }
        ]
      }
    }
  }
}'
```

The deployment rolls out automatically. Verify:
```bash
k3s kubectl rollout status -n cattle-system deployment/cattle-cluster-agent --timeout=60s
```

This is superior to `/etc/hosts` on the node because DNS resolution happens **inside the pod**, not on the host. The `hostAliases` field injects the entry directly into the pod's `/etc/hosts` so it bypasses CoreDNS entirely.

**Node-level fallback** (less effective — only helps commands run directly on the node, not inside pods):
```bash
echo "192.168.89.61 rancher.paulhome.local" >> /etc/hosts
```

**Alternative: Use a proper FQDN with trailing dot**
If you control the Rancher server URL configuration, use a non-`.local` domain or ensure `rancher.paulhome.local.` (with trailing dot) is used.

**Alternative: Add a CoreDNS rewrite**
Patch the CoreDNS ConfigMap to bypass search domain expansion for this domain.

## Rancher Agent Architecture Notes

- The cattle-cluster-agent uses WebSocket (`wss://`) to connect to the Rancher server at `/v3/connect/register`
- It authenticates with a token from the `cattle-credentials-*` secret in `cattle-system`
- The agent runs in "single server mode" by default (no peering)
- Starting up involves: DNS resolution → HTTPS ping → TLS cert validation → WebSocket tunnel → leader election → controller startup
- After successful connection, the agent produces minimal logs (no periodic heartbeat messages)
- A missing "Connected to proxy" message after "Connecting to proxy" does NOT necessarily mean it's disconnected — Rancher agent doesn't always log the connection success
- The agent runs an internal listener on port 80/444 that the Rancher server uses to send requests back to the cluster

## Pitfalls

- **Don't assume "no logs" = disconnected** — the agent is quiet when healthy. Check via `describe pod` events for crash-loop signals instead.
- **`.local` domains are treacherous in Kubernetes** — they interact badly with ndots, search domains, and mDNS/Avahi. Always prefer non-`.local` hostnames for Rancher server URLs.
- **Node rename breaks Rancher** — if you change the hostname and rejoin k3s, the old node stays in etcd as `NotReady`/`Unknown`. Delete it with `kubectl delete node <old-name>`.
- **After deleting a stale node**, pods on that node go `Terminating` and new pods need to spin up on the remaining node. Give it 30-60 seconds to settle.
- **Previous pod logs are key** — the current pod might look healthy while all prior restarts had errors. Always check `--previous` when investigating crash loops.
- **Node rename breaks Rancher** — if you change the hostname and rejoin k3s, the old node stays in etcd as `NotReady`/`Unknown`. Delete it with `kubectl delete node <old-name>`.
- **After deleting a stale node**, pods on that node go `Terminating` and new pods need to spin up on the remaining node. Give it 30-60 seconds to settle.
- **Previous pod logs are key** — the current pod might look healthy while all prior restarts had errors. Always check `--previous` when investigating crash loops.
- **Don't restart the agent pod** — a deployment manages it. If it needs resetting, delete the pod and let the deployment recreate it.
- **Verified DNS != consistent DNS** — a single `curl` to `/ping` succeeding doesn't mean DNS is reliably working. Intermittent failures are the hallmark of the `.local` + ndots issue.
- **VMware/VM guest cannot read host CPU temps** — guest OS has no access to host thermal sensors. Detect with `lscpu | grep Hypervisor`. See `references/vmware-guest-sensor-limitations.md`.

## Exposing Services Externally (Quick-Reference)

When a service needs to be reachable from outside the cluster:

| Method | Best for | Setup |
|--------|----------|-------|
| **NodePort** | Quick testing, no extra resources | `kubectl patch svc <svc> -p '{"spec":{"type":"NodePort"}}'` |
| **Ingress** | Production, domain-based routing | Needs an Ingress Controller (Traefik, NGINX) |
| **LoadBalancer** | Cloud environments with LB support | `type: LoadBalancer` |

### NodePort (fastest way to expose a port on the node)

When you need to quickly expose a service and there's no Ingress Controller:

```bash
# Patch existing service to NodePort
k3s kubectl patch svc <service-name> -n <namespace> -p '{"spec":{"type":"NodePort","ports":[{"name":"https","port":8443,"targetPort":8443,"nodePort":30443}]}}'

# Verify
k3s kubectl get svc <service-name> -n <namespace>
# Output: 8443:30443/TCP means: cluster:8443 → pod:8443, node:30443

# Access from outside
curl -sk https://<NODE_IP>:<NODE_PORT>/...
```

### Pitfall: ClusterIP vs NodePort confusion

`ClusterIP` services are **not reachable from outside the cluster**. If you see a service with `EXTERNAL-IP: <none>` and type `ClusterIP`, it's only accessible from within K8s pods. To access from a browser on the host machine or your LAN, switch to NodePort (or use `kubectl port-forward`).

## Bulk Scale Operations

### Scale DOWN all Deployments & StatefulSets (excluding system namespaces)

Useful for stopping non-essential workloads (e.g., to save resources). Excludes `kube-*`, `kubernetes-*`, `cattle-*` namespaces.

Script: `scripts/scale-down-system.sh`

```bash
# Save as scale-down.sh then run:
# bash scale-down.sh

for ns in $(kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null | sort); do
    # Skip excluded namespaces
    [[ "$ns" == kube-* ]] || [[ "$ns" == kubernetes-* ]] || [[ "$ns" == cattle-* ]] && continue
    
    # Scale deployments to 0
    kubectl scale deployments --all -n "$ns" --replicas=0 2>/dev/null
    # Scale statefulsets to 0
    kubectl scale statefulsets --all -n "$ns" --replicas=0 2>/dev/null
    # Note: DaemonSets cannot be scaled to 0
done
```

When recovering from a full scale-down, see `references/scale-up-recovery-workflow.md` for diagnostics when pods CrashLoopBackOff after being restored — covering `operation not permitted` errors in Cilium environments and missing StatefulSet dependencies (Harbor, Keycloak, etc.).

### Scale UP all Deployments & StatefulSets

```bash
for ns in $(kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null | sort); do
    [[ "$ns" == kube-* ]] || [[ "$ns" == kubernetes-* ]] || [[ "$ns" == cattle-* ]] && continue
    kubectl scale deployments --all -n "$ns" --replicas=1 2>/dev/null
    kubectl scale statefulsets --all -n "$ns" --replicas=1 2>/dev/null
done
```

### Pitfalls

- **DaemonSets cannot be scaled to 0** — they always run at least one pod per matching node. They will show as `Not scaled` but are not errors.
- **Use individual `kubectl scale` per resource** rather than `--all` because `--all` on a namespace with no deployments returns error code 1 and stops the loop.
- **StatefulSets may require manual reconciliation** — scaling to 0 then 1 may not restart pods in the same order; check `kubectl get sts -A` after scaling up.
- **System namespaces** (`kube-*`, `kubernetes-*`, `cattle-*`) must be excluded — scaling these to 0 can break cluster operations.
- **When restoring a fully scaled-down Helm workload, always check StatefulSets too** — many Helm charts (Harbor, Keycloak, databases) use StatefulSets for backing services (Redis, PostgreSQL, Trivy). These are often scaled to 0 alongside Deployments and won't show up with `kubectl get deploy`. Always run `kubectl get sts -n <ns>` and `kubectl get endpoints -n <ns>` to identify missing backing services.
- **`connect: operation not permitted` in a Cilium cluster without network policies** — despite suggesting a policy block, this error in Cilium kube-proxy-replacement mode (no kube-proxy) usually means **the target service's endpoint doesn't exist** (the backing pod is down or never started). Check endpoints first: `kubectl get endpoints -n <ns>`. If endpoints are `<none>`, scale up the missing pod, don't chase Cilium policies.

## Argoworks Workflow Template: CA Cert Injection for On-Prem TLS

When workflows interact with on-prem endpoints (Harbor API, git provisioner), inject `luban-ca-cert` secret for TLS verification.

### Pattern (Argo Workflows v4 strict mode)

```yaml
spec:
  # DO NOT declare volumes at template root when using templateRef
  # Instead, declare volumes in the template that references it
  templates:
    - name: git-clone
      container:
        env:
        - name: SSL_CERT_FILE
          valueFrom:
            secretKeyRef:
              name: luban-ca-cert
              key: ssl_cert_file
              optional: true
        - name: REQUESTS_CA_BUNDLE
          valueFrom:
            secretKeyRef:
              name: luban-ca-cert
              key: requests_ca_bundle
              optional: true
        - name: GIT_SSL_CAINFO
          valueFrom:
            secretKeyRef:
              name: luban-ca-cert
              key: git_ssl_cainfo
              optional: true
        - name: CURL_CA_BUNDLE
          valueFrom:
            secretKeyRef:
              name: luban-ca-cert
              key: curl_ca_bundle
              optional: true
        volumeMounts:
        - name: luban-ca-cert
          mountPath: /var/run/luban/ca
          readOnly: true
  volumes:
  - name: luban-ca-cert
    secret:
      secretName: luban-ca-cert
      optional: true
```

### Key rules

- **When using `templateRef`**: volumes must be declared in the **referenced template**, not the caller. Declaring in the caller causes validation errors under `templateReferencing: Strict`.
- **Always set `optional: true`** — the CA cert secret may not exist in all environments.
- **Mount at `/var/run/luban/ca`** for consistency across all workflow templates.
- **Common env vars**: `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `CURL_CA_BUNDLE`.

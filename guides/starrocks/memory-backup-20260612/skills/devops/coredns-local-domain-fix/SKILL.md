---
name: coredns-local-domain-fix
description: "Fix .local domain resolution in k3s/Cilium clusters by adding host entries to CoreDNS NodeHosts"
version: 1.0.0
author: Hermes Agent
---

# CoreDNS .local Domain Resolution Fix

## When to use

Build pods (kpack), curl containers, or any pod using `dnsPolicy: ClusterFirst` cannot resolve `.local` hostnames (e.g., `nexus.paulhome.local`, `rancher.paulhome.local`). CoreDNS uses the `hosts` plugin with a `NodeHosts` file, and `.local` domains are not in it.

## Root cause

The k3s + Rancher CoreDNS config uses:
```yaml
hosts /etc/coredns/NodeHosts {
  ttl 60
  reload 15s
  fallthrough
}
forward . /etc/resolv.conf
```

The `NodeHosts` file (from the coredns ConfigMap) only contains auto-populated node entries. Custom `.local` domains must be added manually.

## Fix

### 1. Check current NodeHosts
```bash
kubectl get cm -n kube-system coredns -o jsonpath='{.data.NodeHosts}'
```

### 2. Add missing host entries
```bash
kubectl patch cm -n kube-system coredns --type merge \
  -p '{"data":{"NodeHosts":"<existing entries>\n<IP> <hostname>"}}'
```

Example for `nexus.paulhome.local`:
```bash
kubectl patch cm -n kube-system coredns --type merge \
  -p '{"data":{"NodeHosts":"10.41.107.180 fleet-server-agent-http.elastic.svc.cluster.local\n192.168.48.111 k3s-luban\n192.168.89.61 nexus.paulhome.local"}}'
```

### 3. Reload CoreDNS
```bash
kubectl rollout restart -n kube-system deployment/coredns
```

### 4. Verify
```bash
kubectl run dns-test --image=busybox:1.36 --restart=Never \
  -- sh -c "nslookup <hostname> 10.41.0.10"
kubectl delete pod dns-test --force --grace-period=0
```

## Pitfalls

- The NodeHosts file is managed by Rancher/k3s — custom entries may be overwritten on node updates. Monitor after upgrades.
- Adding too many entries to NodeHosts is fine but keep it minimal.
- Use `fallthrough` in the hosts plugin block (already in default Corefile) so unmatching queries fall through to `forward . /etc/resolv.conf`.

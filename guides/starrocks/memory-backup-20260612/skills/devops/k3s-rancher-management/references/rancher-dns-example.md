# Rancher DNS Troubleshooting — Real Example

## Scenario

k3s cluster imported into an external Rancher server at `https://rancher.paulhome.local` (resolves to `192.168.89.61`).

## Problem

The `cattle-cluster-agent` pod kept crash-looping. The pod ran on a node whose hostname had been changed from `cluster1` to `k3s-luban`.

**Pod events:**
```
Warning  BackOff  Back-off restarting failed container cluster-register
```

**Previous pod logs:**
```
ERROR: https://rancher.paulhome.local/ping is not accessible
       (Could not resolve host: rancher.paulhome.local)
```

Current pod logs showed success — DNS was resolving intermittently.

## Root Cause

`rancher.paulhome.local` uses a `.local` TLD. The pod's `resolv.conf`:

```
search cattle-system.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.41.0.10
options ndots:5
```

CoreDNS (`10.41.0.10`) struggles with `.local` domains due to mDNS/avahi interference and search domain expansion.

## Fix Applied

```bash
kubectl patch deployment -n cattle-system cattle-cluster-agent --patch '{
  "spec": {
    "template": {
      "spec": {
        "hostAliases": [
          {
            "ip": "192.168.89.61",
            "hostnames": ["rancher.paulhome.local"]
          }
        ]
      }
    }
  }
}'
```

Verified hostAliases were applied:
```bash
kubectl get pod -n cattle-system -l app=cattle-cluster-agent \
  -o jsonpath='{.items[0].spec.hostAliases}'
# Output: [{"hostnames":["rancher.paulhome.local"],"ip":"192.168.89.61"}]
```

Agent came up cleanly:
```
INFO: https://rancher.paulhome.local/ping is accessible
INFO: Connecting to wss://rancher.paulhome.local/v3/connect/register
```

## Verification Commands

```bash
# From the node
curl -sk https://rancher.paulhome.local/ping
# → pong

# From the pod
kubectl exec -n cattle-system deploy/cattle-cluster-agent -- \
  curl -sk --connect-timeout 5 https://rancher.paulhome.local/ping
# → pong

# Check agent service endpoints
kubectl get endpoints -n cattle-system cattle-cluster-agent
# Should show the new pod's IP
```

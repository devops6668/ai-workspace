# Rancher Agent DNS Crash-Loop Diagnosis

## Symptom Pattern

The cattle-cluster-agent pod shows multiple restarts (`RESTARTS: 4+`) but the current pod is `Running`.

```bash
k3s kubectl describe pod -n cattle-system -l app=cattle-cluster-agent
```
Events show `Back-off restarting failed container`.

## Diagnostic Steps

### 1. Check previous pod logs
```bash
k3s kubectl logs -n cattle-system deployment/cattle-cluster-agent --previous
```
If the previous log shows:
```
ERROR: https://rancher.paulhome.local/ping is not accessible (Could not resolve host: rancher.paulhome.local)
```
...the issue is DNS, not the Rancher server or credentials.

### 2. Verify Rancher server is reachable
```bash
curl -sk https://rancher.paulhome.local/ping                 # Should return "pong"
curl -sk -o /dev/null -w "%{http_code}" https://rancher.paulhome.local/v3/connect/register  # Should return 401 (needs auth)
echo | openssl s_client -connect rancher.paulhome.local:443 -servername rancher.paulhome.local 2>&1 | openssl x509 -noout -subject -dates -issuer
```

### 3. Check DNS resolution
```bash
nslookup rancher.paulhome.local
```
Note: a successful result alongside `NXDOMAIN` is the hallmark of ndots + search-domain expansion interfering.

### 4. Check the pod's DNS config
From the startup logs:
```
Using resolv.conf: search cattle-system.svc.cluster.local svc.cluster.local cluster.local nameserver 10.41.0.10 options ndots:5
```

### 5. Confirm the credentials are valid
```bash
k3s kubectl get secret -n cattle-system cattle-credentials-* -o yaml
```
Decode url and token with `base64 -d`. Verify url matches the Rancher server and the token starts with the same value seen in agent logs (`Connecting to wss://... with token starting with ...`).

### 6. Check agent service endpoint
```bash
k3s kubectl get endpoints -n cattle-system cattle-cluster-agent
```
Should show the current pod's IP on ports 80 and 444.

## Resolution

There are two approaches. Prefer approach A (it fixes DNS inside the pod).

### Approach A: Patch the Deployment with `hostAliases` (Recommended)

This injects the host entry directly into the pod's `/etc/hosts`, bypassing CoreDNS entirely.

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

Wait for rollout:
```bash
k3s kubectl rollout status -n cattle-system deployment/cattle-cluster-agent --timeout=60s
```

Why not `/etc/hosts` on the node? The agent's DNS resolution happens **inside the pod's network namespace**, not on the host. A node-level `/etc/hosts` entry only helps commands run directly on the node (like `curl` from the host shell), not the agent container.

### Approach B: Add `/etc/hosts` on the node (Fallback)

Only helps if the issue is with node-level tools troubleshooting. Does not fix the pod issue:

```bash
echo "<rancher-server-ip> rancher.paulhome.local" >> /etc/hosts
```

Then delete the stale agent pod to force an immediate restart:
```bash
k3s kubectl delete pod -n cattle-system -l app=cattle-cluster-agent
```

Wait 30-60 seconds, then verify:
```bash
k3s kubectl logs -n cattle-system deployment/cattle-cluster-agent --tail=5
```
The initial log line should show `rancher.paulhome.local/ping is accessible`.

## Full Startup Sequence (healthy agent)
1. `https://rancher.paulhome.local/ping is accessible`
2. `rancher.paulhome.local resolves to <IP>`
3. `Value from https://rancher.paulhome.local/v3/settings/cacerts is an x509 certificate`
4. `Connecting to wss://rancher.paulhome.local/v3/connect/register with token starting with <token>`
5. CRDs are applied and controllers start
6. `successfully acquired lease kube-system/cattle-controllers`
7. `Steve auth startup complete`
8. Agent goes quiet — no further log output unless activity triggers it

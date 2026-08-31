# Fleet Server Namespace Registration Bug

## Symptom

The Fleet Server (ECK Agent with `fleetServerEnabled: true`) registers itself in Kibana with an incorrect hostname URL. The namespace `elastic-system` gets truncated to `elastic`:

```
Registered:  https://fleet-server-agent-http.elastic.svc.cluster.local:8220
Correct:     https://fleet-server-agent-http.elastic-system.svc:8220
                               ^^^^^                        ^^^^^^^^^^
```

This causes all downstream Fleet-managed agents to:
1. Try to connect to `fleet-server-agent-http.elastic.svc.cluster.local` (DNS NXDOMAIN)
2. Even if DNS is fixed with CoreDNS hosts, TLS fails because the cert SANs don't include this wrong hostname

## Impact

- Fleet-managed agents (enrolled via ECK Agent CRD with `mode: fleet` + `fleetServerRef`) cannot receive policy updates
- The `Failed to dispatch action` error appears in agent logs
- APM, custom integrations, and any Fleet-managed components inside the agent won't start properly

## Root Cause

The Go DNS resolver in the Elastic Agent binary resolves the Fleet Server's FQDN differently than expected. The service name `fleet-server-agent-http.elastic-system.svc` gets resolved to `fleet-server-agent-http.elastic.svc.cluster.local` instead of the correct `fleet-server-agent-http.elastic-system.svc.cluster.local`.

This is likely a bug in the Elastic Agent's hostname parsing logic where hyphens in namespace names (`elastic-system`) cause incorrect truncation.

## Workaround: FLEET_INSECURE + CoreDNS hosts

There's no clean fix without patching the Elastic Agent binary. The best workaround:

### 1. Add both DNS names to CoreDNS NodeHosts

```bash
FLEET_IP=$(kubectl get svc -n elastic-system fleet-server-agent-http -o jsonpath='{.spec.clusterIP}')
kubectl patch cm -n kube-system coredns --type merge -p \
  "{\"data\":{\"NodeHosts\":\"$FLEET_IP fleet-server-agent-http.elastic-system.svc.cluster.local\\n$FLEET_IP fleet-server-agent-http.elastic.svc.cluster.local\"}}"
```

### 2. Set FLEET_INSECURE on the enrolled Agent

Add `FLEET_INSECURE=true` to the Agent's env to skip TLS verification (since the TLS cert won't match the wrong hostname):

```yaml
apiVersion: agent.k8s.elastic.co/v1alpha1
kind: Agent
metadata:
  name: my-fleet-agent
  namespace: elastic-system
spec:
  version: 8.15.0
  mode: fleet
  fleetServerRef:
    name: fleet-server
    namespace: elastic-system
  policyID: <policy-id>
  kibanaRef:
    name: kibana
    namespace: elastic-system
  deployment:
    replicas: 1
    podTemplate:
      spec:
        containers:
          - name: agent
            env:
              - name: FLEET_INSECURE
                value: "true"
```

### 3. Fleet Server hosts in Kibana settings

After the Fleet Server registers (with the wrong URL), manually update the Fleet Server hosts in Kibana:

```bash
ES_PASS=$(kubectl get secret -n elastic-system elastic-cluster-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
kubectl exec -n elastic-system kibana-kb-<hash> -- bash -c "
  curl -sk -X PUT 'https://localhost:5601/api/fleet/settings' \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -u 'elastic:\$ES_PASS' \
    -d '{\"fleet_server_hosts\":[\"https://fleet-server-agent-http.elastic-system.svc:8220\",\"https://fleet.luban.paulhome.local:443\"]}'
"
```

But this gets overwritten every time the Fleet Server pod restarts and re-registers. The CoreDNS workaround is more permanent.

## Affected Versions

- ECK: 3.4.0
- Elastic Agent: 8.15.0
- Likely affects all versions with namespaces containing hyphens

## Related: APM Integration in Fleet (Can't Change Host)

Even when an APM fleet agent successfully enrolls, the Fleet API forces the APM integration's `host` variable to `localhost:8200`. Attempts to set it to `0.0.0.0:8200` via the API (POST or PUT) are silently overridden by the package default.

**Effect:** The APM server inside a Fleet-managed agent only listens on the loopback interface and is NOT accessible from outside the pod. This makes Fleet-managed APM unsuitable for receiving traces from external sources.

**Workaround:** Use a standalone ECK `ApmServer` CRD instead of Fleet-managed APM when you need external APM traffic.

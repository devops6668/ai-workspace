# Fleet Server Setup on ECK

## Order of Operations

1. Create the Agent CR (Fleet Server) — it creates secrets, service, deployment, but pods won't start until the policy exists
2. Create the Fleet Server policy via Kibana API
3. Pre-create the hostPath state directory 
4. Delete the pod so it recreates with correct permissions

## Troubleshooting Log

### Issue 1: "Agent policy fleet-server-policy not found"

The ECK operator queries Kibana for a policy named `fleet-server-policy`. Without it, the operator stays at "Waiting for Kibana credentials" and never creates the deployment.

**Fix:** Create the policy manually via Kibana Fleet API (see skill section "Required: create Fleet Server policy in Kibana").

### Issue 2: "Association backend for kibana is not configured"

This is a transient ECK warning that appears during Fleet Server reconciliation. It usually resolves once the Kibana association controller establishes the association. If it persists, check:
- Operator logs for `agent-kibana` reconciliation errors
- Secret `fleet-server-agent-kb-user` exists and has data
- Kibana pod is healthy and accepts API calls

### Issue 3: State directory permission denied

The Fleet Server pod uses a `hostPath` volume at `/var/lib/elastic-agent/<ns>/<name>/state/`. Container runs as UID 1000. The directory must exist on the node with `chown 1000:1000`.

The deployment won't create the directory — it only mounts it. So if the directory doesn't exist, the agent logs:
```
Error: preparing STATE_PATH failed: mkdir /usr/share/elastic-agent/state/data: permission denied
```

**Fix:** Pre-create on node:
```bash
sudo mkdir -p /var/lib/elastic-agent/elastic-system/fleet-server/state/data
sudo chown -R 1000:1000 /var/lib/elastic-agent/
```

### Issue 4: Corrupted Fleet message signing keys

When Kibana is recreated, the encryption key for saved objects changes. Fleet's message signing keys are stored encrypted in `.kibana_ingest_*` and become undecryptable.

**Symptoms:**
- Kibana logs: `Failed to decrypt attribute "passphrase" of saved object "fleet-message-signing-keys,..."`
- ECK operator: `ECK cannot setup Fleet enrollment. Waiting for Kibana credentials.`

**Fix:** Delete the corrupted document using the Kibana SA token (the elastic superuser CANNOT write to `.kibana_ingest_*`):
```bash
KB_TOKEN=*** get secret kibana-kibana-user -n elastic-system -o jsonpath='{.data.token}' | base64 -d)
kubectl exec elastic-cluster-es-default-0 -n elastic-system -- bash -c "
  curl -sk -H 'Authorization: Bearer *** \
  -X DELETE 'https://localhost:9200/.kibana_ingest_*/_doc/fleet-message-signing-keys:<uuid>'
"
```

## Verification

```bash
curl -sk --resolve 'fleet.luban.paulhome.local:443:192.168.48.111' \
  https://fleet.luban.paulhome.local/api/status
# {"name":"fleet-server","status":"HEALTHY"}
```

## Service Details

| Detail | Value |
|--------|-------|
| Internal endpoint | `fleet-server-agent-http.elastic-system.svc:8220` |
| External endpoint | `https://fleet.luban.paulhome.local` |
| TLS cert SANs | `fleet-server-agent-http.elastic-system.svc`, `fleet-server-agent-http` |
| BackendTLS hostname | `fleet-server-agent-http.elastic-system.svc` |
| Health check | `GET /api/status` → `{"status":"HEALTHY"}` |
| Fleet port | 8220 |

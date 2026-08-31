# Kibana Readiness Probe: HTTP vs HTTPS Mismatch

## Scenario
- ECK 3.4.0 on k3s, Kibana 8.15.0
- `server.ssl.enabled: false` in Kibana config (set for Envoy Gateway compatibility)
- Pod shows `0/1 Running`, health `red`
- Readiness probe events: `http: server gave HTTP response to HTTPS client`

## Diagnosis Steps
1. `kubectl describe pod <kibana-pod> -n elastic-system` — shows probe scheme mismatch
2. `kubectl logs <kibana-pod> -n elastic-system --tail=80` — confirms Kibana IS running (`Kibana is now available` before probe errors)
3. Verify readiness probe scheme: pod spec shows `"scheme": "HTTPS"` while `server.ssl.enabled: false`
4. Check Kibana CR for last-applied-config annotation to see who changed the SSL setting

## Working Fixes
**Fix A (preferred — patch + reconcile):**
```bash
kubectl patch kibana kibana -n elastic-system --type merge -p '{"spec":{"config":{"server.ssl.enabled":"true"},"http":{"tls":{"certificate":{}}}}}'
```
ECK 3.4.0 reconciles this automatically: new pod gets TLS cert from `kibana-kb-http-certs-internal`, probe scheme updates to HTTPS, rollout proceeds. No delete/recreate needed.

**Fix B (delete + recreate):** Reliable fallback if patch doesn't roll out.

## What Doesn't Work
- `spec.http.tls.enabled` — NOT a valid Kibana CR field. Produces warning `"unknown field\"enabled\""`. Ignore.
- Annotation-only changes — ECK doesn't roll out pods on annotation changes alone.
- Non-existent TLS cert secret — if `kibana-kb-http-certs-internal` doesn't exist, ECK won't auto-generate it.

## Additional Observations (Session 2026-06-11)
- Non-fatal errors in logs: `EncryptedSavedObjects failed to decrypt "fleet-message-signing-keys"` — these are retry-loop warnings that do NOT prevent startup. Kibana logs "Kibana is now available" despite them.
- The `last-applied-configuration` annotation on the Kibana CR originally had `server.ssl.enabled: true` — someone later patched it to `false` for Envoy Gateway but forgot about the readiness probe side effect.
- Service port is named `https` (5601) even when SSL is disabled — this is by design in ECK, not a bug.

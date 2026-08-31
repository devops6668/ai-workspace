---
name: keycloak-administration
description: "Administer Keycloak on Kubernetes — recover admin access, configure LDAP user federation, and troubleshoot the Keycloak Operator (v2alpha1 CRD)."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, kubernetes]
metadata:
  hermes:
    tags: [keycloak, sso, iam, ldap-federation, authentication, kubernetes]
---

# Keycloak Administration on Kubernetes

Recover admin access when the initial admin password is stale, and configure LDAP user federation — all without the admin console.

## Keycloak Operator (v2alpha1) on K3s

The Keycloak Operator creates:

- A `Keycloak` custom resource (`/apis/k8s.keycloak.org/v2alpha1`)
- A StatefulSet (`devops-kc-0`) running Keycloak server
- A Postgres database (standalone pod or external)
- An initial admin secret (`devops-kc-initial-admin`)

### Key points
- The operator **generates** `devops-kc-initial-admin` on install but **never updates it** after creation
- If the admin password was changed in the UI after first login, the secret and database are out of sync
- The operator does **not** reconcile stale passwords — it's a one-shot bootstrap secret

## Recovering Admin Access (When the Initial Admin Password is Stale)

### 1. Identify the user in the database

```bash
# Get DB credentials
DB_USER=$(kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl get secret -n keycloak keycloak-db-secret -o jsonpath='{.data.password}' | base64 -d)

# List users
kubectl exec -n keycloak postgresql-db-0 -- psql -U "$DB_USER" -d keycloak -c "
  SELECT id, username, email FROM user_entity ORDER BY username;
"

# Find the admin user's ID
kubectl exec -n keycloak postgresql-db-0 -- psql -U "$DB_USER" -d keycloak -c "
  SELECT id FROM user_entity WHERE username = 'admin';
"
```

### 2. Generate a proper password hash

Keycloak uses **argon2** or **pbkdf2-sha256** hashing. Generate a hash with Python:

```python
import hashlib, base64, os, json

salt = os.urandom(16)
iterations = 27500  # Keycloak default for pbkdf2-sha256
dk = hashlib.pbkdf2_hmac('sha256', b'<new-password>', salt, iterations)
value_b64 = base64.b64encode(dk).decode()
salt_b64 = base64.b64encode(salt).decode()

credential_data = {"hashIterations": iterations, "algorithm": "pbkdf2-sha256", "additionalParameters": {}}
secret_data = {"value": value_b64, "salt": salt_b64, "additionalParameters": {}}

print("credential_data:", json.dumps(credential_data))
print("secret_data:", json.dumps(secret_data))
```

### 3. Update the credential in the database

```sql
UPDATE credential SET
  credential_data = '<credential_data_from_python>',
  secret_data = '<secret_data_from_python>'
WHERE user_id = '<admin-user-id>' AND type = 'password';
```

### 4. Recreate the admin secret (so the pod can start)

The pod references `devops-kc-initial-admin` for env vars `KC_BOOTSTRAP_ADMIN_USERNAME`/`KC_BOOTSTRAP_ADMIN_PASSWORD`. If you deleted it or it's stale:

```bash
kubectl create secret generic -n keycloak devops-kc-initial-admin \
  --from-literal=username=admin \
  --from-literal=password=<new-password>
```

### 5. Restart Keycloak

```bash
kubectl rollout restart -n keycloak statefulset/devops-kc
kubectl wait --for=condition=ready -n keycloak pod/devops-kc-0 --timeout=60s
```

### 6. Verify

```bash
curl -sk --connect-timeout 10 \
  -d 'client_id=admin-cli' \
  -d 'username=admin' \
  -d 'password=<new-password>' \
  -d 'grant_type=password' \
  'https://<keycloak-service>:8443/realms/master/protocol/openid-connect/token'
```

## Keycloak Database Structure

| Table | Purpose |
|-------|---------|
| `realm` | Realms (master, devops, etc.) |
| `user_entity` | All users |
| `credential` | Password hashes (argon2/pbkdf2-sha256) |
| `user_role_mapping` | Role assignments |
| `client` | OIDC clients |
| `user_federation_provider` | LDAP/AD federation providers |
| `user_federation_config` | Per-provider configuration (key-value) |
| `scope_mapping` | Client scope mappings (roles to include in tokens) |

### Getting realm IDs

```sql
SELECT id, name FROM realm;
```

### Getting client IDs

```sql
SELECT c.id, c.client_id FROM client c JOIN realm r ON c.realm_id = r.id WHERE r.name = 'master';
```

## Configuring LDAP User Federation

### 1. Get the realm ID

```bash
REALM_ID=$(kubectl exec -n keycloak postgresql-db-0 -- psql -U admin -d keycloak -t -c "
  SELECT id FROM realm WHERE name = '<realm-name>';
" | tr -d '[:space:]')
```

### 2. Create the federation provider

```sql
INSERT INTO user_federation_provider (id, changed_sync_period, display_name, full_sync_period, last_sync, priority, provider_name, realm_id)
VALUES ('<uuid>', -1, '<display-name>', -1, -1, 0, 'ldap', '<realm-id>');
```

### 3. Add configuration entries

```sql
INSERT INTO user_federation_config (user_federation_provider_id, name, value)
VALUES
  ('<provider-uuid>', 'enabled', 'true'),
  ('<provider-uuid>', 'vendor', 'other'),
  ('<provider-uuid>', 'usernameLDAPAttribute', 'uid'),
  ('<provider-uuid>', 'rdnLDAPAttribute', 'uid'),
  ('<provider-uuid>', 'uuidLDAPAttribute', 'entryUUID'),
  ('<provider-uuid>', 'userObjectClasses', 'inetOrgPerson,organizationalPerson'),
  ('<provider-uuid>', 'connectionUrl', 'ldap://<ldap-host>:389'),
  ('<provider-uuid>', 'bindDn', 'cn=admin,dc=<domain>,dc=<tld>'),
  ('<provider-uuid>', 'bindCredential', '<bind-password>'),
  ('<provider-uuid>', 'searchScope', '1'),
  ('<provider-uuid>', 'usersDn', 'ou=people,dc=<domain>,dc=<tld>'),
  ('<provider-uuid>', 'batchSizeForSync', '1000'),
  ('<provider-uuid>', 'importEnabled', 'true'),
  ('<provider-uuid>', 'syncRegistrations', 'false'),
  ('<provider-uuid>', 'editMode', 'WRITABLE'),
  ('<provider-uuid>', 'authType', 'simple');
```

### 4. Update existing users' federation links

If users already exist in Keycloak and should be linked to the LDAP provider:

```sql
UPDATE user_entity SET federation_link = '<provider-uuid>'
WHERE federation_link IS NOT NULL
AND realm_id = '<realm-id>';
```

### 5. Restart Keycloak

```bash
kubectl rollout restart -n keycloak statefulset/devops-kc
```

## Exposing Keycloak for Pod Access

When Keycloak runs inside Kubernetes and needs to reach resources on the host (like OpenLDAP), the simplest path is to use the **node's IP** directly:

```bash
# Create a k8s service with manual endpoint
kubectl create service clusterip openldap --tcp=389:389
# Remove the auto-generated selector so manual endpoint works
kubectl patch svc openldap -p '{"spec":{"selector":null}}'
```

Or just use `192.168.x.x:389` (node IP) directly in the LDAP connection URL — it works from all pods.

## Exposing Keycloak Externally (Without an Ingress Controller)

When the cluster has no Ingress controller (e.g., Cilium is the CNI but Ingress support isn't enabled), use **NodePort** on the Keycloak service:

```bash
kubectl patch svc devops-kc-service -n keycloak -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      {"name": "https", "port": 8443, "targetPort": 8443, "nodePort": 30443},
      {"name": "metrics", "port": 9000, "targetPort": 9000, "nodePort": 30900}
    ]
  }
}'
```

After patching, access Keycloak at `https://<NODE_IP>:30443`.

**Important considerations when using NodePort with Cilium:**
- Cilium's kube-proxy replacement handles NodePort traffic at the datapath level, which can conflict with service DNS on certain configurations
- If `curl -sk https://<NODE_IP>:30443` works from the node but `curl -sk https://<CLUSTER_IP>:8443` from another pod fails with connection timeouts, the issue is likely Cilium's service routing (not the Keycloak pod)
- Workaround: Always use the **node IP** directly for external access and for pod-to-Keycloak communication when Cilium service routing behaves inconsistently

### Adding DNS convenience

On the node itself, add a `/etc/hosts` entry so local commands can use a hostname:

```bash
echo "<NODE_IP> keycloak.paulhome.local" >> /etc/hosts
```

On client machines, add the same entry to their `/etc/hosts` (or C:\Windows\System32\drivers\etc\hosts on Windows) to avoid browser certificate warnings about unknown hostnames.

### After a server reboot

If k3s is disabled at boot, Keycloak won't come up automatically:

```bash
sudo systemctl start k3s          # Start k3s cluster
kubectl wait --for=condition=ready pod -n keycloak -l app=keycloak --timeout=120s   # Wait for Keycloak pod
```

## Assigning Admin Roles

If a user authenticates but gets 401 from the admin API, check the role mapping:

```bash
# List user's current roles
kubectl exec -n keycloak postgresql-db-0 -- psql -U admin -d keycloak -c "
  SELECT k.name FROM keycloak_role k
  JOIN user_role_mapping m ON k.id = m.role_id
  WHERE m.user_id = '<user-id>';
"

# Add the admin role
kubectl exec -n keycloak postgresql-db-0 -- psql -U admin -d keycloak -c "
  INSERT INTO user_role_mapping (role_id, user_id)
  SELECT id, '<user-id>' FROM keycloak_role
  WHERE name = 'admin' AND realm_id = (SELECT id FROM realm WHERE name = 'master');
"
```

## Pitfalls

- **LDAP User Federation tab may not appear in the admin console** — When the Keycloak Operator manages the realm, the admin console may not show the "LDAP" / "Add provider" options under User Federation. The operator's CRD reconciliation can suppress or override UI state. **Workaround:** Configure LDAP federation directly in the database by inserting into `user_federation_provider` and `user_federation_config`, then restart the Keycloak pod. See "Configuring LDAP User Federation" section above for the SQL.

- **The initial admin secret is NOT updated when you change the password in the UI.** The operator created it once and never reconciles it. If you delete it, the operator logs will show "already exists" errors but won't regenerate it.
- **kcadm.sh inside the Keycloak pod** needs the proper truststore. The cert SAN is `keycloak.rancher.local` but that hostname may not be resolvable from inside the pod. Use `/etc/hosts` manipulation or import the cert into a Java truststore via `keytool -import`.
- **Keycloak containers are extremely minimal** — no `curl`, `wget`, `which`, `tar`, or package managers. You can't install tools. Use a sidecar debug pod (`curlimages/curl`, `ubuntu`) for network testing.
- **Token from admin-cli may lack realm_access** — the `admin-cli` client is a public client and may not include `realm_access` claims in the token by default. Add the admin role to `scope_mapping` in the database if needed.
- **Database password format** — Keycloak v26 uses argon2 or pbkdf2-sha256. The value and salt in `secret_data` must be **base64-encoded**.
- **Restart Keycloak after DB changes** — credential changes, user role mapping changes, and federation provider changes all require a pod restart to take effect.

# MySQL OIDC Authentication with Keycloak

## Table of Contents

- [Overview](#overview)
- [Architecture Flow](#architecture-flow)
- [Prerequisites](#prerequisites)
- [Step 1: Enable OIDC Plugin in MySQL](#step-1-enable-oidc-plugin-in-mysql)
- [Step 2: Configure MySQL OIDC Parameters](#step-2-configure-mysql-oidc-parameters)
- [Step 3: Register MySQL as OIDC Client in Keycloak](#step-3-register-mysql-as-oidc-client-in-keycloak)
- [Step 4: Create MySQL Users Mapped to OIDC](#step-4-create-mysql-users-mapped-to-oidc)
- [Step 5: Application Integration](#step-5-application-integration)
- [Step 6: JWT Claims MySQL Looks For](#step-6-jwt-claims-mysql-looks-for)
- [Step 7: Group-Based Access Control](#step-7-group-based-access-control)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [References](#references)

---

## Overview

MySQL 8.0+ supports OIDC authentication via the `auth_oidc` plugin. Your app authenticates to Keycloak first, gets a JWT token, then presents that token to MySQL. MySQL validates the token against Keycloak's public keys. **No database passwords stored anywhere.**

> See [diagram.html](diagram.html) for the interactive sequence diagram.

## Architecture Flow

```
1. App authenticates with Keycloak (client_credentials or authorization_code)
2. Keycloak returns a JWT (JSON Web Token) with user/group claims
3. App connects to MySQL, presents the JWT token
4. MySQL calls Keycloak's JWKS endpoint to validate the token
5. MySQL maps token claims (sub, group) to a MySQL user
6. Connection granted with appropriate privileges

App --(1)--> Keycloak --(2)--> JWT token
App --(3,4)--> MySQL --(5)--> Keycloak JWKS (validate token)
MySQL --(6)--> Connection established
```

## Prerequisites

- MySQL 8.0+ (with auth_oidc plugin compiled in)
- Keycloak running (e.g., on K3s via Keycloak Operator)
- App that can obtain OIDC tokens (most modern frameworks support this)

## Step 1: Enable OIDC Plugin in MySQL

```sql
-- Check if plugin is available
SHOW PLUGINS;

-- If not listed, enable it:
INSTALL AUTHENTICATIONOIDC PLUGIN;

-- Verify
SELECT PLUGIN_NAME, PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS
WHERE PLUGIN_NAME = 'authentication_oidc';
```

## Step 2: Configure MySQL OIDC Parameters

```sql
-- In my.cnf or via SET GLOBAL:
SET GLOBAL authentication_oidc_provider = 'keycloak';

-- Keycloak OIDC discovery URL
SET GLOBAL authentication_oidc_provider_metadata_url =
  'https://keycloak.paulhome.local:30443/realms/devops/.well-known/openid-configuration';

-- Client ID registered in Keycloak (see Step 3)
SET GLOBAL authentication_oidc_client_id = 'mysql-app';

-- Client secret from Keycloak
SET GLOBAL authentication_oidc_client_secret = '<client-secret-from-keycloak>';

-- JWT claim to map to MySQL user (default: 'sub')
-- Options: 'sub', 'preferred_username', or a custom claim
SET GLOBAL authentication_oidc_user_claim = 'preferred_username';

-- Auto-create MySQL users from OIDC tokens (optional)
SET GLOBAL authentication_oidc_autocreate_user = 'ON';
```

## Step 3: Register MySQL as OIDC Client in Keycloak

In Keycloak Admin Console:

1. Go to your Realm (e.g., `devops`)
2. **Clients** -> **Create Client**
3. Settings:

| Setting | Value |
|---------|-------|
| Client ID | `mysql-app` |
| Client Protocol | OpenID Connect |
| Access Type | `confidential` |
| Direct Access Grants | ON (for testing) |

4. After creation, go to **Credentials** tab:
   Copy the "Secret" value — this is your `client_secret`

5. Go to **Settings** tab, set **Valid Redirect URIs**:
   (MySQL doesn't redirect, but Keycloak requires at least one)
   `https://localhost`

6. Enable **Authorization** (optional, for fine-grained access)

## Step 4: Create MySQL Users Mapped to OIDC

### Option A: Auto-create (if autocreate_user = ON)

```sql
-- MySQL automatically creates users on first OIDC login
-- Just grant privileges after first login:
GRANT SELECT, INSERT, UPDATE ON mydb.* TO 'app-user'@'%';
FLUSH PRIVILEGES;
```

### Option B: Pre-create users manually

```sql
-- Create user with OIDC auth method
CREATE USER 'app-user'@'%' IDENTIFIED WITH authentication_oidc
  AS '{
    "provider": "keycloak",
    "user_claim": "preferred_username",
    "required_claims": {
      "azp": "mysql-app"
    }
  }';

-- Grant privileges
GRANT SELECT, INSERT, UPDATE ON mydb.* TO 'app-user'@'%';
FLUSH PRIVILEGES;
```

## Step 5: Application Integration

Your app needs to:
1. Obtain a JWT from Keycloak before connecting to MySQL
2. Pass the JWT when connecting

### Python Example

```python
import mysql.connector
import requests

def get_keycloak_token():
    """Get JWT from Keycloak using client_credentials flow"""
    resp = requests.post(
        'https://keycloak.paulhome.local:30443/realms/devops/protocol/openid-connect/token',
        data={
            'grant_type': 'client_credentials',
            'client_id': 'my-app',
            'client_secret': '<app-client-secret>',
        },
        verify=False  # Use proper CA in production
    )
    return resp.json()['access_token']

# Connect to MySQL with OIDC token
token = get_keycloak_token()

conn = mysql.connector.connect(
    host='mysql-host',
    port=3306,
    user='app-user',        # Must match OIDC user or use token
    password=token,          # JWT token IS the password
    database='mydb',
    ssl_disabled=False,
    ssl_ca='/path/to/ca.pem'
)

cursor = conn.cursor()
cursor.execute("SELECT NOW()")
print(cursor.fetchone())
```

### Go Example

```go
import (
    "database/sql"
    _ "github.com/go-sql-driver/mysql"
)

token := getOidcToken() // Your Keycloak token logic

dsn := "app-user:" + token + "@tcp(mysql-host:3306)/mydb?tls=true&tls-ca=/path/to/ca.pem"
db, err := sql.Open("mysql", dsn)
```

## Step 6: JWT Claims MySQL Looks For

| Claim | Purpose |
|-------|---------|
| `sub` | Subject (user identifier) |
| `preferred_username` | Mapped to MySQL user (if user_claim = preferred_username) |
| `azp` | Authorized party (client ID that requested the token) |
| `iss` | Issuer (must match Keycloak realm URL) |
| `exp` | Expiration (token validity) |
| `iat` | Issued at time |

### Custom Claims for Fine-Grained Access

Example: Add a `mysql_role` custom claim in Keycloak:

1. In Keycloak, go to **Client** -> **Mappers** -> **Create**
2. Configure:

| Setting | Value |
|---------|-------|
| Name | `mysql_role` |
| Type | User Attribute |
| User Attribute | `mysql_role` |
| Token Claim Name | `mysql_role` |
| Add to ID token | ON |
| Add to access token | ON |

Then in MySQL:
```sql
CREATE USER 'dba-user'@'%' IDENTIFIED WITH authentication_oidc AS '{
  "provider": "keycloak",
  "required_claims": {
    "mysql_role": "dba"
  }
}';
```

## Step 7: Group-Based Access Control

Map Keycloak groups to MySQL privilege levels:

| Keycloak Group | MySQL User | Privileges |
|----------------|------------|------------|
| `dev-team` | `dev-user` | SELECT, INSERT, UPDATE |
| `dba-team` | `dba-user` | ALL PRIVILEGES |
| `readonly` | `readonly-user` | SELECT only |
| `app-service` | `app-user` | SELECT, INSERT, UPDATE, DELETE |

In Keycloak, configure group membership:
- **Users** -> [user] -> **Groups** tab -> join group

In MySQL, create users with required_claims:
```sql
CREATE USER 'dev-user'@'%' IDENTIFIED WITH authentication_oidc AS '{
  "provider": "keycloak",
  "required_claims": {
    "group": "dev-team"
  }
}';
```

## Security Considerations

1. **Token expiration**: JWT tokens have a default TTL (usually 30 min). App must refresh tokens before expiry. MySQL re-validates on each new connection.

2. **TLS everywhere**:
   - MySQL -> Keycloak JWKS endpoint must be over HTTPS
   - App -> MySQL should use TLS
   - cert-manager can handle certs for both

3. **Client secrets**: Still need to store Keycloak client secret in the app. Use K8s Secrets or Vault for this. Still better than storing DB passwords.

4. **Token replay**: Tokens are short-lived (30 min default). Use refresh tokens for long-running apps.

## Troubleshooting

```bash
# Test OIDC discovery URL works from MySQL host:
curl -sk https://keycloak.paulhome.local:30443/realms/devops/.well-known/openid-configuration

# Verify JWKS endpoint:
curl -sk https://keycloak.paulhome.local:30443/realms/devops/protocol/openid-connect/certs

# Test token acquisition from app side:
curl -sk -d 'grant_type=client_credentials' \
  -d 'client_id=mysql-app' \
  -d 'client_secret=<secret>' \
  'https://keycloak.paulhome.local:30443/realms/devops/protocol/openid-connect/token'

# Decode JWT to inspect claims:
echo '<token>' | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "Failed to fetch OIDC metadata" | Wrong metadata_url or TLS issue | Check URL and CA cert |
| "Invalid token" | Token expired, wrong issuer, or wrong client_id | Verify `iss` claim matches Keycloak realm URL |
| "User not found" | autocreate_user=OFF and user not pre-created | Enable autocreate or create user manually |

## Limitations

- MySQL auth_oidc plugin is relatively new (8.0.27+)
- Not all MySQL distributions compile it in by default
- MariaDB does NOT support OIDC auth
- Each new connection requires a token — connection pooling is tricky (tokens expire, pooled connections may become invalid)

## References

- [MySQL 8.0 OIDC Authentication Plugin](https://dev.mysql.com/doc/refman/8.0/en/pluggable-authentication-components.html)
- [Keycloak OpenID Connect](https://www.keycloak.org/docs/latest/server_admin/#_oidc)
- [MySQL InnoDB Cluster](https://dev.mysql.com/doc/refman/8.0/en/mysql-innodb-cluster.html)

---

*Created: 2026-09-29 | Diagram: [diagram.html](diagram.html)*

# Password Hash Generation for Keycloak Credential Reset

Two approaches that work with Keycloak 26.x:

## Method 1: pbkdf2-sha256 (simpler, faster)

```python
import hashlib, base64, os, json

salt = os.urandom(16)
iterations = 27500  # Keycloak default
password = b"admin123"

dk = hashlib.pbkdf2_hmac('sha256', password, salt, iterations)
value_b64 = base64.b64encode(dk).decode()
salt_b64 = base64.b64encode(salt).decode()

credential_data = json.dumps({
    "hashIterations": iterations,
    "algorithm": "pbkdf2-sha256",
    "additionalParameters": {}
})

secret_data = json.dumps({
    "value": value_b64,
    "salt": salt_b64,
    "additionalParameters": {}
})

print(f"credential_data: {credential_data}")
print(f"secret_data: {secret_data}")
```

## Method 2: argon2 (matches Keycloak's default)

```bash
pip install argon2-cffi
```

```python
from argon2 import PasswordHasher, Type
import json, base64

ph = PasswordHasher(
    time_cost=5,
    memory_cost=7168,
    parallelism=1,
    hash_len=32,
    type=Type.ID,
)
password_hash = ph.hash("admin123")
# Parse: $argon2id$v=19$m=7168,t=5,p=1$<salt>$<hash>
parts = password_hash.split('$')

value_b64 = base64.b64encode(parts[5].encode()).decode()
salt_b64 = base64.b64encode(parts[4].encode()).decode()

credential_data = json.dumps({
    "hashIterations": 5,
    "algorithm": "argon2",
    "additionalParameters": {
        "hashLength": ["32"],
        "memory": ["7168"],
        "type": ["id"],
        "version": ["1.3"],
        "parallelism": ["1"]
    }
})

secret_data = json.dumps({
    "value": value_b64,
    "salt": salt_b64,
    "additionalParameters": {}
})
```

## SQL to apply

```sql
UPDATE credential SET
  credential_data = '<credential_data>',
  secret_data = '<secret_data>'
WHERE user_id = '<user-uuid>' AND type = 'password';
```

## Verify the credential was stored

```sql
SELECT id, type, user_id, substring(secret_data, 1, 60) as secret_preview
FROM credential
WHERE user_id = '<user-uuid>';
```

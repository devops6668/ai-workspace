# Admin Password Change (Recovery Procedure)

When the admin password for `cn=admin,dc=paulhome,dc=local` is lost or needs changing.

## The Problem

`cn=admin,dc=paulhome,dc=local` is a **root DN** (defined in slapd config via `olcRootPW`), not a directory entry. This means:
- `ldappasswd -x -D cn=admin,... -W -S` fails with **"No such object (32)"**
- There is no entry to `ldapmodify` under the `dc=...` tree
- The password hash lives in slapd's `cn=config` database

## The Fix

Use the local Unix socket (no auth required for root):

```bash
# 1. Generate new hash
slappasswd -s <new-password>

# 2. Create LDIF
cat > /tmp/admin_pwd.ldif << 'EOF'
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: {SSHA}<hash-from-slappasswd>
EOF

# 3. Apply
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/admin_pwd.ldif

# 4. Verify
ldapwhoami -x -D cn=admin,dc=paulhome,dc=local -w <new-password>
# Expected: dn:cn=admin,dc=paulhome,dc=local
```

## Which Database?

- `{0}config` = slapd runtime configuration (`cn=config`)
- `{1}mdb` = your directory data (`dc=paulhome,dc=local`) ← **this is where `olcRootPW` lives**

To see all databases:
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config | grep -E "^dn:|olcSuffix"
```

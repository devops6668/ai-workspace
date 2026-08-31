---
name: openldap
description: "Install, configure, and manage OpenLDAP (slapd) on Ubuntu/Debian — domain setup, user/group management, and web GUI (phpLDAPadmin)."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [ldap, openldap, slapd, authentication, directory-services, phpldapadmin]
---

# OpenLDAP Server Management

Install and configure OpenLDAP (`slapd`) on Ubuntu/Debian, manage entries, and set up a web-based administration UI.

## Installation

### Install slapd and client utils
```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils
```

### Reconfigure with your domain (if default `dc=nodomain` was set)

Preseed debconf values, then reconfigure:
```bash
# Stop and clear defaults
systemctl stop slapd
rm -rf /etc/ldap/slapd.d/*
rm -rf /var/lib/ldap/*

# Preseed the domain/org
echo "slapd slapd/password1 password <admin-password>" | debconf-set-selections
echo "slapd slapd/password2 password <admin-password>" | debconf-set-selections
echo "slapd slapd/domain string <your.domain>" | debconf-set-selections
echo "slapd slapd/backend select MDB" | debconf-set-selections
echo "slapd shared/organization string <org-name>" | debconf-set-selections
echo "slapd slapd/purge_database boolean true" | debconf-set-selections
echo "slapd slapd/move_old_database boolean true" | debconf-set-selections
echo "slapd slapd/allow_ldap_v2 boolean false" | debconf-set-selections
echo "slapd slapd/no_configuration boolean false" | debconf-set-selections

DEBIAN_FRONTEND=noninteractive dpkg-reconfigure slapd
systemctl start slapd
```

### Verify
```bash
systemctl is-active slapd
slapcat  # should show your domain's base DN
```

## Adding Directory Structure

Create a base LDIF file (e.g., `/tmp/base.ldif`):

```ldif
dn: ou=people,dc=<domain>,dc=<tld>
objectClass: organizationalUnit
ou: people

dn: ou=groups,dc=<domain>,dc=<tld>
objectClass: organizationalUnit
ou: groups

dn: ou=services,dc=<domain>,dc=<tld>
objectClass: organizationalUnit
ou: services
```

Apply it:
```bash
ldapadd -x -D cn=admin,dc=<domain>,dc=<tld> -w <password> -f /tmp/base.ldif
```

## Managing Users

### Generate password hash
```bash
slappasswd -s <user-password>
```

### Add a user
Create an LDIF:
```ldif
dn: uid=<username>,ou=people,dc=<domain>,dc=<tld>
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: <Display Name>
sn: <Last Name>
uid: <username>
uidNumber: <e.g. 20000>
gidNumber: <primary-group-gid>
homeDirectory: /home/<username>
loginShell: /bin/bash
mail: <email>
givenName: <First Name>
userPassword: <SSHA-hash-from-slappasswd>
```

Apply:
```bash
ldapadd -x -D cn=admin,dc=<domain>,dc=<tld> -w <password> -f <user.ldif>
```

Test login:
```bash
ldapwhoami -x -D uid=<username>,ou=people,dc=<domain>,dc=<tld> -w <user-password>
```

## Managing Groups

### Add a POSIX group
```ldif
dn: cn=<groupname>,ou=groups,dc=<domain>,dc=<tld>
objectClass: top
objectClass: posixGroup
cn: <groupname>
gidNumber: <e.g. 10001>
memberUid: <username1>
memberUid: <username2>
```

Apply with `ldapadd`.

## Searching

```bash
# Search all entries
ldapsearch -x -b dc=<domain>,dc=<tld> -D cn=admin,dc=<domain>,dc=<tld> -w <password>

# Search with filter
ldapsearch -x -b dc=<domain>,dc=<tld> -D cn=admin,dc=<domain>,dc=<tld> -w <password> "(&(objectClass=posixGroup)(memberUid=<username>))"
```

## Web GUI: phpLDAPadmin

### Install
```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y phpldapadmin
```

### Configure
Edit `/etc/phpldapadmin/config.php`. Key settings to change:

```php
$servers->setValue('server','name','<your-label> LDAP');
$servers->setValue('server','host','127.0.0.1');
$servers->setValue('server','port',389);
$servers->setValue('server','base',array('dc=<domain>,dc=<tld>'));
$servers->setValue('login','anon_bind',false);
$servers->setValue('login','allowed_dns',array('cn=admin,dc=<domain>,dc=<tld>'));
$servers->setValue('login','base',array('dc=<domain>,dc=<tld>'));
```

### Restart Apache
```bash
systemctl restart apache2
```

### Access
Open `http://<server-ip>/phpldapadmin` in a browser.
Login DN: `cn=admin,dc=<domain>,dc=<tld>`

### PHP 8.x Compatibility Fix

phpLDAPadmin calls `ldap_connect($host, $port)` with two arguments, which is **deprecated in PHP 8.0+** and emits:
```
Unrecognized error number: 8192: Usage of ldap_connect with two arguments is deprecated
```

**Fix:** Edit `/usr/share/phpldapadmin/lib/ds_ldap.php` and change both `ldap_connect()` calls to use a single URI:

```bash
# With port — line ~208
sed -i 's|ldap_connect($this->getValue(.server.,.host.),$this->getValue(.server.,.port.))|ldap_connect(sprintf(.ldap://%s:%s.,$this->getValue(.server.,.host.),$this->getValue(.server.,.port.)))|' /usr/share/phpldapadmin/lib/ds_ldap.php

# Without port — line ~210
sed -i 's|ldap_connect($this->getValue(.server.,.host.))|ldap_connect(sprintf(.ldap://%s.,$this->getValue(.server.,.host.)))|' /usr/share/phpldapadmin/lib/ds_ldap.php
```

Or edit manually: `ldap_connect($host, $port)` → `ldap_connect("ldap://{$host}:{$port}")` and `ldap_connect($host)` → `ldap_connect("ldap://{$host}")`.

No Apache restart needed.

### Fix the default Login DN in the login form

By default, the phpLDAPadmin login form pre-fills `cn=admin,dc=example,dc=com`. Update it to match your domain:

```bash
sed -i 's|value="cn=admin,dc=example,dc=com"|value="cn=admin,dc=<your.domain>"|g' \
  /usr/share/phpldapadmin/htdocs/login_form.php
```

### Login form field names (for curl/API testing)

When POSTing to `/phpldapadmin/cmd.php` with `cmd=login`:
- `login` — the Login DN (e.g. `cn=admin,dc=paulhome,dc=local`)
- `login_pass` — the password
- `server_id=1`
- `nodecode[login_pass]=1`

Test login via curl:
```bash
curl -sL -c /tmp/cookies.txt -b /tmp/cookies.txt \
  -d "cmd=login" \
  -d "server_id=1" \
  -d "nodecode[login_pass]=1" \
  -d "login=cn=admin,dc=<domain>,dc=<tld>" \
  -d "login_pass=<password>" \
  -d "submit=Authenticate" \
  "http://localhost/phpldapadmin/cmd.php" | grep "Successfully logged into server"
```

## Ports
- LDAP: 389 (plain)
- LDAPS: 636 (TLS, requires certificate setup)

## Admin Password Management

The `cn=admin,dc=<domain>,dc=<tld>` account is a **root DN** defined in slapd's config, not a regular directory entry. This means:
- `ldappasswd` will **not** work (returns "No such object (32)")
- The password hash is stored in `olcRootPW` in the slapd config database

### Change the admin password

1. Generate a new password hash:
```bash
slappasswd -s <new-password>
```
Example output: `{SSHA}5qJJNEilXdUV9jwTzX+G/Lw8Kp++J7J7`

2. Create an LDIF file:
```ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: {SSHA}5qJJNEilXdUV9jwTzX+G/Lw8Kp++J7J7
```

3. Apply via the local socket (no password needed):
```bash
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/admin_pwd.ldif
```

4. Verify the new password works:
```bash
ldapwhoami -x -D cn=admin,dc=<domain>,dc=<tld> -w <new-password>
```

### Using ldapi:/// for admin tasks

The `ldapi:///` transport (local Unix socket) allows root to perform LDAP admin operations **without authenticating**. This is useful for:
- Changing the admin password
- Modifying slapd configuration (under `cn=config`)
- Recovery when the admin password is lost

```bash
# All admin operations on the local machine
ldapmodify -Y EXTERNAL -H ldapi:/// -f <file.ldif>
ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config
```

The `cn=config` database (backend `{0}config`) is writable via `ldapi:///` and contains all slapd runtime configuration.

The `{1}mdb` database holds your directory data (`dc=...,dc=...`). Its `olcRootPW` attribute defines the root DN password.

## Related Skills

- **keycloak-administration** — Connect OpenLDAP to Keycloak as an LDAP user federation provider for SSO.

## Pitfalls

- **Default domain is `dc=nodomain`** — always reconfigure slapd after install or the base DN will be wrong.
- **Password hashing** — Use `slappasswd -s <password>` to generate SSHA hashes. Plaintext passwords in LDIF will fail `ldapwhoami` authentication even though `ldapadd` accepts them.
- **phpLDAPadmin shows blank page** — check that Apache is running and the config alias is correct: `ls /etc/apache2/conf-enabled/ | grep phpldapadmin`
- **memberUid must match uid exactly** — POSIX groups use `memberUid` (not `member` or `uniqueMember`) for simple user-group mapping.
- **Port 389 conflicts** — if something else is on port 389, change slapd's listen address in `/etc/default/slapd` (`SLAPD_SERVICES="ldap://127.0.0.1:389/"`).
- **Backup before purge** — `dpkg-reconfigure slapd` backs up old config to `/var/backups/slapd-*` automatically.
- **cn=admin is a root DN, not a directory entry** — you cannot `ldapsearch` for it, and `ldappasswd` returns "No such object (32)". Change password via `ldapmodify -Y EXTERNAL -H ldapi:///` to update `olcRootPW`.
- **ldapi:/// is your recovery tool** — if the admin password is lost, use the local Unix socket as root: `ldapmodify -Y EXTERNAL -H ldapi:///` (no password needed).
- **PHP 8.x breaks phpLDAPadmin out of the box** — `ldap_connect($host, $port)` is deprecated. Fix: change to `ldap_connect("ldap://{$host}:{$port}")` in `/usr/share/phpldapadmin/lib/ds_ldap.php`.
- **Watch the URL** — the default Apache alias is `/phpldapadmin` (not `/phpldamadmin`).

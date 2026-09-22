# Vault + Confluent Kafka mTLS — Research Notes

> Research date: 2026-09-21
> Status: Architecture review complete, pending implementation

---

## Table of Contents

- [1. Overview](#1-overview)
- [2. OpenBao vs HashiCorp Vault](#2-openbao-vs-hashicorp-vault)
  - [2.1 Background](#21-background)
  - [2.2 Feature Comparison](#22-feature-comparison)
  - [2.3 Community vs Enterprise](#23-community-vs-enterprise)
  - [2.4 Community Edition Limitations](#24-community-edition-limitations)
- [3. Kafka Integration](#3-kafka-integration)
  - [3.1 Integration Methods](#31-integration-methods)
  - [3.2 SCRAM vs mTLS Comparison](#32-scram-vs-mtls-comparison)
  - [3.3 Recommended Architecture (mTLS)](#33-recommended-architecture-mtls)
  - [3.4 Trust Chain](#34-trust-chain)
  - [3.5 Certificate Renewal](#35-certificate-renewal)
  - [3.6 Broker Certificate Update](#36-broker-certificate-update)
- [4. Security Assessment](#4-security-assessment)
  - [4.1 Current Measures](#41-current-measures)
  - [4.2 Remaining Risks](#42-remaining-risks)
  - [4.3 Hardening Recommendations](#43-hardening-recommendations)
- [5. Active Directory Integration](#5-active-directory-integration)
  - [5.1 Vault LDAP Secrets Engine](#51-vault-ldap-secrets-engine)
  - [5.2 Static vs Dynamic Roles](#52-static-vs-dynamic-roles)
  - [5.3 Community Edition Support](#53-community-edition-support)
- [6. SAML / OIDC Authentication](#6-saml--oidc-authentication)
  - [6.1 SAML](#61-saml)
  - [6.2 OIDC with Keycloak](#62-oidc-with-keycloak)
- [7. Keycloak Integration](#7-keycloak-integration)
- [8. Diagrams](#8-diagrams)
- [9. Open Questions](#9-open-questions)
- [10. Next Steps](#10-next-steps)

---

## 1. Overview

Research into using HashiCorp Vault (Community Edition) to manage secrets and mTLS certificates for a hybrid environment:

- **Kafka Cluster**: Confluent Platform on VMs, LDAP authentication via Windows AD
- **Applications**: Consumer/Producer on K8s (RKE2)
- **Goal**: Eliminate static passwords, automate certificate lifecycle, zero manual intervention

---

## 2. OpenBao vs HashiCorp Vault

### 2.1 Background

| Item | OpenBao | HashiCorp Vault |
|------|---------|-----------------|
| Origin | Fork from Vault 1.14.0 (last MPL version) | Original, relicensed BUSL-1.1 in Aug 2023 |
| License | MPL-2.0 (OSI-approved open source) | BUSL-1.1 (source-available, not OSI) |
| Governance | Linux Foundation + OpenSSF | HashiCorp/IBM single vendor |
| Current version | v2.6.2 (2026-08-18) | v1.20.4 (2025-06) |

### 2.2 Feature Comparison

**Both support:**
- KV v1/v2, Transit, PKI, Database, SSH, all cloud provider engines
- AppRole, K8s, JWT/OIDC, LDAP, GitHub, Userpass auth methods
- Raft/PostgreSQL/Consul storage, HA, Auto-unseal
- UI, CLI, API, Terraform Provider

**OpenBao exclusive (already open-sourced):**
- Namespaces (multi-tenancy) — Enterprise feature
- Performance Standby (read scaling) — Enterprise feature
- Transactional Storage, Paginated Lists
- Per-namespace Sealing, Workflow Engine (v2.6.0)

**Vault Enterprise only:**
- DR Replication, Performance Replication
- Sentinel Policies (Policy-as-Code)
- Transform Engine, KMIP, Entropy Augmentation
- HSM Auto-unseal, Seal Wrapping, FIPS Builds
- SAML Auth, MFA, Control Groups
- Automated Snapshots, Secrets Sync, Lease Count Quotas

### 2.3 Community vs Enterprise

Community Edition covers ~60-70% of Enterprise features.

### 2.4 Community Edition Limitations

- No Namespaces, no DR/Performance Replication
- No Sentinel, no HSM, no FIPS
- No official SLA or commercial support
- BSL 1.1 license (not OSI open source)
- Upgrade to Enterprise is smooth (same binary, same storage format)

---

## 3. Kafka Integration

### 3.1 Integration Methods

| Method | Auto-renew | Complexity | Community CE |
|--------|:----------:|:----------:|:------------:|
| KV Secrets Engine (static) | ❌ (CronJob) | Low | ✅ |
| Database Secrets Engine (SCRAM) | ❌ (plugin needed) | High | ✅ |
| PKI Secrets Engine (mTLS) | ✅ (Vault Agent) | Medium | ✅ |
| Third-party Kafka plugin | ✅ | High | ✅ |

### 3.2 SCRAM vs mTLS Comparison

| Aspect | SCRAM Password | mTLS Certificate |
|--------|:--------------:|:----------------:|
| Auto-fetch credentials | ✅ Vault Agent | ✅ Vault Agent |
| Auto rotation | ❌ CronJob needed | ✅ Vault Agent auto-renew |
| Fully automated | ❌ | ✅ |
| Extra dependencies | kafka-configs CLI | None |
| Kafka-side changes | Manage SCRAM users | Just trust CA |
| Security | Password exposure window | Short-lived cert, minimal window |
| Community Edition | ✅ | ✅ |

### 3.3 Recommended Architecture (mTLS)

**Fully automated, zero manual password management:**

```
Vault PKI (Internal CA)
  ├── Root CA (10yr TTL)
  └── Intermediate CA (5yr TTL)
        ├── Role: kafka-broker (TTL=720h)
        └── Role: kafka-client (TTL=1h)

Vault Agent Sidecar (K8s)
  ├── Auto-fetches client certificate
  ├── Writes to /etc/kafka/certs/
  └── Auto-renews at 60% TTL

Kafka Broker (VM)
  ├── ssl.client.auth=required
  └── broker.truststore.jks contains Vault CA cert
```

### 3.4 Trust Chain

```
Vault CA (signs all certificates)
  ├── Broker cert (CN=broker1.kafka.internal)
  ├── Producer cert (CN=app-producer.kafka.internal)
  └── Consumer cert (CN=app-consumer.kafka.internal)

Broker verifies: "Is this cert signed by Vault CA?" → YES → trusted
```

### 3.5 Certificate Renewal

Vault Agent uses `pkiCert` template function:
- Default: renews at 85% of TTL
- For TTL=1h: auto-renews at ~51 minutes
- New cert written to Pod volume, app reloads transparently
- Zero downtime, zero manual intervention

### 3.6 Broker Certificate Update

Broker cert (TTL=720h) can be updated via:
1. **Dynamic reload** — `kafka-configs` updates SSL config without restart
2. **Rolling restart** — One broker at a time, no service interruption
3. **Vault Agent on VM** — Auto-renew + auto-reload script

---

## 4. Security Assessment

### 4.1 Current Measures

- mTLS bidirectional authentication
- Short-lived certificates (TTL=1h)
- Vault CA as single trust anchor
- Vault Agent auto-renewal (no human intervention)
- Auto-unseal via Cloud KMS
- Audit logging

### 4.2 Remaining Risks

1. Private key in Pod memory (mitigated by emptyDir Memory-backed)
2. Vault Agent token exposure (mitigated by short TTL + minimal policy)
3. No certificate revocation mechanism (mitigated by short TTL)
4. Broker truststore too permissive (any Vault CA-signed cert trusted)
5. No network segmentation between Pods

### 4.3 Hardening Recommendations

| Priority | Measure | Difficulty | Impact |
|:--------:|---------|:----------:|:------:|
| 1 | Shorter TTL (10-30 min) | Low | High |
| 2 | Kafka ACL with certificate CN | Medium | High |
| 3 | Vault Policy minimal permissions | Low | High |
| 4 | emptyDir Memory-backed | Low | Medium |
| 5 | Root CA key offline | High | High |
| 6 | CRL setup | Medium | Medium |
| 7 | NetworkPolicy | Medium | Medium |
| 8 | Pod Security Context | Low | Medium |

---

## 5. Active Directory Integration

### 5.1 Vault LDAP Secrets Engine

Vault connects to Windows Active Directory via LDAP Secrets Engine with `schema=ad`.

### 5.2 Static vs Dynamic Roles

| Mode | Description | Kafka Change |
|------|-------------|:------------:|
| Static Role | Vault manages existing AD account, auto-rotates password | No change |
| Dynamic Role | Vault creates/deletes AD accounts on demand | Password fetch via Vault |

**Recommended: Static Role** — least disruptive to existing Kafka LDAP setup.

### 5.3 Community Edition Support

| Feature | Community | Enterprise |
|---------|:---------:|:----------:|
| LDAP Secrets Engine (built-in) | ✅ | ✅ |
| Static Roles | ✅ | ✅ |
| Dynamic Roles | ✅ | ✅ |
| Service Account Libraries | ❌ | ✅ |

---

## 6. SAML / OIDC Authentication

### 6.1 SAML

- Enterprise only (Vault) / In development (OpenBao)
- For human SSO login to Vault UI
- Not needed if using OIDC with Keycloak

### 6.2 OIDC with Keycloak

- Community Edition supported
- Recommended for human SSO
- Keycloak groups → Vault policies mapping

---

## 7. Keycloak Integration

OIDC auth method with Keycloak:

```bash
vault auth enable oidc
vault write auth/oidc/config \
  oidc_discovery_url="https://keycloak.example.com/realms/your-realm" \
  oidc_client_id="vault-client" \
  oidc_client_secret="your-secret" \
  default_role="developer"
```

Keycloak groups automatically map to Vault policies.

---

## 8. Diagrams

- `vault-kafka-mtls-architecture.html` — Architecture diagram (SVG/HTML)
- `vault-kafka-mtls-archify.html` — Archify sequence diagram
- `vault-kafka-mtls-archify.png` — Sequence diagram screenshot

---

## 9. Open Questions

- [ ] Which Confluent Kafka version is currently deployed?
- [ ] Is Kafka using SASL_SSL or SSL listener?
- [ ] Current LDAP authenticator configuration details?
- [ ] Do we need to support both SCRAM and mTLS during transition?
- [ ] Which Cloud KMS for Vault auto-unseal (AWS/GCP/Azure)?
- [ ] Vault Enterprise pricing if needed later?

---

## 10. Next Steps

1. Decide: mTLS (recommended) vs SCRAM + Vault Agent
2. Set up Vault PKI engine (Root + Intermediate CA)
3. Configure Kafka broker truststore with Vault CA cert
4. Deploy Vault Agent sidecar in Producer/Consumer Pods
5. Test mTLS connection end-to-end
6. Set up Vault LDAP Secrets Engine for AD integration (if needed)
7. Configure Keycloak OIDC for Vault UI SSO

---

## References

- OpenBao: https://openbao.org
- HashiCorp Vault: https://developer.hashicorp.com/vault
- Vault LDAP Secrets Engine: https://developer.hashicorp.com/vault/docs/secrets/ldap
- Vault PKI + Kafka: https://developer.hashicorp.com/validated-patterns/vault/vault-securing-kafka
- Confluent mTLS: https://docs.confluent.io/platform/current/security/authentication/mutual-tls/overview.html

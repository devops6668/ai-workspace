# Confluent Platform (Kafka) Ansible 安裝指南

> 參考來源: https://docs.confluent.io/ansible/current/ansible-install.html
> Collection: confluent.platform (cp-ansible)
> GitHub: https://github.com/confluentinc/cp-ansible

---

## 前提條件

- Ansible 2.11+
- 目標機器: RHEL/CentOS/Ubuntu (需要 Python3)
- Control node 可以 SSH 到所有 target hosts
- 需要開啟 hash merging (ansible.cfg)

---

## Step 1: 安裝 Confluent Ansible Collection

### 方法 A — Ansible Galaxy（推薦）

```bash
ansible-galaxy collection install confluent.platform
```

### 方法 B — 指定版本

```bash
ansible-galaxy collection install confluent.platform:==8.3.0
```

### 方法 C — 直接從 GitHub

```bash
mkdir -p ~/ansible_collections/confluent/
git clone https://github.com/confluentinc/cp-ansible \
  ~/ansible_collections/confluent/platform
```

---

## Step 2: 設定 ansible.cfg 開啟 hash merging

Confluent Ansible 要求 hash merging，加喺 `ansible.cfg`:

```ini
[defaults]
hash_behaviour = merge
```

---

## Step 3: 建立 Inventory 檔案 (hosts.yml)

### Multi-node 範例

```yaml
---
all:
  vars:
    ansible_connection: ssh
    ansible_user: centos
    ansible_become: true
    ansible_python_interpreter: /usr/bin/python3

  children:
    kafka_controller:
      hosts:
        kafka-c1.example.com:
        kafka-c2.example.com:
        kafka-c3.example.com:

    kafka_broker:
      hosts:
        kafka-b1.example.com:
        kafka-b2.example.com:
        kafka-b3.example.com:

    schema_registry:
      hosts:
        kafka-b1.example.com:

    kafka_connect:
      hosts:
        kafka-b2.example.com:

    kafka_rest:
      hosts:
        kafka-b3.example.com:

    ksql:
      hosts:
        kafka-b1.example.com:

    control_center_next_gen:
      hosts:
        kafka-b2.example.com:
```

> **注意:** Control Center 同 KRaft Controller 不能同一部機（port 9093 衝突）

### Single dev node 範例（測試用）

```yaml
---
all:
  vars:
    ansible_connection: ssh
    ansible_user: developer
    ansible_become: true
    ansible_python_interpreter: /usr/bin/python3

  children:
    kafka_controller:
      hosts:
        dev-host.example.com:

    kafka_broker:
      hosts:
        dev-host.example.com:

    schema_registry:
      hosts:
        dev-host.example.com:

    kafka_connect:
      hosts:
        dev-host.example.com:

    kafka_rest:
      hosts:
        dev-host.example.com:

    ksql:
      hosts:
        dev-host.example.com:

    control_center_next_gen:
      hosts:
        dev-host.example.com:
```

---

## Step 4: 驗證連接

```bash
ansible all -i hosts.yml -m ping
```

---

## Step 5: 驗證 Hosts（可選）

驗證全部:
```bash
ansible-playbook -i hosts.yml confluent.platform.all --check
```

驗證單一組件:
```bash
ansible-playbook -i hosts.yml confluent.platform.all \
  --tags kafka_controller --check
```

---

## Step 6: 安裝

### 一次過裝晒

```bash
ansible-playbook -i hosts.yml confluent.platform.all
```

### 逐步裝（有依賴順序）

```bash
# 1) KRaft Controller
ansible-playbook -i hosts.yml confluent.platform.all --tags kafka_controller

# 2) Kafka Broker
ansible-playbook -i hosts.yml confluent.platform.all --tags kafka_broker

# 3) 其他組件（可任意順序）
ansible-playbook -i hosts.yml confluent.platform.all --tags schema_registry
ansible-playbook -i hosts.yml confluent.platform.all --tags kafka_rest
ansible-playbook -i hosts.yml confluent.platform.all --tags kafka_connect
ansible-playbook -i hosts.yml confluent.platform.all --tags ksql
ansible-playbook -i hosts.yml confluent.platform.all --tags control_center_next_gen
```

> **依賴順序:** CA 證書 → KRaft Controller → Kafka Broker → 其他組件

---

## Step 7: Control Center（需要 bcrypt）

Control node 要裝 bcrypt:

```bash
pip install bcrypt
```

安裝:

```bash
ansible-playbook -i hosts.yml confluent.platform.all --tags control_center_next_gen
```

---

## 安裝方法選項

喺 `hosts.yml` 入面可以設定:

| 方法 | 說明 | 設定 |
|------|------|------|
| 預設 (packages) | 從 packages.confluent.io 裝，要上網 | 不需額外設定 |
| archive | 用 tarball，air-gapped 環境 | `installation_method: archive` |
| rpm | 用自己嘅 yum repo (RHEL/CentOS) | `confluent_common_repository_baseurl` |
| deb | 用自己嘅 apt repo (Ubuntu/Debian) | `confluent_common_repository_baseurl` |

---

## 常用安全設定（喺 hosts.yml all.vars）

```yaml
# TLS 加密
ssl_enabled: true
ssl_mutual_auth_enabled: true      # mTLS

# RBAC
rbac_enabled: true

# Secrets Protection（加密 password）
secrets_protection_enabled: true
```

---

## 非 Root 安裝

用 `--skip-tags` 跳過需要 root 嘅 task:

```bash
ansible-playbook -i hosts.yml confluent.platform.all \
  --skip-tags privileged,sysctl,systemd,filesystem,configuration
```

> **注意:** 官方講呢個 flow 有 known issues，有問題要 contact Confluent support

---

## 各組件 Port 一覽

| 組件 | Port |
|------|------|
| Kafka Controller | 9093 |
| Kafka Broker (inter-broker) | 9091 |
| Kafka Broker (client) | 9092 |
| Schema Registry | 8081 |
| REST Proxy | 8082 |
| Kafka Connect | 8083 |
| ksqlDB | 8088 |
| Control Center | 9021 |
| MDS (RBAC) | 8090 |

---

## Custom Properties

喺 `hosts.yml` 用 `*_custom_properties` dictionary:

```yaml
all:
  vars:
    kafka_broker_custom_properties:
      num.io.threads: 8
      auto.create.topics.enable: false
```

> **重要:** 每個 `*_custom_properties` 只可以定義一次 (all/group/host)，唔可以 merge

---

## Sample Inventories (GitHub)

| 檔案 | 用途 |
|------|------|
| `single_dev_node.yml` | 測試用，全部裝同一部機 |
| `mtls_kraft.yml` | mTLS + KRaft |
| `sasl_ssl_kraft.yml` | SASL/SSL + KRaft |
| `non_root_deployment.yml` | 非 root 安裝 |
| `rbac-over-mtls-centralized-mds.yml` | RBAC + mTLS |

路徑: https://github.com/confluentinc/cp-ansible/tree/8.3.0-post/docs/sample_inventories

---

## 更新已安裝嘅配置

```bash
ansible-playbook -i hosts.yml confluent.platform.all
```

Playbook 每次都會 compare 現有配置同 desired state，有變更先會 restart。

---

## Upgrade

```bash
# 更新 collection
ansible-galaxy collection install confluent.platform --upgrade

# 更新 CP
ansible-playbook -i hosts.yml confluent.platform.all
```

---

## Troubleshooting

- SSH 連唔到？check `chmod 600` SSH private key
- hash merging 錯誤？check `ansible.cfg` 有 `hash_behaviour = merge`
- Control Center port 衝突？唔好同 KRaft Controller 放同一部機
- 非 root 問題？用 `--skip-tags` 跳過 privileged tasks

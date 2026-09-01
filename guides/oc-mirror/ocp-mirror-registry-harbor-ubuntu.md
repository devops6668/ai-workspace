# Harbor + oc-mirror 離線 Mirror Registry 部署指南

> **環境：** OCP 4.20.27 on VMware，Ubuntu VM 做 mirror registry
> **Harbor 版本：** v2.15.2（最新）
> **oc-mirror 版本：** v2（OCP 4.20 專用）

---

## Table of Contents

- [1. 架構概覽](#1-架構概覽)
- [2. Ubuntu VM 準備](#2-ubuntu-vm-準備)
  - [2.1 系統要求](#21-系統要求)
  - [2.2 基本套件安裝](#22-基本套件安裝)
  - [2.3 安裝 Docker](#23-安裝-docker)
  - [2.4 安裝 Docker Compose Plugin](#24-安裝-docker-compose-plugin)
- [3. 安裝 Harbor](#3-安裝-harbor)
  - [3.1 下載 Harbor](#31-下載-harbor)
  - [3.2 生成 TLS 證書](#32-生成-tls-證書)
  - [3.3 配置 harbor.yml](#33-配置-harbor.yml)
  - [3.4 執行安裝](#34-執行安裝)
  - [3.5 驗證 Harbor](#35-驗證-harbor)
- [4. 在 OCP 上 Trust Harbor 證書](#4-在-ocp-上-trust-harbor-證書)
- [5. 安裝 oc-mirror](#5-安裝-oc-mirror)
- [6. 建立 ImageSetConfiguration](#6-建立-imagesetconfiguration)
- [7. 執行 Mirror](#7-執行-mirror)
- [8. Apply Resources 到 OCP](#8-apply-resources-到-ocp)
- [9. 驗證 Mirror 結果](#9-驗證-mirror-結果)
- [10. 日常維護](#10-日常維護)
- [Appendix A: 常見問題](#appendix-a-常見問題)
- [Appendix B: 參考連結](#appendix-b-參考連結)

---

## 1. 架構概覽

```
Internet (慢)
    │
    │  oc-mirror download
    ▼
┌─────────────────────┐
│  Ubuntu VM          │
│  Harbor v2.15.2     │
│  (Mirror Registry)  │
│  <harbor-ip>:443    │
└─────────┬───────────┘
          │
          │  LAN Pull (快)
          ▼
┌─────────────────────┐
│  OCP 4.20.27        │
│  VMware Cluster     │
└─────────────────────┘
```

**流程：**
1. Ubuntu VM 安裝 Harbor
2. oc-mirror 從 registry.redhat.io download images → push 到 Harbor
3. Apply 生成嘅 YAML 到 OCP cluster
4. OCP cluster 從 Harbor pull images（LAN 速度）

---

## 2. Ubuntu VM 準備

### 2.1 系統要求

| 項目 | 最低要求 | 建議 |
|------|---------|------|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 100 GB | 200 GB+（視乎 mirror 幾多） |
| Network | Static IP | Static IP |

> **注意：** 如果要 mirror 成個 operator catalog，需要 350GB+。淨 mirror 指定 operators 約 50-80GB。

### 2.2 基本套件安裝

```bash
# 更新系統
sudo apt update && sudo apt upgrade -y

# 安裝基本工具
sudo apt install -y ca-certificates curl gnupg openssl \
  git jq tmux

# 安裝 tmux（oc-mirror 可能跑好耐，避免 SSH 斷線）
sudo apt install -y tmux
```

### 2.3 安裝 Docker

```bash
# 移除舊版 Docker（如果有）
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# 加 Docker 官方 GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 加 Docker apt repo
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 安裝 Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# 啟動 Docker
sudo systemctl enable docker
sudo systemctl start docker

# 驗證
docker --version
docker compose version
```

### 2.4 安裝 Docker Compose Plugin

Docker Compose Plugin 已經喺上面一步安裝咗。驗證：

```bash
docker compose version
# 應該顯示 Docker Compose v2.x.x
```

---

## 3. 安裝 Harbor

### 3.1 下載 Harbor

```bash
# 建立安裝目錄
sudo mkdir -p /opt/harbor
cd /opt/harbor

# 下載 Harbor v2.15.2 offline installer
sudo wget https://github.com/goharbor/harbor/releases/download/v2.15.2/harbor-offline-installer-v2.15.2.tgz

# 解壓
sudo tar xzf harbor-offline-installer-v2.15.2.tgz
cd harbor

# 你應該見到以下檔案
ls
# harbor.yml.tmpl  install.sh  common.sh  LICENSE
```

### 3.2 生成 TLS 證書

```bash
# 建立 cert 目錄
sudo mkdir -p /data/cert

# 生成 self-signed cert（替換 <HARBOR_IP> 為你嘅 VM IP）
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
  -nodes \
  -keyout /data/cert/server.key \
  -out /data/cert/server.crt \
  -subj "/CN=<HARBOR_IP>"

# 設定權限
sudo chmod 600 /data/cert/server.key
sudo chmod 644 /data/cert/server.crt
```

> **提示：** 3650 日 = 10 年有效期，lab 環境唔使太緊張。

### 3.3 配置 harbor.yml

```bash
# 複製範本
sudo cp harbor.yml.tmpl harbor.yml

# 編輯配置
sudo nano harbor.yml
```

修改以下項目：

```yaml
# 修改 hostname 為你嘅 VM IP
hostname: <HARBOR_IP>

# 修改 HTTPS 配置
https:
  port: 443
  certificate: /data/cert/server.crt
  key: /data/cert/server.key

# 修改 admin 密碼（重要！記低）
harbor_admin_password: <你嘅密碼>

# 其他保持預設
# database, data_volume, storage_service 等唔使改
```

> **注意：** 如果唔想用 HTTPS，可以註釋掉 https section 改用 HTTP。但 oc-mirror 建議用 HTTPS。

### 3.4 執行安裝

```bash
# 執行安裝（帶 Trivy vulnerability scanning）
sudo ./install.sh --with-trivy

# 安裝過程大約 5-10 分鐘，會見到：
# [Step 0]: checking if docker is installed ...
# [Step 1]: checking docker-compose is installed ...
# [Step 2]: loading the harbor images ...
# ...
# ✔ ----The installation has been completed successfully----
```

### 3.5 驗證 Harbor

```bash
# 查看所有 container 狀態
docker compose ps

# 應該見到以下 container 全部 Up：
# harbor-core
# harbor-db
# harbor-portal
# harbor-registry
# harbor-jobservice
# nginx
# redis
# trivy-adapter
# (可能仲有其他)

# 測試 HTTP 端口
curl -k https://<HARBOR_IP>/api/v2.0/health
# 應該返回 {"status":"healthy"}
```

**瀏覽器訪問：**
```
https://<HARBOR_IP>
用戶名: admin
密碼: 你喺 harbor.yml 設定嘅密碼
```

### 3.6 建立 Mirror 專用 Project

登入 Web UI 或者用 API：

```bash
# 用 API 建立 project
curl -k -u admin:<密碼> \
  -X POST "https://<HARBOR_IP>/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"ocp-mirror","public":true}'
```

---

## 4. 在 OCP 上 Trust Harbor 證書

OCP cluster 要 trust 你嘅 self-signed cert 先可以從 Harbor pull images。

### 4.1 攞 Harbor 證書

```bash
# 在 OCP 可以 reach 到 Harbor 嘅機上面執行
# 或者直接 copy harbor cert 到 OCP machine

openssl s_client -connect <HARBOR_IP>:443 -showcerts \
  </dev/null 2>/dev/null | \
  awk '/BEGIN/,/END/{print}' > harbor-ca.crt
```

### 4.2 建立 ConfigMap

```bash
# 用 oc apply
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-ca
  namespace: openshift-config
data:
  ca-bundle.crt: |
$(openssl s_client -connect <HARBOR_IP>:443 -showcerts \
  </dev/null 2>/dev/null | \
  awk '/BEGIN/,/END/{print}' | \
  sed 's/^/    /')
EOF
```

### 4.3 Patch API Server 嘅 CA

```bash
oc patch proxy/cluster \
  --type merge \
  -p '{"spec":{"trustedCA":{"name":"harbor-ca"}}}'
```

### 4.4 Patch Image Config

```bash
# 用 patch 加入 trustedCA
oc patch image.config.openshift.io/cluster \
  --type merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"harbor-ca"}}}'
```

### 4.5 等待 MCP rollout

```bash
# 觀望 MachineConfigPool rollout
oc get mcp
# 當所有 MCP 都 Updated=True 就 OK

# 驗證
oc get image.config.openshift.io/cluster -o yaml
# 應該見到 additionalTrustedCA 指向 harbor-ca
```

---

## 5. 安裝 oc-mirror

### 5.1 下載 oc-mirror v2

```bash
# 方法 1：直接下載 binary（推薦）
# 去 GitHub releases 攞最新版
# https://github.com/openshift/oc-mirror/releases

curl -LO https://github.com/openshift/oc-mirror/releases/latest/download/oc-mirror_linux_amd64.tar.gz
tar xzf oc-mirror_linux_amd64.tar.gz
sudo mv oc-mirror /usr/local/bin/
sudo chmod +x /usr/local/bin/oc-mirror

# 驗證
oc-mirror --version
```

### 5.2 設定 XDG_RUNTIME_DIR

> **重要：** oc-mirror v2 需要 `$XDG_RUNTIME_DIR` 先搵到 auth.json。部分系統預設為空，必須手動設定。

```bash
# 設定 XDG_RUNTIME_DIR（加落 .bashrc 永久生效）
export XDG_RUNTIME_DIR=/run/user/$(id -u)
echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> ~/.bashrc

# 驗證
echo $XDG_RUNTIME_DIR
# 應該顯示 /run/user/0 或 /run/user/<uid>
```

### 5.3 設定 Pull Secret

oc-mirror 需要 auth.json 同時包含：
- Red Hat Registry 憑證（registry.redhat.io）← 從 OCP pull secret
- Harbor 憑證（你嘅 mirror registry）← 從 Docker login
- 其他 registries（docker.io, quay.io 等）← 從現有 ~/.docker/config.json

```bash
# 建立 credentials 目錄
mkdir -p $XDG_RUNTIME_DIR/containers

# ── 方法 1：合併三個來源（推薦）──────────────────────────────────
# 如果你有現成 ~/.docker/config.json + ocp-pull-secret.yaml

# Step 1: 從 ~/.docker/config.json 開始（保留原有 docker.io, quay.io 等）
cat ~/.docker/config.json | jq . > $XDG_RUNTIME_DIR/containers/auth.json

# Step 2: 合佢 OCP pull secret（加入 registry.redhat.io 等 Red Hat 憑證）
jq -s '.[0] * .[1]' $XDG_RUNTIME_DIR/containers/auth.json ocp-pull-secret.yaml \
  > $XDG_RUNTIME_DIR/containers/auth.json.tmp \
  && mv $XDG_RUNTIME_DIR/containers/auth.json.tmp $XDG_RUNTIME_DIR/containers/auth.json

# Step 3: 加入 Harbor registry credentials
podman login <HARBOR_IP> -u admin -p '<密碼>'

# 驗證
jq '.auths | keys' $XDG_RUNTIME_DIR/containers/auth.json
# 應該見到: harbor.devops.local, registry.redhat.io, docker.io, quay.io 等

# ── 方法 2：只有 OCP pull secret（冇現成 Docker config）────────
# 從 Red Hat 下載 pull secret
# https://console.redhat.com/openshift/install/pull-secret

# 直接用 pull secret 作為 auth.json
cat ocp-pull-secret.yaml | jq . > $XDG_RUNTIME_DIR/containers/auth.json

# 加入 Harbor registry credentials
podman login <HARBOR_IP> -u admin -p '<密碼>'

# 驗證
jq '.auths | keys' $XDG_RUNTIME_DIR/containers/auth.json
# 應該見到: harbor.devops.local, registry.redhat.io 等
```

> **注意：** 方法 1 會保留你原有嘅所有 registries 憑證，唔會被覆蓋。方法 2 會淨係用 Red Hat pull secret，原有嘅 docker.io 等會冇咗。

---

## 6. 建立 ImageSetConfiguration

建立 `mirror-config.yaml`：

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: stable-4.20
        minVersion: 4.20.27
        maxVersion: 4.20.27
  operators:
    # Red Hat Operators Catalog
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
      packages:
        - name: openshift-gitops-operator
        - name: openshift-pipelines-operator-rh
        - name: servicemeshoperator3
        - name: kiali-operator
        - name: opentelemetry-operator
        - name: tempo-operator
        - name: compliance-operator
        - name: quay-bridge-operator
        - name: cert-manager-operator
        - name: advanced-cluster-management
        - name: k10-kasten-operator-rhmp
        - name: multicluster-engine
    # Certified Operators Catalog
    - catalog: registry.redhat.io/redhat/certified-operator-index:v4.20
      packages:
        - name: elasticsearch-eck-operator-certified
```

> **提示：** 如果之後要加新 operator，改呢個 config 再重新跑 oc-mirror 就得。

---

## 7. 執行 Mirror

### 7.1 建立工作目錄

```bash
mkdir -p /opt/mirror
cd /opt/mirror
```

### 7.2 執行 Mirror（建議用 tmux）

```bash
# 開 tmux（避免 SSH 斷線）
tmux new -s mirror

# 確保 XDG_RUNTIME_DIR 已設定
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# 執行 oc-mirror（standalone binary）
oc-mirror \
  -c /opt/mirror/mirror-config.yaml \
  --workspace file:///opt/mirror/workspace \
  docker://<HARBOR_IP>/ocp-mirror \
  --v2

# 注意：--v2 必須放喺最尾！
# 注意：用 -c 唔係 --config
```

> **時間估算：**
> - OCP release (~12GB): 約 15-30 分鐘（視乎 internet 速度）
> - Operators (~50-80GB): 約 1-3 小時
> - 完整 catalog (~350GB): 約 6-12 小時

### 7.3 完成後

Mirror 完成後會輸出類似：

```
INFO[0000] Writing ImageSetConfiguration to: /opt/mirror/workspace/imageset-config.yaml
INFO[0000] Writing IDMS to: /opt/mirror/workspace/cluster-resources/imageDigestMirrorSet.yaml
INFO[0000] Writing ITMS to: /opt/mirror/workspace/cluster-resources/imageTagMirrorSet.yaml
INFO[0000] Writing CatalogSource to: /opt/mirror/workspace/cluster-resources/catalogSource.yaml
```

**記低生成嘅檔案路徑：**
```bash
ls /opt/mirror/workspace/cluster-resources/
# imageDigestMirrorSet.yaml (IDMS)
# imageTagMirrorSet.yaml (ITMS)
# catalogSource.yaml
```

### 7.4 Copy 生成嘅檔案到 OCP 可以 access 嘅地方

```bash
# 方法 1：scp 到 OCP machine
scp /opt/mirror/workspace/cluster-resources/*.yaml \
  <OCP_USER>@<OCP_MASTER>:/tmp/

# 方法 2：直接在 OCP machine 上 oc apply
# 如果 OCP machine 可以 reach 到 mirror VM
```

---

## 8. Apply Resources 到 OCP

在 OCP cluster 上執行：

### 8.1 Apply ImageDigestMirrorSet + ImageTagMirrorSet

```bash
# v2 生成 IDMS + ITMS（取代舊版 ICSP）
oc apply -f /tmp/imageDigestMirrorSet.yaml
oc apply -f /tmp/imageTagMirrorSet.yaml
```

### 8.2 Apply CatalogSource

```bash
# 建立 mirror catalog source
oc apply -f /tmp/catalogSource.yaml
```

### 8.3 禁用 Default Catalog Sources（可選但建議）

```bash
# 如果你想全部從 mirror pull，禁用 default sources
oc patch OperatorHub cluster --type json \
  -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
```

> **警告：** 禁用後，所有 operator 必須從 mirror registry 安裝。

### 8.4 等待 MCP Rollout

```bash
# 觀望 MachineConfigPool
oc get mcp
# 當所有 Updated=True 就 OK

# 如果有問題，可以 debug
oc get mcp -o yaml
oc describe mcp master
```

### 8.5 重啟 Nodes（如果需要）

```bash
# 逐個 reboot（避免全部同時）
# 先 master
oc debug node/<master-1> -- chroot /host reboot
# 然後 worker
```

---

## 9. 驗證 Mirror 結果

### 9.1 驗證 CatalogSource

```bash
# 查看 catalog sources
oc get catalogsource -A
# 應該見到你 mirror 嘅 catalog source

# 查看 catalog pod 狀態
oc get pods -n openshift-marketplace
# catalog 應該 running
```

### 9.2 驗證 ImageDigestMirrorSet

```bash
oc get imagedigestmirrorset
oc describe imagedigestmirrorset
oc get imagetagmirrorset
```

### 9.3 驗證 Operator 安裝

```bash
# 查看可用 operators
oc get packagemanifest | grep openshift-gitops
# 應該見到你 mirror 嘅 operator

# 測試安裝一個 operator
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 9.4 在 Harbor Web UI 驗證

登入 Harbor Web UI：
```
https://<HARBOR_IP>
```

應該見到 `ocp-mirror` project 入面有所有 mirror 嘅 images。

---

## 10. 日常維護

### 10.1 更新 Mirror（加新 Operator）

```bash
# 改 mirror-config.yaml 加入新 operator
# 然後重新跑 oc-mirror（會自動 incremental）
cd /opt/mirror
oc-mirror \
  -c mirror-config.yaml \
  --workspace file:///opt/mirror/workspace \
  docker://<HARBOR_IP>/ocp-mirror \
  --v2

# 然後 apply 新生成嘅 YAML
```

### 10.2 更新 OCP Version

```yaml
# 改 mirror-config.yaml
mirror:
  platform:
    channels:
      - name: stable-4.20
        minVersion: 4.20.28  # 改新版本
        maxVersion: 4.20.28
```

```bash
# 重新 mirror
oc-mirror \
  -c mirror-config.yaml \
  --workspace file:///opt/mirror/workspace \
  docker://<HARBOR_IP>/ocp-mirror \
  --v2
```

### 10.3 Harbor 備份

```bash
# 停止 Harbor
cd /opt/harbor/harbor
docker compose down

# 備份 data
sudo tar -czf harbor-backup-$(date +%Y%m%d).tar.gz /data

# 重啟 Harbor
docker compose up -d
```

### 10.4 Harbor 更新

```bash
# 下載新版本
cd /opt/harbor
sudo wget https://github.com/goharbor/harbor/releases/download/v<新版本>/harbor-offline-installer-v<新版本>.tgz
sudo tar xzf harbor-offline-installer-v<新版本>.tgz
cd harbor

# 用新版本嘅 install.sh 重新安裝（會 upgrade）
sudo ./install.sh --with-trivy
```

---

## Appendix A: 常見問題

### Q1: registries.conf must be in v2 format

```bash
# registries.conf 係 v1 格式，oc-mirror v2 要 v2 格式
# 備份舊版
sudo cp /etc/containers/registries.conf /etc/containers/registries.conf.bak

# 建立 v2 格式
sudo tee /etc/containers/registries.conf << 'EOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "<HARBOR_IP>"
location = "<HARBOR_IP>"

[[registry]]
prefix = "registry.redhat.io"
location = "registry.redhat.io"
EOF
```

### Q2: $XDG_RUNTIME_DIR 為空

```bash
# 設定 XDG_RUNTIME_DIR
export XDG_RUNTIME_DIR=/run/user/$(id -u)
echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> ~/.bashrc

# 確認 auth.json 喺正確位置
ls -la $XDG_RUNTIME_DIR/containers/auth.json
```

### Q3: Push image timeout (context deadline exceeded)

```bash
# 加長 image timeout（預設 10m）
oc-mirror \
  -c mirror-config.yaml \
  --workspace file:///opt/mirror/workspace \
  docker://<HARBOR_IP>/ocp-mirror \
  --image-timeout 30m \
  --v2

# 檢查 Harbor nginx timeout
sudo vi /opt/harbor/harbor/common/config/nginx/nginx.conf
# 確認 proxy_read_timeout 同 proxy_send_timeout >= 900
```

### Q4: registry.redhat.io 認證失敗

```bash
# 確認 pull secret 正確
cat $XDG_RUNTIME_DIR/containers/auth.json | jq '.auths["registry.redhat.io"]'

# 如果過期，重新下載
# https://console.redhat.com/openshift/install/pull-secret
cat 新嘅pull-secret.json | jq . > $XDG_RUNTIME_DIR/containers/auth.json
podman login <HARBOR_IP> -u admin -p '<密碼>'
```

### Q5: oc-mirror 話 connection refused

```bash
# 確認 Harbor 係 running
docker compose ps

# 確認 cert 有問題
openssl s_client -connect <HARBOR_IP>:443

# 如果用 self-signed cert，確保 trust 咗
cat ~/.docker/config.json  # 確認有 login
```

### Q6: OCP pull image 失敗

```bash
# 確認 IDMS/ITMS 已 apply
oc get imagedigestmirrorset
oc get imagetagmirrorset

# 確認 MCP rollout 完成
oc get mcp

# 如果 MCP 卡住，檢查 nodes
oc get nodes
oc describe node <node-name>
```

### Q7: Harbor disk space 唔夠

```bash
# 清理 untagged images
# Harbor Web UI → Administration → Clean Up → GC

# 或者用 API
curl -k -u admin:<密碼> \
  -X POST "https://<HARBOR_IP>/api/v2.0/system/gc/schedule" \
  -H "Content-Type: application/json" \
  -d '{"parameters":{"delete_untagged":true,"dry_run":false},"schedule":{"type":"Custom","cron":"0 0 * * *"}}'
```

### Q8: tmux 斷咗點算

```bash
# 重新 attach
tmux attach -t mirror

# oc-mirror 有 cache，重新跑會 incremental
# 唔會由頭 download 返
```

### Q9: Harbor 裝完之後 HTTPS 有問題

```bash
# 檢查 cert 有冇過期
openssl x509 -in /data/cert/server.crt -noout -dates

# 檢查 Docker 有冇 trust cert
# Ubuntu trust /etc/docker/certs.d/ 下面嘅 cert
sudo mkdir -p /etc/docker/certs.d/<HARBOR_IP>
sudo cp /data/cert/server.crt /etc/docker/certs.d/<HARBOR_IP>/
sudo systemctl restart docker
```

---

## Appendix B: 參考連結

- Harbor GitHub: https://github.com/goharbor/harbor
- Harbor v2.15 Release: https://github.com/goharbor/harbor/releases/tag/v2.15.2
- Harbor Docs: https://goharbor.io/docs/
- oc-mirror GitHub: https://github.com/openshift/oc-mirror
- OCP 4.20 Mirror Guide: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/
- OCP 4.20 oc-mirror v2: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/disconnected_environments/about-installing-oc-mirror-v2

---

> **文件版本：** v1.1
> **建立日期：** 2026-08-27
> **最後更新：** 2026-08-28
> **適用環境：** OCP 4.20.27 + Harbor v2.15.2 on Ubuntu

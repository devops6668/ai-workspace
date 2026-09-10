# JupyterHub Keyring 加密方案

## 目錄

1. [需求聲明](#1-需求聲明)
2. [解決方案](#2-解決方案)
3. [Dockerfile](#3-dockerfile)
4. [Helm Values 部署](#4-helm-values-部署)
5. [User Setup - 加密和解密](#5-user-setup---加密和解密)

---

## 1. 需求聲明

### 問題
在 JupyterHub 多用戶環境中，用戶需要連接數據庫，但不想在 notebook 中明文儲存 username 和 password。

### 需求
- 用戶可以加密自己的 DB credentials
- Pod 重啟後 credentials 保留
- 用戶自己管理 encryption key
- 安全等級：AES 加密

### 約束
- 多用戶環境（每個用戶有自己的 AD account）
- K8s 部署（Helm chart）
- 用戶 PVC 掛載喺 `/home/jovyan/`

---

## 2. 解決方案

### 架構
```
用戶登入 JupyterHub (AD via Keycloak)
    ↓
JupyterHub 啟動用戶 Pod
    ↓
Pod 中有 EncryptedKeyring backend
    ↓
用戶喺 notebook 中設定 encryption key
    ↓
Credentials 加密存入 PVC
    ↓
Pod 重啟後，用戶再設定 encryption key
    ↓
Credentials 解密讀取
```

### 技術選型
- **Keyring Backend**: `keyrings.alt.file.EncryptedKeyring`
- **加密算法**: AES (PyCryptodome)
- **存儲位置**: `/home/jovyan/.local/share/python_keyring/keyring_pass.cfg`
- **Encryption Key**: 用戶自己設定（建議用自定 password）

### 優點
- ✅ 用戶自己管理 credentials
- ✅ AES 加密（比 Base64 安全）
- ✅ Pod 重啟後保留（喺用戶 PVC 入面）
- ✅ 多用戶隔離（每個用戶有自己的 keyring）

---

## 3. Dockerfile

```dockerfile
# 使用指定的 base image
FROM quay.io/jupyter/datascience-notebook:python-3.12.11

# 切换到 root 用户以安装软件
USER root

# 安装 Node.js 20（jupyter-ai v3.x 扩展构建需要）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl build-essential && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 安装 keyring 依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnome-keyring \
    libsecret-1-0 \
    dbus-x11 \
    libglib2.0-dev \
  && rm -rf /var/lib/apt/lists/*

# 強制升級 keyring 到最新版（覆蓋系統版本，確保有 file backend）
RUN pip install --no-cache-dir --force-reinstall "keyring>=25.7.0" && \
    pip install --no-cache-dir "keyrings.alt>=5.0.0" && \
    pip install --no-cache-dir "pycryptodome>=3.20.0"

# 更新 pip 并安装 Jupyter AI 3.0.1（稳定版本）
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    "jupyterlab>=4.4.0,<5.0.0" \
    "jupyter-ai[jupyternaut]==3.0.1" \
    "jupyter-ai-persona-manager>=0.0.11,<0.1.0" \
    "jupyter-ai-jupyternaut>=0.0.11,<0.1.0" \
    "jupyter-ai-litellm>=0.0.2,<0.1.0" \
    "litellm>=1.0.0" \
    "aiosqlite>=0.20.0" \
    "langgraph-checkpoint-sqlite>=3.0.0" \
    "secretstorage>=3.3.0"

# 修补 persona-manager 的 send_message 方法
# jupyternaut 调用 send_message(body, subtitle) 两个参数，
# 但 persona-manager 只接受一个参数，是上游 bug。
RUN python3 -c "import pathlib; import jupyter_ai_persona_manager; bp=pathlib.Path(jupyter_ai_persona_manager.__file__).parent/'base_persona.py'; s=bp.read_text(); s=s.replace('def send_message(self, body: str) -> None:', 'def send_message(self, body: str, subtitle: str = \"\") -> None:'); bp.write_text(s); print('Patched send_message')"

# 複製 entrypoint 腳本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 建立 keyring 目錄並設定權限
RUN mkdir -p /home/${NB_USER}/.local/share/keyrings && \
    mkdir -p /home/${NB_USER}/.local/share/python_keyring && \
    chown -R ${NB_UID}:${NB_GID} /home/${NB_USER}/.local

# 切换回默认用户
USER ${NB_UID}

# 设置工作目录
WORKDIR /home/${NB_USER}/work

# 暴露 Jupyter Lab 端口
EXPOSE 8888

# 使用 entrypoint 啟動
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["jupyterhub-singleuser", "--ip=0.0.0.0", "--port=8888", "--no-browser"]
```

### entrypoint.sh

```bash
#!/bin/bash
set -e

echo "=== Starting JupyterLab with Keyring Support ==="

# 1. 取得用戶名
USER_NAME=$(whoami)
echo "User: $USER_NAME"

# 2. 建立 keyring 目錄（包括 python_keyring）
KEYRING_DIR="/home/${USER_NAME}/.local/share/keyrings"
PYTHON_KEYRING_DIR="/home/${USER_NAME}/.local/share/python_keyring"
mkdir -p "${KEYRING_DIR}"
mkdir -p "${PYTHON_KEYRING_DIR}"
chmod 700 "${KEYRING_DIR}"
chmod 700 "${PYTHON_KEYRING_DIR}"
echo "✓ Keyring dir: $KEYRING_DIR"
echo "✓ Python keyring dir: $PYTHON_KEYRING_DIR"

# 3. 建立 keyring config（用 EncryptedKeyring）
CONFIG_DIR="/home/${USER_NAME}/.config"
mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_DIR}/keyringrc.cfg" << 'EOF'
[keyring]
backend = keyrings.alt.file.EncryptedKeyring
EOF
echo "✓ Keyring config created"

# 4. 啟動 JupyterHub singleuser
echo "✓ Starting JupyterHub singleuser..."
exec jupyterhub-singleuser --ip=0.0.0.0 --port=8888 --no-browser
```

---

## 4. Helm Values 部署

### values.yaml 新增 profile

```yaml
singleuser:
  profileList:
    - display_name: "Jupyter AI Coding v3.2.0 (keyring)"
      description: "Jupyter v3.2.0 keyring (AES encrypted)"
      kubespawner_override:
        image: quay.io/paulwong6668/jupyter-ai-agnes:DS-keyring-v1.0
        # Keyring-specific environment variables
        environment:
          DBUS_SESSION_BUS_ADDRESS: "unix:path=/tmp/runtime-$(NB_USER)/dbus.sock"
          GNOME_KEYRING_CONTROL: "/home/$(NB_USER)/.local/share/keyrings"
          XDG_RUNTIME_DIR: "/tmp/runtime-$(NB_USER)"
```

### 部署命令

```bash
cd /home/paul/jupyterhub
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub -f values.yaml --version 4.2.0
```

### 注意事項

1. **Image**: 需要先 push image 到 registry
2. **PVC**: 用戶嘅 PVC 會掛載喺 `/home/jovyan/`
3. **Keyring 目錄**: 已在 Dockerfile 中建立 `python_keyring` 目錄

---

## 5. User Setup - 加密和解密

### 首次設定（加密 credentials）

用戶喺 JupyterLab notebook 中執行：

```python
import keyring
import keyrings.alt.file
import getpass

print("=== 設定 Encryption Key ===")
print("呢個 key 會用嚟加密你嘅 credentials")
print("建議用你自定 password 或者其他 secret")
print()

# 1. 設定用 EncryptedKeyring
kr = keyrings.alt.file.EncryptedKeyring()
keyring.set_keyring(kr)

# 2. 用戶輸入 encryption key
encryption_key = getpass.getpass("請輸入 encryption key: ")

# 3. 設定 encryption key 到 keyring backend
kr.keyring_key = encryption_key
print(f"\n✓ Encryption key set")
print(f"Backend: {kr}")
print(f"Keyring file: {kr.file_path}")

# 4. 存入 credentials
keyring.set_password('mydb', 'paul.wong', '***')
print("✓ Credentials encrypted and stored")
```

### Pod 重啟後（解密 credentials）

用戶喺 JupyterLab notebook 中執行：

```python
import keyring
import keyrings.alt.file
import getpass

print("=== 讀取 Credentials ===")

# 1. 設定用 EncryptedKeyring
kr = keyrings.alt.file.EncryptedKeyring()
keyring.set_keyring(kr)

# 2. 用戶輸入 encryption key（用返之前嗰個）
encryption_key = getpass.getpass("請輸入 encryption key: ")

# 3. 設定 encryption key 到 keyring backend
kr.keyring_key = encryption_key
print(f"\n✓ Encryption key set")

# 4. 讀取 credentials
password = keyring.get_password('mydb', 'paul.wong')
print(f"✓ Retrieved: {'***' if password else 'NOT FOUND'}")

# 5. 使用 credentials 連接 DB
if password:
    from sqlalchemy import create_engine
    engine = create_engine(f"postgresql://paul.wong***@db-host/mydb")
    print("✓ Database connection ready")
```

### 連接數據庫（範例）

```python
import keyring
import keyrings.alt.file
import getpass
from sqlalchemy import create_engine
import pandas as pd

# 1. 設定 encryption key
kr = keyrings.alt.file.EncryptedKeyring()
keyring.set_keyring(kr)
encryption_key = getpass.getpass("請輸入 encryption key: ")
kr.keyring_key = encryption_key

# 2. 讀取 credentials
username = "paul.wong"
password = keyring.get_password('mydb', username)
host = "db.yourdomain.com"
database = "mydb"

if password:
    # 3. 連接數據庫
    engine = create_engine(f"postgresql://{username}***@{host}/{database}")
    
    # 4. 執行查詢
    df = pd.read_sql("SELECT * FROM my_table LIMIT 10", engine)
    print(df)
else:
    print("✗ Failed to retrieve password")
```

### 安全注意事項

1. **Encryption Key**: 建議用用戶嘅 password 或者其他 secret
2. **不要共享**: Encryption Key 不要與其他人共享
3. **Pod 重啟**: 每次 Pod 重啟都需要重新輸入 encryption key
4. **Keyring 檔案**: 存喺用戶嘅 PVC 入面，其他用戶睇唔到

### 故障排除

#### 問題 1: `ModuleNotFoundError: No module named 'Cryptodome'`
**解決方案**: 確保 Dockerfile 中有安裝 `pycryptodome`

#### 問題 2: `AttributeError: 'PlaintextKeyring' object has no attribute 'keyring_key'`
**解決方案**: 確保執行咗 `keyring.set_keyring(kr)` 設定 EncryptedKeyring

#### 問題 3: Pod 重啟後 credentials 丟失
**解決方案**: 
1. 確保用戶有執行 `keyring.set_password()` 去存 credentials
2. 確保 PVC 正確掛載喺 `/home/jovyan/`
3. 確保 `python_keyring` 目錄存在

---
### 結果
```
jovyan@jupyter-paul-wong---8c13526e:~/.local/share/python_keyring$ cat crypted_pass.cfg 
[mydb1]
paul_2ewong = 
        eyJzYWx0IjogIkUyNWdRaEJMTHU2QVd2MWpzc0FpeThteGNDR0hVZkRLQ1dkL0hjbitHWWc9Iiwg
        IklWIjogImRYYlRPa0FRV2pMVDNMYTR3cTd3V3c9PSIsICJwYXNzd29yZF9lbmNyeXB0ZWQiOiAi
        RzJ2L09hdS81ZWhtMlljPSJ9


```
---
## 總結

| 項目 | 內容 |
|------|------|
| **Encryption Algorithm** | AES (PyCryptodome) |
| **Keyring Backend** | `keyrings.alt.file.EncryptedKeyring` |
| **Storage Location** | `/home/jovyan/.local/share/python_keyring/keyring_pass.cfg` |
| **Encryption Key** | 用戶自己設定（建議自定  password） |
| **Pod 重啟** | 需要重新輸入 encryption key |
| **安全等級** | 高（AES 加密） |

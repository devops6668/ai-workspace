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

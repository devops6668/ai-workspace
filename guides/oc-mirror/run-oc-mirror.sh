#!/bin/bash
# oc-mirror 一鍵執行腳本
# 用法: ./run-oc-mirror.sh [OPTIONS]
#   --harbor-ip <IP>          Harbor registry IP (必填)
#   --config <path>           ImageSetConfiguration 路徑 (預設: ./mirror-config.yaml)
#   --workspace <path>        workspace 路徑 (預設: ./workspace)
#   --project <name>          Harbor project name (預設: ocp-mirror)
#   --image-timeout <min>     image push timeout (預設: 30m)
#   --dry-run                 只檢查環境，唔執行 mirror
#   --help                    顯示幫助

set -euo pipefail

# ── 默認值 ──────────────────────────────────────────────────────────────
HARBOR_IP=""
CONFIG="./mirror-config.yaml"
WORKSPACE="./workspace"
PROJECT="ocp-mirror"
IMAGE_TIMEOUT="30m"
DRY_RUN=false

# ── 解析參數 ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --harbor-ip)       HARBOR_IP="$2";          shift 2 ;;
    --config)          CONFIG="$2";             shift 2 ;;
    --workspace)       WORKSPACE="$2";          shift 2 ;;
    --project)         PROJECT="$2";            shift 2 ;;
    --image-timeout)   IMAGE_TIMEOUT="$2";      shift 2 ;;
    --dry-run)         DRY_RUN=true;            shift   ;;
    --help)            sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知參數: $1"; exit 1 ;;
  esac
done

# ── 基本檢查 ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Harbor IP 必填
[[ -z "$HARBOR_IP" ]] && error "請用 --harbor-ip <IP> 指定 Harbor IP"

REGISTRY="docker://${HARBOR_IP}/${PROJECT}"

# ── 環境檢查 ─────────────────────────────────────────────────────────────
check_cmd() { command -v "$1" &>/dev/null || error "'$1' 未安裝，請先安裝"; }

check_cmd oc-mirror
check_cmd podman

# XDG_RUNTIME_DIR
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR"
  warn "XDG_RUNTIME_DIR 未設定，已自動設為 $XDG_RUNTIME_DIR"
fi
info "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

# auth.json
AUTH_JSON="$XDG_RUNTIME_DIR/containers/auth.json"
if [[ ! -f "$AUTH_JSON" ]]; then
  error "auth.json 唔見: $AUTH_JSON"
fi
info "auth.json: $AUTH_JSON"

# Harbor 登入檢查
if ! grep -q "$HARBOR_IP" "$AUTH_JSON" 2>/dev/null; then
  warn "auth.json 入面冇 $HARBOR_IP 嘅記錄，請重新 podman login"
  exit 1
fi
info "Harbor 登入檢查通過"

# registry.redhat.io 檢查
if ! grep -q "registry.redhat.io" "$AUTH_JSON" 2>/dev/null; then
  warn "auth.json 入面冇 registry.redhat.io，鏡像可能 pull 唔到"
fi

# config 檢查
if [[ ! -f "$CONFIG" ]]; then
  error "config 唔見: $CONFIG"
fi
info "Config: $CONFIG"

# workspace 目錄
mkdir -p "$WORKSPACE"

# ── 顯示摘要 ─────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  oc-mirror 執行摘要"
echo "═══════════════════════════════════════════════════════════"
echo "  Registry:    $REGISTRY"
echo "  Config:      $CONFIG"
echo "  Workspace:   $WORKSPACE"
echo "  Image timeout: $IMAGE_TIMEOUT"
echo "  Dry run:     $DRY_RUN"
echo "═══════════════════════════════════════════════════════════"
echo ""

if $DRY_RUN; then
  info "Dry run 模式，只作環境檢查，唔會執行 mirror"
  exit 0
fi

# ── 執行 oc-mirror ───────────────────────────────────────────────────────
info "開始執行 oc-mirror..."
info "這可能需要數分鐘至數小時，視乎 mirror 內容大小"

oc-mirror \
  -c "$CONFIG" \
  --workspace "file:///$WORKSPACE" \
  "$REGISTRY" \
  --image-timeout "$IMAGE_TIMEOUT" \
  --v2

# ── 完成 ─────────────────────────────────────────────────────────────────
info "oc-mirror 完成！"
echo ""
info "生成嘅檔案:"
ls -la "$WORKSPACE/cluster-resources/" 2>/dev/null || true
echo ""
info "下一步: 將 cluster-resources/*.yaml apply 去 OCP cluster"
echo "  oc apply -f $WORKSPACE/cluster-resources/imageDigestMirrorSet.yaml"
echo "  oc apply -f $WORKSPACE/cluster-resources/imageTagMirrorSet.yaml"
echo "  oc apply -f $WORKSPACE/cluster-resources/catalogSource.yaml"

#!/bin/bash
# =============================================================================
# JupyterHub Deployment Script
# =============================================================================
# Usage: ./deploy.sh [namespace] [action]
# Examples:
#   ./deploy.sh jupyterhub install
#   ./deploy.sh jupyterhub upgrade
#   ./deploy.sh jupyterhub uninstall
#   ./deploy.sh jupyterhub status
# =============================================================================

set -e

# Configuration
NAMESPACE=${1:-jupyterhub}
ACTION=${2:-install}
RELEASE_NAME="jupyterhub"
CHART_REPO="https://hub.jupyter.org/helm-chart/"
CHART_NAME="jupyterhub/jupyterhub"
VALUES_FILE="$(dirname "$0")/values.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Pre-flight checks
# =============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    # kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi

    # helm
    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Please install Helm first."
        exit 1
    fi

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        exit 1
    fi

    log_info "All prerequisites met!"
}

# =============================================================================
# Create API Keys Secret
# =============================================================================
create_secrets() {
    log_info "Creating API keys secret..."

    if kubectl get secret jupyterhub-api-keys -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret jupyterhub-api-keys already exists. Skipping..."
    else
        echo -n "Enter OpenAI API Key: "
        read -s OPENAI_KEY
        echo

        echo -n "Enter Anthropic API Key (optional, press Enter to skip): "
        read -s ANTHROPIC_KEY
        echo

        echo -n "Enter LiteLLM Master Key: "
        read -s LITELLM_KEY
        echo

        # Create secret
        kubectl create secret generic jupyterhub-api-keys \
            --namespace "$NAMESPACE" \
            --from-literal=OPENAI_API_KEY="$OPENAI_KEY" \
            --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_KEY:-}" \
            --from-literal=LITELLM_MASTER_KEY="${LITELLM_KEY:-sk-change-me}"

        log_info "Secret created successfully!"
    fi
}

# =============================================================================
# Deploy JupyterHub
# =============================================================================
install_jupyterhub() {
    log_info "Installing JupyterHub..."

    # Add Helm repo
    helm repo add jupyterhub "$CHART_REPO" 2>/dev/null || true
    helm repo update

    # Create namespace
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Create secrets
    create_secrets

    # Install/Upgrade
    helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait \
        --timeout 10m

    log_info "JupyterHub installed successfully!"
    show_status
}

# =============================================================================
# Upgrade JupyterHub
# =============================================================================
upgrade_jupyterhub() {
    log_info "Upgrading JupyterHub..."

    helm upgrade "$RELEASE_NAME" "$CHART_NAME" \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait \
        --timeout 10m

    log_info "JupyterHub upgraded successfully!"
    show_status
}

# =============================================================================
# Uninstall JupyterHub
# =============================================================================
uninstall_jupyterhub() {
    log_warn "Uninstalling JupyterHub from namespace: $NAMESPACE"

    read -p "Are you sure? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE"
        log_info "JupyterHub uninstalled."
    else
        log_info "Cancelled."
    fi
}

# =============================================================================
# Show Status
# =============================================================================
show_status() {
    log_info "JupyterHub Status:"

    echo ""
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" -l "app=jupyterhub" -o wide

    echo ""
    echo "=== Services ==="
    kubectl get svc -n "$NAMESPACE"

    echo ""
    echo "=== Ingress (if any) ==="
    kubectl get ingress -n "$NAMESPACE" 2>/dev/null || true

    echo ""
    echo "=== Helm Release ==="
    helm list -n "$NAMESPACE"

    echo ""
    echo "=== Access JupyterHub ==="

    # Get service URL
    SVC_TYPE=$(kubectl get svc -n "$NAMESPACE" -l "app=jupyterhub" -o jsonpath='{.items[0].spec.type}')

    if [ "$SVC_TYPE" = "LoadBalancer" ]; then
        EXTERNAL_IP=$(kubectl get svc -n "$NAMESPACE" -l "app=jupyterhub" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
        if [ -n "$EXTERNAL_IP" ]; then
            echo "  URL: http://$EXTERNAL_IP:8888"
        else
            echo "  Waiting for LoadBalancer IP..."
            echo "  Run: kubectl get svc -n $NAMESPACE -w"
        fi
    elif [ "$SVC_TYPE" = "NodePort" ]; then
        NODE_PORT=$(kubectl get svc -n "$NAMESPACE" -l "app=jupyterhub" -o jsonpath='{.items[0].spec.ports[0].nodePort}')
        NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
        echo "  URL: http://${NODE_IP}:${NODE_PORT}"
    else
        echo "  ClusterIP - use port-forward:"
        echo "  kubectl port-forward -n $NAMESPACE svc/jupyterhub 8888:8888"
        echo "  Then open: http://localhost:8888"
    fi
}

# =============================================================================
# Main
# =============================================================================
check_prerequisites

case "$ACTION" in
    install)
        install_jupyterhub
        ;;
    upgrade)
        upgrade_jupyterhub
        ;;
    uninstall)
        uninstall_jupyterhub
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 [namespace] [install|upgrade|uninstall|status]"
        echo "  install   - Install JupyterHub"
        echo "  upgrade   - Upgrade JupyterHub"
        echo "  uninstall - Uninstall JupyterHub"
        echo "  status    - Show JupyterHub status"
        exit 1
        ;;
esac

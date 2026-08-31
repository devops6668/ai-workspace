#!/bin/bash
###############################################################################
# Phase 5 — Migrate Workload Namespaces from OSSM 2 to OSSM 3
#
# Based on: Step-by-Step Migration Guide_ OpenShift Service Mesh 2 to
#           Service Mesh 3.md
#
# This script automates Phase 5 (Section 9) of the migration guide.
# It iterates over each workload namespace, applies the OSSM 3 injection
# labels, rolls out the deployments, and verifies connectivity.
#
# IMPORTANT PREREQUISITES (must be done BEFORE running this script):
#   - Phase 1: SMCP upgraded to 2.6.14 and healthy
#   - Phase 2: OSSM 3 Operator + IstioCNI installed
#   - Phase 3: Istio resource deployed, activeRevision captured,
#              shared root certificate verified, mTLS strict mode applied
#   - Phase 4: Gateway migrated to OSSM 3
#
# USAGE:
#   chmod +x migrate_workload_namespaces.sh
#   ./migrate_workload_namespaces.sh [--dry-run] [--namespace <ns>] [--yes]
#
# FLAGS:
#   --dry-run    Show what would be done without executing
#   --namespace  Migrate only this specific namespace (repeatable)
#   --yes        Skip confirmation prompts
#
# ENVIRONMENT:
#   ACTIVE_REVISION  Override the detected revision (optional)
#
###############################################################################

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

# Workload namespaces to migrate (in order — migrate one at a time in prod)
DEFAULT_NAMESPACES=(
    project-01
    project-02
    project-03
    project-04
    devops
)

# Per-namespace deployment names for rollout-status waits
declare -A NAMESPACE_DEPLOYMENTS
NAMESPACE_DEPLOYMENTS[project-01]="hello-world1 hello-world2"
NAMESPACE_DEPLOYMENTS[project-02]="hello-world3 hello-world4"
NAMESPACE_DEPLOYMENTS[project-03]="hello-world5 hello-world6"
NAMESPACE_DEPLOYMENTS[project-04]="hello-world7 hello-world8"
NAMESPACE_DEPLOYMENTS[devops]="hello-world hello-world-nexus nginx-test example"

# Per-namespace hostnames for curl health checks
declare -A NAMESPACE_HOSTS
NAMESPACE_HOSTS[project-01]="hello-world1.devops.local hello-world2.devops.local"
NAMESPACE_HOSTS[project-02]="hello-world3.devops.local hello-world4.devops.local"
NAMESPACE_HOSTS[project-03]="hello-world5.devops.local hello-world6.devops.local"
NAMESPACE_HOSTS[project-04]="hello-world7.devops.local hello-world8.devops.local"
NAMESPACE_HOSTS[devops]="hello-world.devops.local"

# Istio system namespace
ISTIO_NS="istio-system"

# ─── Parse Arguments ────────────────────────────────────────────────────────

DRY_RUN=false
SPECIFIC_NAMESPACE=""
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true; shift ;;
        --namespace)
            SPECIFIC_NAMESPACE="$2"; shift 2 ;;
        --yes|-y)
            AUTO_YES=true; shift ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--dry-run] [--namespace <ns>] [--yes]" >&2
            exit 1 ;;
    esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
error()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

run_cmd() {
    # Execute a command, respecting --dry-run
    if $DRY_RUN; then
        log "[DRY-RUN] Would execute: $*"
        return 0
    fi
    eval "$@"
}

confirm() {
    if $AUTO_YES; then
        return 0
    fi
    echo -n "$1 [y/N] "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ─── Pre-flight Checks ──────────────────────────────────────────────────────

preflight_checks() {
    log "Running pre-flight checks..."

    # 1. Verify oc login
    if ! oc whoami &>/dev/null; then
        error "Not logged into OpenShift. Please run 'oc login' first."
        exit 1
    fi

    # 2. Verify cluster-admin
    if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
        warn "You may not have cluster-admin. Some operations might fail."
    fi

    # 3. Verify istioctl is available
    if ! command -v istioctl &>/dev/null; then
        error "istioctl is not in PATH. Please install istioctl matching Istio 1.24.x."
        exit 1
    fi

    # 4. Detect or require ACTIVE_REVISION
    if [[ -z "${ACTIVE_REVISION:-}" ]]; then
        ACTIVE_REVISION=$(oc get istios basic -n "$ISTIO_NS" \
            -o jsonpath='{.status.activeRevision}' 2>/dev/null || true)
        if [[ -z "$ACTIVE_REVISION" ]]; then
            error "No activeRevision found for Istio resource 'basic' in $ISTIO_NS."
            error "Phase 3 (deploy Istio resource) must be completed first."
            error "Set ACTIVE_REVISION env var to override, e.g.: ACTIVE_REVISION=basic-v1-24-3"
            exit 1
        fi
        log "Detected active revision: $ACTIVE_REVISION"
    else
        log "Using provided active revision: $ACTIVE_REVISION"
    fi

    # 5. Verify the Istio resource is Ready
    if ! $DRY_RUN; then
        istio_status=$(oc get istios basic -n "$ISTIO_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$istio_status" != "True" ]]; then
            warn "Istio resource status is '$istio_status'. Proceed with caution."
        else
            log "Istio resource is Ready."
        fi
    fi

    # 6. Verify namespaces exist
    for ns in "${MIGRATE_NAMESPACES[@]}"; do
        if ! oc get namespace "$ns" &>/dev/null; then
            warn "Namespace $ns does not exist — skipping."
        fi
    done

    log "Pre-flight checks passed."
}

# ─── Namespace Migration ────────────────────────────────────────────────────

migrate_namespace() {
    local ns="$1"

    log "═══════════════════════════════════════════════════════════"
    log "Migrating namespace: $ns"
    log "═══════════════════════════════════════════════════════════"

    # Step 1: Apply injection labels
    log "Step 1: Applying injection labels to $ns..."

    run_cmd "oc label namespace $ns \
        istio.io/rev=${ACTIVE_REVISION} \
        maistra.io/ignore-namespace=true \
        service-mesh=enabled \
        --overwrite=true"

    # Remove old OSSM 2 injection label if present
    run_cmd "oc label namespace $ns istio-injection- 2>/dev/null || true"

    # Verify labels applied
    if ! $DRY_RUN; then
        log "  Labels applied:"
        oc get namespace "$ns" -o jsonpath='{.metadata.labels}' 2>/dev/null | \
            python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in ['istio.io/rev','maistra.io/ignore-namespace','service-mesh']:
    if k in d:
        print(f'  {k} = {d[k]}')
" 2>/dev/null || true
    fi

    # Step 2: Rollout restart all deployments
    log "Step 2: Rolling out deployments in $ns..."

    local deployments="${NAMESPACE_DEPLOYMENTS[$ns]:-}"
    if [[ -z "$deployments" ]]; then
        # Fallback: restart ALL deployments in the namespace
        deployments=$(oc get deployments -n "$ns" -o name 2>/dev/null | sed 's|deployment.apps/||' || true)
        if [[ -z "$deployments" ]]; then
            warn "No deployments found in $ns — skipping rollout."
            return 0
        fi
        log "  (Fallback: detected deployments: $deployments)"
    fi

    run_cmd "oc rollout restart deployment -n $ns"

    # Wait for each deployment individually
    for dep in $deployments; do
        log "  Waiting for deployment/$dep to be ready..."
        if ! $DRY_RUN; then
            if ! oc rollout status "deployment/$dep" -n "$ns" --timeout=300s 2>/dev/null; then
                warn "  Deployment $dep did not become ready within 300s."
                log "  Showing pod status for $ns:"
                oc get pods -n "$ns" -l "app=$dep" 2>/dev/null || true
            fi
        fi
    done

    # Step 3: Verify pods are connected to OSSM 3
    log "Step 3: Verifying proxy connections in $ns..."

    if ! $DRY_RUN; then
        local ossm2_pods
        ossm2_pods=$(istioctl ps --istioNamespace "$ISTIO_NS" --revision basic \
            -n "$ns" 2>/dev/null | tail -n +2 || true)
        if [[ -n "$ossm2_pods" ]]; then
            warn "  Pods still connected to OSSM 2 (revision 'basic') in $ns:"
            echo "$ossm2_pods" | sed 's/^/    /'
            warn "  These pods may need a manual rollout restart."
        else
            log "  No pods found on OSSM 2 — good."
        fi

        local ossm3_pods
        ossm3_pods=$(istioctl ps --istioNamespace "$ISTIO_NS" --revision "$ACTIVE_REVISION" \
            -n "$ns" 2>/dev/null | tail -n +2 || true)
        if [[ -n "$ossm3_pods" ]]; then
            log "  Pods connected to OSSM 3 (revision '$ACTIVE_REVISION') in $ns:"
            echo "$ossm3_pods" | sed 's/^/    /'
        else
            warn "  No pods found on OSSM 3 yet. They may still be restarting."
        fi
    fi

    # Step 4: Test application connectivity (if hosts are defined)
    log "Step 4: Testing application connectivity for $ns..."

    local hosts="${NAMESPACE_HOSTS[$ns]:-}"
    if [[ -n "$hosts" ]]; then
        for host in $hosts; do
            if ! $DRY_RUN; then
                log "  Checking https://${host}/ ..."
                local http_code
                http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
                    "https://${host}/" 2>/dev/null || echo "000")
                if [[ "$http_code" == "200" ]]; then
                    log "  ✓ $host → HTTP $http_code"
                elif [[ "$http_code" == "000" ]]; then
                    warn "  ✗ $host → Connection refused or timeout"
                else
                    warn "  ✗ $host → HTTP $http_code (expected 200)"
                fi
            else
                log "  [DRY-RUN] Would check https://${host}/"
            fi
        done
    else
        log "  No hosts defined for $ns — skipping connectivity test."
    fi

    log "Migration of $ns complete."
    log ""
}

# ─── Final Verification ─────────────────────────────────────────────────────

final_verification() {
    log "═══════════════════════════════════════════════════════════"
    log "Final Verification"
    log "═══════════════════════════════════════════════════════════"

    if ! $DRY_RUN; then
        # Check for any remaining OSSM 2 proxies
        log "Checking for remaining OSSM 2 proxies..."
        local remaining
        remaining=$(istioctl ps --istioNamespace "$ISTIO_NS" --revision basic \
            2>/dev/null | tail -n +2 || true)
        if [[ -n "$remaining" ]]; then
            warn "Pods still on OSSM 2:"
            echo "$remaining" | sed 's/^/  /'
        else
            log "  No pods remain on OSSM 2 — all migrated!"
        fi

        # Check all OSSM 3 proxies
        log "Listing all OSSM 3 proxies..."
        istioctl ps --istioNamespace "$ISTIO_NS" --revision "$ACTIVE_REVISION" 2>/dev/null

        # Verify gateway is healthy
        log "Checking gateway pods..."
        oc get pods -n "$ISTIO_NS" -l istio=ingressgateway 2>/dev/null || \
            log "  (gateway label not found — may use different selector)"
    fi

    log "Final verification complete."
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    log "OSSM 2 → OSSM 3 Workload Migration Script"
    log "Active Revision: ${ACTIVE_REVISION:-<not set yet>}"
    log "Dry Run: $DRY_RUN"
    log ""

    # Determine which namespaces to migrate
    if [[ -n "$SPECIFIC_NAMESPACE" ]]; then
        MIGRATE_NAMESPACES=("$SPECIFIC_NAMESPACE")
    else
        MIGRATE_NAMESPACES=("${DEFAULT_NAMESPACES[@]}")
    fi

    log "Namespaces to migrate: ${MIGRATE_NAMESPACES[*]}"
    log ""

    # Pre-flight
    preflight_checks
    log ""

    # Confirmation
    if ! $DRY_RUN && ! $AUTO_YES; then
        if ! confirm "Start migrating ${#MIGRATE_NAMESPACES[@]} namespace(s)?"; then
            log "Aborted by user."
            exit 0
        fi
    fi

    # Migrate each namespace one at a time
    for ns in "${MIGRATE_NAMESPACES[@]}"; do
        migrate_namespace "$ns"

        # Pause between namespaces (only in non-dry-run mode)
        if [[ "$ns" != "${MIGRATE_NAMESPACES[-1]}" ]] && ! $DRY_RUN; then
            log "Waiting 10 seconds before migrating next namespace..."
            sleep 10
        fi
    done

    # Final verification
    final_verification

    log ""
    log "═══════════════════════════════════════════════════════════"
    log "Phase 5 migration complete!"
    log "Next: Phase 6 — Update Gateway Resources and Finalise"
    log "═══════════════════════════════════════════════════════════"
}

main "$@"

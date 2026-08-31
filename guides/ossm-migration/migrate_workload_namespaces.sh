#!/bin/bash
###############################################################################
# Phase 5 — Migrate Workload Namespaces from OSSM 2 to OSSM 3
#
# Based on: Step-by-Step Migration Guide_ OpenShift Service Mesh 2 to
#           Service Mesh 3.md
#
# This script automates Phase 5 (Section 9) of the migration guide.
# It discovers mesh member namespaces from the ServiceMeshMemberRoll,
# applies OSSM 3 injection labels, rolls out deployments, and verifies
# connectivity.
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
#
#   # Migrate ALL mesh member namespaces (skips empty ones):
#   ./migrate_workload_namespaces.sh
#
#   # Migrate specific namespaces only:
#   ./migrate_workload_namespaces.sh project-01 project-02
#
#   # Dry run (shows what would be done without executing):
#   ./migrate_workload_namespaces.sh --dry-run project-01
#
#   # Skip confirmation prompts:
#   ./migrate_workload_namespaces.sh --yes
#
# FLAGS:
#   --dry-run    Show what would be done without executing
#   --yes/-y     Skip confirmation prompts
#
# ENVIRONMENT:
#   ACTIVE_REVISION   Override the detected revision (optional)
#   ISTIO_NS          Namespace where Istio/SMCP lives (default: istio-system)
#   SKIP_EMPTY        Set to "yes" to skip namespaces with no deployments
#
###############################################################################

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

ISTIO_NS="${ISTIO_NS:-istio-system}"
SKIP_EMPTY="${SKIP_EMPTY:-yes}"

# ─── Parse Arguments ────────────────────────────────────────────────────────

DRY_RUN=false
AUTO_YES=false
TARGET_NAMESPACES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true; shift ;;
        --yes|-y)
            AUTO_YES=true; shift ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--dry-run] [--yes] [namespace1 [namespace2 ...]]" >&2
            exit 1 ;;
        *)
            TARGET_NAMESPACES+=("$1"); shift ;;
    esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }
error()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

run_cmd() {
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

# ─── Discover Namespaces ────────────────────────────────────────────────────

discover_namespaces() {
    if [[ ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
        # User specified namespaces explicitly
        log "Using user-specified namespaces: ${TARGET_NAMESPACES[*]}"
        return
    fi

    # Discover from ServiceMeshMemberRoll
    log "Discovering mesh member namespaces from ServiceMeshMemberRoll..."
    local members
    members=$(oc get smmr default -n "$ISTIO_NS" \
        -o jsonpath='{.spec.members}' 2>/dev/null || true)

    if [[ -z "$members" ]]; then
        error "Could not read ServiceMeshMemberRoll 'default' from $ISTIO_NS."
        error "Is the SMR resource named 'default'? Check with:"
        error "  oc get smmr -n $ISTIO_NS"
        exit 1
    fi

    # Parse JSON array into bash array
    while IFS= read -r ns; do
        TARGET_NAMESPACES+=("$ns")
    done < <(echo "$members" | tr ',' '\n' | tr -d '[]" ')

    log "Found ${#TARGET_NAMESPACES[@]} mesh member namespaces: ${TARGET_NAMESPACES[*]}"
}

# ─── Detect Active Revision ─────────────────────────────────────────────────

detect_revision() {
    if [[ -n "${ACTIVE_REVISION:-}" ]]; then
        log "Using provided active revision: $ACTIVE_REVISION"
        return
    fi

    ACTIVE_REVISION=$(oc get istios basic -n "$ISTIO_NS" \
        -o jsonpath='{.status.activeRevision}' 2>/dev/null || true)

    if [[ -z "$ACTIVE_REVISION" ]]; then
        error "No activeRevision found for Istio resource 'basic' in $ISTIO_NS."
        error "Phase 3 (deploy Istio resource) must be completed first."
        error "Set ACTIVE_REVISION env var to override, e.g.:"
        error "  ACTIVE_REVISION=basic-v1-24-3 ./migrate_workload_namespaces.sh"
        exit 1
    fi

    log "Detected active revision: $ACTIVE_REVISION"
}

# ─── Preflight Checks ───────────────────────────────────────────────────────

preflight_checks() {
    log "Running pre-flight checks..."

    if ! oc whoami &>/dev/null; then
        error "Not logged into OpenShift. Please run 'oc login' first."
        exit 1
    fi

    if ! command -v istioctl &>/dev/null; then
        error "istioctl is not in PATH. Please install istioctl matching Istio 1.24.x."
        exit 1
    fi

    # Check Istio resource status
    if ! $DRY_RUN; then
        local istio_status
        istio_status=$(oc get istios basic -n "$ISTIO_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$istio_status" == "True" ]]; then
            log "Istio resource is Ready."
        else
            warn "Istio resource status is '$istio_status'. Proceed with caution."
        fi
    fi

    log "Pre-flight checks passed."
}

# ─── Get Deployments in a Namespace ─────────────────────────────────────────

get_deployments() {
    local ns="$1"
    if ! $DRY_RUN; then
        oc get deployments -n "$ns" -o name 2>/dev/null | sed 's|deployment.apps/||' || true
    fi
}

# ─── Get Hosts for Connectivity Test ────────────────────────────────────────

# Derives hostnames from deployment names.
# Convention: deployment name "hello-world1" → host "hello-world1.<cluster-domain>"
# Override by setting HOST_SUFFIX env var (default: .devops.local)
HOST_SUFFIX="${HOST_SUFFIX:-.devops.local}"

get_hosts_for_namespace() {
    local ns="$1"
    local deployments
    deployments=$(get_deployments "$ns")

    local hosts=()
    for dep in $deployments; do
        # Skip common infrastructure deployments that are not exposed externally
        case "$dep" in
            curl|dotnet|nginx*|dind|poc-*)
                continue ;;
        esac
        hosts+=("${dep}${HOST_SUFFIX}")
    done

    echo "${hosts[*]}"
}

# ─── Migrate a Single Namespace ─────────────────────────────────────────────

migrate_namespace() {
    local ns="$1"

    log "═══════════════════════════════════════════════════════════"
    log "Migrating namespace: $ns"
    log "═══════════════════════════════════════════════════════════"

    # Verify namespace exists
    if ! $DRY_RUN; then
        if ! oc get namespace "$ns" &>/dev/null; then
            warn "Namespace $ns does not exist — skipping."
            return 0
        fi
    fi

    # Step 1: Apply injection labels
    log "Step 1: Applying injection labels to $ns..."

    run_cmd "oc label namespace $ns \
        istio.io/rev=${ACTIVE_REVISION} \
        maistra.io/ignore-namespace=true \
        service-mesh=enabled \
        --overwrite=true"

    # Remove old OSSM 2 injection label if present
    run_cmd "oc label namespace $ns istio-injection- 2>/dev/null || true"

    # Verify labels
    if ! $DRY_RUN; then
        log "  Applied labels:"
        for label_key in istio.io/rev maistra.io/ignore-namespace service-mesh; do
            local val
            val=$(oc get namespace "$ns" -o jsonpath="{.metadata.labels.${label_key}}" 2>/dev/null || echo "<not set>")
            log "    ${label_key} = ${val}"
        done
    fi

    # Step 2: Get deployments to restart
    local deployments
    deployments=$(get_deployments "$ns")

    if [[ -z "$deployments" ]]; then
        if [[ "$SKIP_EMPTY" == "yes" ]]; then
            log "  No deployments found in $ns — skipping rollout."
            return 0
        else
            warn "  No deployments found in $ns but SKIP_EMPTY is not set."
        fi
    fi

    log "  Found ${#deployments[@]} deployment(s): $deployments"

    # Step 3: Rollout restart
    log "Step 2: Rolling out deployments in $ns..."

    run_cmd "oc rollout restart deployment -n $ns"

    # Wait for each deployment individually
    for dep in $deployments; do
        log "  Waiting for deployment/$dep to be ready..."
        if ! $DRY_RUN; then
            if ! oc rollout status "deployment/$dep" -n "$ns" --timeout=300s 2>/dev/null; then
                warn "  Deployment $dep did not become ready within 300s."
                log "  Showing pod status:"
                oc get pods -n "$ns" -l "app=$dep" 2>/dev/null || true
            fi
        fi
    done

    # Step 4: Verify proxy connections
    log "Step 3: Verifying proxy connections in $ns..."

    if ! $DRY_RUN; then
        # Check for remaining OSSM 2 proxies
        local ossm2_pods
        ossm2_pods=$(istioctl ps --istioNamespace "$ISTIO_NS" --revision basic \
            -n "$ns" 2>/dev/null | tail -n +2 || true)
        if [[ -n "$ossm2_pods" ]]; then
            warn "  Pods still on OSSM 2 (revision 'basic'):"
            echo "$ossm2_pods" | sed 's/^/    /'
            warn "  These may need a manual rollout restart."
        else
            log "  No pods remain on OSSM 2 — good."
        fi

        # Check OSSM 3 proxies
        local ossm3_pods
        ossm3_pods=$(istioctl ps --istioNamespace "$ISTIO_NS" --revision "$ACTIVE_REVISION" \
            -n "$ns" 2>/dev/null | tail -n +2 || true)
        if [[ -n "$ossm3_pods" ]]; then
            log "  Pods connected to OSSM 3 (revision '$ACTIVE_REVISION'):"
            echo "$ossm3_pods" | sed 's/^/    /'
        else
            warn "  No pods found on OSSM 3 yet (may still be restarting)."
        fi
    fi

    # Step 5: Test connectivity
    log "Step 4: Testing application connectivity for $ns..."

    local hosts
    hosts=$(get_hosts_for_namespace "$ns")

    if [[ -z "$hosts" ]]; then
        log "  No externally exposed hosts found in $ns — skipping connectivity test."
    else
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

        log "Listing all OSSM 3 proxies:"
        istioctl ps --istioNamespace "$ISTIO_NS" --revision "$ACTIVE_REVISION" 2>/dev/null
    fi

    log "Final verification complete."
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    log "OSSM 2 → OSSM 3 Workload Migration Script"
    log "Istio Namespace: $ISTIO_NS"
    log "Dry Run: $DRY_RUN"
    log ""

    # Discover namespaces
    discover_namespaces

    if [[ ${#TARGET_NAMESPACES[@]} -eq 0 ]]; then
        error "No namespaces to migrate."
        exit 1
    fi

    log "Namespaces to migrate: ${TARGET_NAMESPACES[*]}"
    log ""

    # Detect revision
    detect_revision

    # Preflight
    preflight_checks
    log ""

    # Confirmation
    if ! $DRY_RUN && ! $AUTO_YES; then
        if ! confirm "Start migrating ${#TARGET_NAMESPACES[@]} namespace(s)?"; then
            log "Aborted by user."
            exit 0
        fi
    fi

    # Migrate each namespace
    for ns in "${TARGET_NAMESPACES[@]}"; do
        migrate_namespace "$ns"

        # Pause between namespaces (non-dry-run only)
        if [[ "$ns" != "${TARGET_NAMESPACES[-1]}" ]] && ! $DRY_RUN; then
            log "Waiting 10 seconds before next namespace..."
            sleep 10
        fi
    done

    # Final verification
    final_verification

    log ""
    log "═══════════════════════════════════════════════════════════"
    log "Phase 5 migration complete!"
    log "═══════════════════════════════════════════════════════════"
}

main "$@"

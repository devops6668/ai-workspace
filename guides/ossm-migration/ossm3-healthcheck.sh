#!/usr/bin/env bash
#
# OSSM3 Health Check Script
# Checks OpenShift Service Mesh 3 installation status, control plane, data plane,
# cross-mesh connectivity, and cleanup of old OSSM2 resources.
#
# Usage: ./ossm3-healthcheck.sh [--output report.txt] [--skip-connectivity]
# Requires: oc, istioctl installed and authenticated to the cluster.

set -uo pipefail

OUTPUT=""
SKIP_CONNECTIVITY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --skip-connectivity|-s) SKIP_CONNECTIVITY=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

SEP="================================================================================"
SUBSEP="--------------------------------------------------------------------------------"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass()  { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
info()  { printf "${CYAN}       %s${NC}\n" "$1"; }
section() { echo ""; echo "$SEP"; printf "${GREEN}%s${NC}\n" "$1"; echo "$SEP"; }

# ─── Pre-flight ───────────────────────────────────────────────────────────────

section "Pre-flight Checks"

for cmd in oc istioctl; do
  if command -v "$cmd" &>/dev/null; then
    pass "$cmd found ($(which "$cmd"))"
  else
    fail "$cmd not found in PATH"
    exit 1
  fi
done

if oc whoami &>/dev/null 2>&1; then
  pass "Authenticated as $(oc whoami 2>/dev/null)"
else
  fail "Not authenticated to OpenShift cluster"
  exit 1
fi

CLUSTER_CONTEXT=$(oc config current-context 2>/dev/null || echo "unknown")
info "Cluster context: $CLUSTER_CONTEXT"

# Discover the Istio CR — try common namespaces
ISTIO_NS=""
ISTIO_NAME=""
for candidate_ns in istio-system openshift-service-mesh; do
  n=$(oc get istio -n "$candidate_ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$n" ]; then
    ISTIO_NS="$candidate_ns"
    ISTIO_NAME="$n"
    break
  fi
done

if [ -n "$ISTIO_NS" ] && [ -n "$ISTIO_NAME" ]; then
  pass "Istio CR found: $ISTIO_NS/$ISTIO_NAME"
else
  warn "No Istio CR found (sailoperator.io/v1) in istio-system or openshift-service-mesh"
fi

echo ""

# ─── 1. Control Plane Status ─────────────────────────────────────────────────

section "1. Control Plane — Istio/$ISTIO_NS/$ISTIO_NAME"

if [ -z "$ISTIO_NS" ] || [ -z "$ISTIO_NAME" ]; then
  fail "No Istio CR found, skipping detailed checks"
else
  state=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
  active_rev=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.activeRevisionName}' 2>/dev/null || echo "unknown")
  obs_gen=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "unknown")
  gen=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "unknown")
  spec_version=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.spec.version}' 2>/dev/null || echo "unknown")
  ustrategy=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.spec.updateStrategy.type}' 2>/dev/null || echo "unknown")

  pass "State: $state"
  pass "Active Revision: $active_rev"
  pass "Version: $spec_version"
  pass "Update Strategy: $ustrategy"

  if [ "$obs_gen" = "$gen" ]; then
    pass "Fully reconciled (observed gen = $obs_gen)"
  else
    warn "Not yet reconciled (observed=$obs_gen, generation=$gen)"
  fi

  for cond_type in Ready Reconciled; do
    cond_status=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath="{.status.conditions[?(@.type==\"$cond_type\")].status}" 2>/dev/null || echo "?")
    if [ "$cond_status" = "True" ]; then
      pass "Condition $cond_type = True"
    elif [ "$cond_status" = "?" ]; then
      warn "Condition $cond_type not found"
    else
      fail "Condition $cond_type = $cond_status"
    fi
  done

  rev_total=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.revisions.total}' 2>/dev/null || echo "?")
  rev_ready=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.revisions.ready}' 2>/dev/null || echo "?")
  rev_inuse=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.revisions.inUse}' 2>/dev/null || echo "?")
  pass "Revisions: total=$rev_total ready=$rev_ready inUse=$rev_inuse"
fi

echo ""

# ─── 2. Istiod Pods ──────────────────────────────────────────────────────────

section "2. Istiod Pods"

istiod_pods=$(oc get pods -n "$ISTIO_NS" -l app=istiod -o name 2>/dev/null || echo "")
if [ -z "$istiod_pods" ]; then
  istiod_pods=$(oc get pods -n istio-system -l app=istiod -o name 2>/dev/null || echo "")
fi

if [ -z "$istiod_pods" ]; then
  fail "No istiod pods found"
else
  pod_count=0
  running_count=0
  error_count=0
  for pod in $istiod_pods; do
    pod_name="${pod#pod/}"
    pod_status=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    pod_ready=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    pod_restarts=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    pod_node=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "?")
    pod_age=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    pod_count=$((pod_count + 1))

    if [ "$pod_status" = "Running" ] && [ "$pod_ready" = "true" ]; then
      running_count=$((running_count + 1))
      pass "$pod_name — Running on $pod_node (restarts: $pod_restarts, age: $pod_age)"
    else
      fail "$pod_name — Status: $pod_status, Ready: $pod_ready"
    fi

    errs=$(oc logs "$pod" -n "$ISTIO_NS" --tail=200 2>/dev/null | grep -ciE '(error|fatal|panic)' || true)
    if [ "$errs" -gt 0 ]; then
      warn "$pod_name: $errs error lines in last 200 log lines"
      oc logs "$pod" -n "$ISTIO_NS" --tail=50 2>/dev/null | grep -iE '(error|fatal|panic)' | tail -3 | while read -r eline; do info "  $eline"; done
      error_count=$((error_count + errs))
    fi
  done
  pass "Istiod pods: $running_count/$pod_count running"
  if [ "$error_count" -eq 0 ]; then
    pass "No errors in istiod logs"
  fi
fi

echo ""

# ─── 3. Ingress Gateway ──────────────────────────────────────────────────────

section "3. Ingress Gateway"

gw_pods=$(oc get pods -n "$ISTIO_NS" -l app=istio-ingressgateway -o name 2>/dev/null || echo "")
if [ -z "$gw_pods" ]; then
  gw_pods=$(oc get pods -n istio-system -l app=istio-ingressgateway -o name 2>/dev/null || echo "")
fi

if [ -z "$gw_pods" ]; then
  warn "No ingress gateway pods found"
else
  gw_running=0
  gw_total=0
  for pod in $gw_pods; do
    pod_name="${pod#pod/}"
    pod_status=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    pod_ready=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    pod_restarts=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    pod_node=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "?")
    gw_total=$((gw_total + 1))

    if [ "$pod_status" = "Running" ] && [ "$pod_ready" = "true" ]; then
      gw_running=$((gw_running + 1))
      pass "$pod_name — Running on $pod_node (restarts: $pod_restarts)"
    else
      fail "$pod_name — Status: $pod_status, Ready: $pod_ready"
    fi
  done
  pass "Ingress gateway: $gw_running/$gw_total running"
fi

info "Gateway Services:"
oc get svc -n "$ISTIO_NS" 2>/dev/null | grep -i ingress | while read -r line; do info "  $line"; done

echo ""

# ─── 4. Kiali ─────────────────────────────────────────────────────────────────

section "4. Kiali"

kiali_pods=$(oc get pods -n "$ISTIO_NS" -l app.kubernetes.io/name=kiali -o name 2>/dev/null || echo "")
if [ -z "$kiali_pods" ]; then
  kiali_pods=$(oc get pods -n "$ISTIO_NS" -l app=kiali -o name 2>/dev/null || echo "")
fi

if [ -z "$kiali_pods" ]; then
  warn "No Kiali pods found"
else
  kiali_running=0
  kiali_total=0
  for pod in $kiali_pods; do
    pod_name="${pod#pod/}"
    pod_status=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    pod_ready=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    pod_restarts=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    kiali_total=$((kiali_total + 1))

    if [ "$pod_status" = "Running" ] && [ "$pod_ready" = "true" ]; then
      kiali_running=$((kiali_running + 1))
      pass "$pod_name — Running (restarts: $pod_restarts)"
    else
      fail "$pod_name — Status: $pod_status, Ready: $pod_ready"
    fi
  done
  pass "Kiali: $kiali_running/$kiali_total running"
fi

info "Kiali Service:"
oc get svc -n "$ISTIO_NS" 2>/dev/null | grep -i kiali | while read -r line; do info "  $line"; done

echo ""

# ─── 5. MeshConfig Summary ───────────────────────────────────────────────────

section "5. MeshConfig Summary"

if [ -n "$ISTIO_NS" ] && [ -n "$ISTIO_NAME" ]; then
  for key in enableAutoMtls enableTracing enablePrometheusMerge ingressControllerMode; do
    val=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath="{.spec.values.meshConfig.$key}" 2>/dev/null || echo "N/A")
    info "$key: $val"
  done

  tls_min=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.spec.values.meshConfig.tlsDefaults.minProtocolVersion}' 2>/dev/null || echo "N/A")
  trace_sampling=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.spec.values.pilot.traceSampling}' 2>/dev/null || echo "N/A")
  dns_refresh=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.spec.values.meshConfig.dnsRefreshRate}' 2>/dev/null || echo "N/A")
  info "tlsDefaults.minProtocolVersion: $tls_min"
  info "traceSampling: ${trace_sampling}%"
  info "dnsRefreshRate: ${dns_refresh}"
else
  info "No Istio CR found, skipping MeshConfig"
fi

echo ""

# ─── 6. Gateway API Resources ────────────────────────────────────────────────

section "6. Gateway API Resources"

vs_count=$(oc get vs -A --no-headers 2>/dev/null | wc -l)
vs_count=$(echo "$vs_count" | tr -d '[:space:]')
dr_count=$(oc get dr -A --no-headers 2>/dev/null | wc -l)
dr_count=$(echo "$dr_count" | tr -d '[:space:]')
gw_count=$(oc get gw -A --no-headers 2>/dev/null | wc -l)
gw_count=$(echo "$gw_count" | tr -d '[:space:]')
ef_count=$(oc get envoyfilters -A --no-headers 2>/dev/null | wc -l)
ef_count=$(echo "$ef_count" | tr -d '[:space:]')
ap_count=$(oc get authorizationpolicy -A --no-headers 2>/dev/null | wc -l)
ap_count=$(echo "$ap_count" | tr -d '[:space:]')

pass "VirtualServices: $vs_count"
pass "DestinationRules: $dr_count"
pass "Gateways: $gw_count"
pass "EnvoyFilters: $ef_count"
pass "AuthorizationPolicies: $ap_count"

echo ""
info "VirtualServices:"
oc get vs -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | while read -r line; do info "  $line"; done

echo ""
info "DestinationRules:"
oc get dr -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host' 2>/dev/null | while read -r line; do info "  $line"; done

echo ""

# ─── 7. Data Plane — Proxy Status ─────────────────────────────────────────────

section "7. Data Plane — Proxy Status"

VERSION_OUTPUT=$(istioctl version --short 2>/dev/null || echo "unavailable")
info "Version output:"
echo "$VERSION_OUTPUT" | while read -r line; do info "  $line"; done

# Extract proxy count from data plane line
dp_line=$(echo "$VERSION_OUTPUT" | grep 'data plane' || echo "")
if echo "$dp_line" | grep -qoP '\(\d+ proxies\)' 2>/dev/null; then
  dp_proxy_count=$(echo "$dp_line" | grep -oP '\(\K\d+(?= proxies)' || echo "0")
  info "Data plane proxies reported: $dp_proxy_count"
fi

echo ""
info "Connected Proxies:"
PROXY_OUTPUT=$(istioctl proxy-status 2>/dev/null | grep -v 'CLUSTER' || echo "")
if [ -z "$PROXY_OUTPUT" ]; then
  warn "No proxies connected or istioctl proxy-status returned nothing"
else
  total_proxies=$(echo "$PROXY_OUTPUT" | wc -l)
  total_proxies=$(echo "$total_proxies" | tr -d '[:space:]')
  synced=$(echo "$PROXY_OUTPUT" | grep -c 'SYNCED' || true)
  not_synced=$((total_proxies - synced))
  pass "Total: $total_proxies, Synced: $synced, Not synced: $not_synced"

  if [ "$not_synced" -gt 0 ]; then
    warn "Unsynced proxies:"
    echo "$PROXY_OUTPUT" | grep -v 'SYNCED' | while read -r line; do info "  $line"; done
  fi

  # Check version mismatches — strip _ossm suffix from control plane version
  cp_ver=$(echo "$VERSION_OUTPUT" | grep 'control plane' | awk '{print $NF}' 2>/dev/null | sed 's/_ossm$//' || echo "")
  if [ -n "$cp_ver" ]; then
    mismatch_count=$(echo "$PROXY_OUTPUT" | awk '{print $NF}' | grep -cv "^${cp_ver}$" || true)
    if [ "$mismatch_count" -gt 0 ]; then
      warn "Version mismatch: $mismatch_count proxy(es) not matching control plane version $cp_ver"
    else
      pass "All proxies match control plane version $cp_ver"
    fi
  fi
fi

echo ""

# ─── 8. Namespace Injection ──────────────────────────────────────────────────

section "8. Namespace Injection Status"

OLD_INJECT_NS=$(oc get ns -l sidecar.istio.io/inject=true -o name 2>/dev/null || echo "")
if [ -n "$OLD_INJECT_NS" ]; then
  warn "Old-style sidecar injection labels:"
  echo "$OLD_INJECT_NS" | while read -r ns; do info "  $ns"; done
else
  pass "No old-style sidecar.istio.io/inject labels"
fi

IGNORE_NS=$(oc get ns -l maistra.io-ignore=true -o name 2>/dev/null || echo "")
if [ -n "$IGNORE_NS" ]; then
  warn "maistra.io-ignore namespaces (cleanup needed):"
  echo "$IGNORE_NS" | while read -r ns; do info "  $ns"; done
else
  pass "No maistra.io-ignore namespaces"
fi

echo ""
info "Namespaces with istio.io/rev label:"
REV_LABELS=$(oc get ns -l istio.io/rev -o custom-columns='NAME:.metadata.name,REV:.metadata.labels.istio\.io/rev' 2>/dev/null || echo "")
if [ -n "$REV_LABELS" ]; then
  echo "$REV_LABELS" | while read -r line; do info "  $line"; done
else
  info "  (none)"
fi

echo ""
info "Namespaces with service-mesh=enabled label:"
SM_NS=$(oc get ns -l service-mesh=enabled -o custom-columns='NAME:.metadata.name' 2>/dev/null || echo "")
if [ -n "$SM_NS" ]; then
  echo "$SM_NS" | while read -r line; do info "  $line"; done
else
  info "  (none)"
fi

echo ""

# ─── 9. Old OSSM2 Resource Cleanup ───────────────────────────────────────────

section "9. Old OSSM2 Resource Cleanup"

legacy_found=false
for crd in servicemeshcontrolplane servicemeshmemberroll servicemeshaccesslog servicemeshauthorizationpolicy servicemeshhealthcheck servicemeshprobe; do
  count=$(oc get "$crd" -A --no-headers 2>/dev/null | wc -l)
  count=$(echo "$count" | tr -d '[:space:]')
  if [ "$count" -gt 0 ] 2>/dev/null; then
    warn "Found $count $crd resource(s) (OSSM 2.x legacy)"
    legacy_found=true
  else
    pass "No $crd resources"
  fi
done

if [ "$legacy_found" = false ]; then
  pass "All legacy OSSM2 resources cleaned up"
fi

echo ""

# ─── 10. Cross-Mesh Connectivity ─────────────────────────────────────────────

if [ "$SKIP_CONNECTIVITY" = false ]; then
  section "10. Cross-Mesh Connectivity (route-mon.log)"

  ROUTE_LOG="/home/devops/Documents/mesh-demo/route-mon.log"
  if [ -f "$ROUTE_LOG" ]; then
    LAST_CHECK=$(grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' "$ROUTE_LOG" | tail -1 || echo "unknown")
    STATUS_LINE=$(grep 'Status:' "$ROUTE_LOG" | tail -1 || echo "unknown")
    pass "Last check: $LAST_CHECK"
    pass "Overall status: $STATUS_LINE"

    # Only count the last check block (after the last "Status:" line)
    last_status_line=$(grep -n 'Status:' "$ROUTE_LOG" | tail -1 | cut -d: -f1)
    if [ -n "$last_status_line" ]; then
      ok_count=$(tail -n +"$last_status_line" "$ROUTE_LOG" | grep -c '→.*OK' || true)
      fail_count=$(tail -n +"$last_status_line" "$ROUTE_LOG" | grep -c '→.*FAIL' || true)
    else
      ok_count=$(grep -c '→.*OK' "$ROUTE_LOG" || true)
      fail_count=$(grep -c '→.*FAIL' "$ROUTE_LOG" || true)
    fi
    ok_count=${ok_count:-0}
    fail_count=${fail_count:-0}
    pass "Cross-mesh checks — OK: $ok_count, Failed: $fail_count"

    if [ "$fail_count" -gt 0 ] 2>/dev/null; then
      warn "Recent failures:"
      grep '→.*FAIL' "$ROUTE_LOG" | tail -5 | while read -r line; do info "  $line"; done
    fi
  else
    warn "route-mon.log not found at $ROUTE_LOG"
    info "Skipping cross-mesh connectivity verification"
  fi

  echo ""
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

section "SUMMARY"

echo "  Cluster:   $CLUSTER_CONTEXT"
echo "  Checked:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

overall_pass=true
issues=()

# Check CR state
if [ -n "$ISTIO_NS" ] && [ -n "$ISTIO_NAME" ]; then
  st=$(oc get istio "$ISTIO_NAME" -n "$ISTIO_NS" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
  if [ "$st" != "Healthy" ]; then
    overall_pass=false
    issues+=("Istio CR $ISTIO_NS/$ISTIO_NAME state: $st")
  fi

  for pod in $(oc get pods -n "$ISTIO_NS" -l app=istiod -o name 2>/dev/null); do
    ps=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$ps" != "Running" ]; then
      overall_pass=false
      issues+=("Istiod ${pod#pod/} is $ps")
    fi
  done

  for pod in $(oc get pods -n "$ISTIO_NS" -l app=istio-ingressgateway -o name 2>/dev/null); do
    ps=$(oc get "$pod" -n "$ISTIO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$ps" != "Running" ]; then
      overall_pass=false
      issues+=("Ingress ${pod#pod/} is $ps")
    fi
  done
fi

# Check proxy sync
if [ -n "$PROXY_OUTPUT" ]; then
  not_synced=$(echo "$PROXY_OUTPUT" | grep -cv 'SYNCED' || true)
  if [ "$not_synced" -gt 0 ]; then
    overall_pass=false
    issues+=("$not_synced proxy(ies) not synced")
  fi
fi

echo "$SUBSEP"
if [ "$overall_pass" = true ]; then
  printf "${GREEN}OVERALL: ALL CHECKS PASSED${NC}\n"
else
  printf "${RED}OVERALL: ISSUES DETECTED${NC}\n"
  echo ""
  for issue in "${issues[@]}"; do
    fail "$issue"
  done
fi
echo "$SEP"
echo ""

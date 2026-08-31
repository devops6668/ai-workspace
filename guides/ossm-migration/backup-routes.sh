#!/bin/bash
# Detach Routes from SMCP ownership and backup clean copies
# 1. Remove maistra.io labels and ownerReferences from live Routes
# 2. Backup cleaned YAMLs
# Before disabling IOR — Section 4.7 of the migration guide
set -euo pipefail

BACKUP_DIR="/home/devops/Documents/ossm2_to_ossm3/route-backup"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAMESPACE="istio-system"

mkdir -p "${BACKUP_DIR}"

echo "=== Step 1: Detaching Routes from SMCP ownership (live cluster) ==="

# Get all route names
ROUTES=$(oc get routes -n "${NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name)

for name in ${ROUTES}; do
  echo "Processing route: ${name}"

  # Remove ALL maistra.io labels (wildcard removal)
  oc label route "${name}" -n "${NAMESPACE}" \
    $(oc get route "${name}" -n "${NAMESPACE}" -o json \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
labels = data['metadata'].get('labels', {})
for k in labels:
    if 'maistra.io' in k:
        print(f'{k}-')
" 2>/dev/null) \
    2>/dev/null || true

  # Remove maistra.io annotations
  ANNOTATIONS=$(oc get route "${name}" -n "${NAMESPACE}" -o json \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
anns = data['metadata'].get('annotations', {})
for k in anns:
    if 'maistra.io' in k:
        print(k)
" 2>/dev/null)
  for ann in ${ANNOTATIONS}; do
    oc annotate route "${name}" -n "${NAMESPACE}" "${ann}-" 2>/dev/null || true
  done

  # Remove ownerReferences
  oc patch route "${name}" -n "${NAMESPACE}" --type='json' \
    -p '[{"op": "remove", "path": "/metadata/ownerReferences"}]' \
    2>/dev/null || echo "   (no ownerReferences)"

  # Remove app.kubernetes.io/managed-by label
  oc label route "${name}" -n "${NAMESPACE}" app.kubernetes.io/managed-by- 2>/dev/null || true
done

echo ""
echo "=== Step 2: Backing up cleaned Routes ==="

echo "Exporting individual Route YAMLs..."
for name in ${ROUTES}; do
  oc get route "${name}" -n "${NAMESPACE}" -o yaml \
    > "${BACKUP_DIR}/route-${name}.yaml"
  echo "   -> route-${name}.yaml"
done

echo "Exporting full Routes YAML..."
oc get routes -n "${NAMESPACE}" -o yaml \
  > "${BACKUP_DIR}/routes-istio-system-${TIMESTAMP}.yaml"

echo "Exporting Route summary..."
oc get routes -n "${NAMESPACE}" -o custom-columns=\
'NAME:.metadata.name,HOST:.spec.host,SERVICE:.spec.to.name,PORT:.spec.port.targetPort,TLS:.spec.tls.termination' \
> "${BACKUP_DIR}/routes-summary-${TIMESTAMP}.txt"

TOTAL=$(echo "${ROUTES}" | wc -l)
echo ""
echo "=== Done: ${TOTAL} Routes detached and backed up ==="
echo "Backup directory: ${BACKUP_DIR}"
ls -la "${BACKUP_DIR}/"

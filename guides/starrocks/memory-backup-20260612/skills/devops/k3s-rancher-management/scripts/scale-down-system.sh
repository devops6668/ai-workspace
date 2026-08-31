#!/bin/bash
# Scale down all Deployments, StatefulSets in non-system namespaces
# Exclude: kube-*, kubernetes-*, cattle-*
# Usage: bash scale-down.sh
# Save as ~/.hermes/skills/devops/k3s-rancher-management/scripts/scale-down-system.sh

echo "=========================================="
echo "Scale DOWN Deployments & StatefulSets"
echo "Excluding: kube-*, kubernetes-*, cattle-* namespaces"
echo "=========================================="

ALL_NS=$(kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null | sort)

count=0
skipped=0

for ns in $ALL_NS; do
    # Skip system namespaces
    if [[ "$ns" == kube-* ]] || [[ "$ns" == kubernetes-* ]] || [[ "$ns" == cattle-* ]]; then
        echo "⊘ Skip: $ns"
        skipped=$((skipped + 1))
        continue
    fi

    echo "▸ $ns"

    # Scale Deployments to 0
    for dep in $(kubectl get deployments -n "$ns" --no-headers -o name 2>/dev/null); do
        kubectl scale "$dep" -n "$ns" --replicas=0 2>&1 | grep -q "scaled" && echo "  ↓ $dep" && count=$((count + 1))
    done

    # Scale StatefulSets to 0
    for st in $(kubectl get statefulsets -n "$ns" --no-headers -o name 2>/dev/null); do
        kubectl scale "$st" -n "$ns" --replicas=0 2>&1 | grep -q "scaled" && echo "  ↓ $st" && count=$((count + 1))
    done

    # DaemonSets cannot be scaled to 0 — just list them
    for ds in $(kubectl get daemonsets -n "$ns" --no-headers -o name 2>/dev/null); do
        echo "  ⊘ $ds (DaemonSet - cannot scale to 0)"
    done
done

echo ""
echo "=========================================="
echo "Done! Scaled down $count workloads (skipped $skipped namespaces)"
echo "=========================================="

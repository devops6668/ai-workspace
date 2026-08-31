---
name: acm-uninstall
description: Uninstall RHACM from OCP - steps, pitfalls, cleanup.
category: devops
triggers:
  - ACM uninstall
  - RHACM uninstall
  - Advanced Cluster Management removal
  - MCE cleanup
  - open-cluster-management cleanup
---

# RHACM Uninstall Guide

Uninstall Red Hat Advanced Cluster Management (RHACM) from OpenShift Container Platform.

## Official Steps (Red Hat ACM 2.17 docs)

### Prerequisites

Before uninstalling, clean up these resources:

```bash
# 1. Detach all managed clusters (except local-cluster)
oc get managedclusters
oc delete managedcluster <cluster-name>

# 2. Disable Discovery
oc delete discoveryconfigs --all --all-namespaces

# 3. Delete AgentServiceConfig
oc delete agentserviceconfig --all

# 4. Delete MultiClusterObservability
oc delete mco observability
```

### Step 1: Delete MultiClusterHub CR (DO THIS FIRST)

```bash
oc project open-cluster-management
oc delete multiclusterhub --all

# Monitor progress - wait for this to complete
oc get mch -o yaml
```

**CRITICAL**: Delete the MCH CR FIRST. This triggers cascading cleanup. Skipping this causes manual cleanup headaches.

### Step 2: Uninstall Operator

```bash
# Find and delete CSV
oc get csv -n open-cluster-management
oc delete clusterserviceversion <acm-csv-name> -n open-cluster-management

# Find and delete Subscription
oc get sub -n open-cluster-management
oc delete subscription <acm-sub-name> -n open-cluster-management
```

### Step 3: Delete Namespaces

```bash
oc delete namespace open-cluster-management --ignore-not-found
oc delete namespace open-cluster-management-agent --ignore-not-found
oc delete namespace open-cluster-management-agent-addon --ignore-not-found
oc delete namespace open-cluster-management-hub --ignore-not-found
oc delete namespace open-cluster-management-policies --ignore-not-found
oc delete namespace open-cluster-management-global-set --ignore-not-found
oc delete namespace open-cluster-management-observability --ignore-not-found
```

### Step 4: Delete MCE (Multicluster Engine)

```bash
# Delete MCE CSV
oc get csv -n multicluster-engine
oc delete clusterserviceversion <mce-csv-name> -n multicluster-engine

# Delete MCE OperatorGroup
oc delete operatorgroup -n multicluster-engine default

# Delete MCE namespace
oc delete namespace multicluster-engine
```

### Step 5: Clean up CRDs

```bash
oc get crd | grep -iE "open-cluster|acm" | awk '{print $1}' | xargs -I{} oc delete crd {} --ignore-not-found
```

### Step 6: Clean up RBAC

```bash
oc get clusterrole | grep -iE "open-cluster|acm" | awk '{print $1}' | xargs -I{} oc delete clusterrole {} --ignore-not-found
oc get clusterrolebinding | grep -iE "open-cluster|acm" | awk '{print $1}' | xargs -I{} oc delete clusterrolebinding {} --ignore-not-found
```

### Step 7: Clean up Aggregated APIs

```bash
oc get apiservice | grep -iE "open-cluster" | awk '{print $1}' | xargs -I{} oc delete apiservice {} --ignore-not-found
```

### Step 8: Clean up Webhooks

```bash
oc get validatingwebhookconfiguration | grep -iE "open-cluster|acm|multicluster" | xargs -I{} oc delete validatingwebhookconfiguration {} --ignore-not-found
oc get mutatingwebhookconfiguration | grep -iE "open-cluster|acm|multicluster" | xargs -I{} oc delete mutatingwebhookconfiguration {} --ignore-not-found
```

### Step 9: Clean up Console Plugins

```bash
oc get consoleplugins | grep -iE "mce|acm|multicluster" | xargs -I{} oc delete consoleplugin {} --ignore-not-found
```

### Step 10: Clean up Operator Groups

```bash
oc delete operatorgroup -n open-cluster-management --all --ignore-not-found
```

## Verification

```bash
# Check nothing remains
oc get namespace | grep -iE "open-cluster|multicluster"
oc get crd | grep -iE "open-cluster|acm"
oc get csv -A | grep -iE "open-cluster|acm|multicluster"
oc get apiservice | grep -iE "open-cluster"
oc get consoleplugins | grep -iE "mce|acm|multicluster"
```

## Known Pitfalls

### 1. quay.redhat.com/quayintegrations Finalizer

**Problem**: Namespaces stuck in Terminating due to `quay.redhat.com/quayintegrations` finalizer injected by Quay Bridge Operator.

**Symptoms**:
- Namespace shows Terminating but never deletes
- No pods inside, but deletion hangs

**Fix**:
```bash
# Check for finalizer
oc get namespace <ns> -o jsonpath='{.metadata.finalizers}'

# Delete the mutating webhook that adds it
oc get mutatingwebhookconfiguration | grep quay
oc delete mutatingwebhookconfiguration quayintegration.quay.redhat.com-xxxxx

# Remove finalizer
oc patch namespace <ns> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

### 2. ValidatingWebhook Blocking Deletion

**Problem**: Resources can't be deleted because webhook points to a deleted service.

**Symptoms**:
- `Error from server (InternalError): failed calling webhook`
- Service not found errors

**Fix**:
```bash
# Find and delete the webhook
oc get validatingwebhookconfiguration | grep -iE "multicluster|acm"
oc delete validatingwebhookconfiguration <webhook-name>
```

### 3. Console Warning: MCE Version Mismatch

**Problem**: After ACM uninstall, console shows "ACM in unexpected configuration: MCE X.X.X is ahead..."

**Fix**:
```bash
# Delete the stale MCE console plugin
oc delete consoleplugin mce

# Delete the MulticlusterEngine CR (may need to remove finalizer first)
oc get multiclusterengine -o jsonpath='{.metadata.finalizers}'
oc patch multiclusterengine <name> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete multiclusterengine <name>
```

### 4. KubeAggregatedAPIDown Alert

**Problem**: Alert fires for aggregated API pointing to deleted service.

**Fix**:
```bash
oc get apiservice | grep -iE "open-cluster"
# Delete any with False (ServiceNotFound) status
oc delete apiservice <api-service-name>
```

### 5. Stuck Namespaces (Force Delete)

**Problem**: Namespaces stuck in Terminating even after removing finalizers.

**Fix** (use with caution):
```bash
# Force delete (immediate, no grace period)
oc delete namespace <ns> --force --grace-period=0

# Or patch to remove finalizers first
oc patch namespace <ns> -p '{"metadata":{"finalizers":null}}' --type=merge
```

### 6. MCH CR Stuck in "Uninstalling"

**Problem**: MCH CR stuck in "Uninstalling" state with no operator running to clean it up.

**Symptoms**:
- `oc get multiclusterhub` shows STATUS: Uninstalling
- No ACM pods or deployments running

**Fix**:
```bash
# Remove finalizer first
oc get multiclusterhub <name> -n open-cluster-management -o jsonpath='{.metadata.finalizers}'
oc patch multiclusterhub <name> -n open-cluster-management --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'

# Then delete
oc delete multiclusterhub <name> -n open-cluster-management
```

### 7. Remaining MCE CRDs

**Problem**: After ACM uninstall, MCE CRDs still present:
- `internalenginecomponents.multicluster.openshift.io`
- `multiclusterengines.multicluster.openshift.io`
- `multiclusterhubs.operator.open-cluster-management.io`

**Fix**:
```bash
oc delete crd internalenginecomponents.multicluster.openshift.io --ignore-not-found
oc delete crd multiclusterengines.multicluster.openshift.io --ignore-not-found
oc delete crd multiclusterhubs.operator.open-cluster-management.io --ignore-not-found
```

### 8. Remaining Aggregated API

**Problem**: `v1.operator.open-cluster-management.io` still present after cleanup.

**Fix**:
```bash
oc delete apiservice v1.operator.open-cluster-management.io --ignore-not-found
```

## OCP 4.20 + ACM Version Compatibility

| ACM Version | MCE Version | OCP Support |
|------------|-------------|-------------|
| ACM 2.17   | MCE 2.17    | OCP 4.20, 4.21, 4.22 |
| ACM 2.16   | MCE 2.11    | OCP 4.19, 4.20, 4.21 |
| ACM 2.15   | MCE 2.10    | OCP 4.18, 4.19, 4.20 |

**Minimum ACM version for OCP 4.20**: ACM 2.15

## Known Issues

### ACM 2.17 Console Warning (Cosmetic)

```
WARNING: ACM in unexpected configuration: MCE 2.17.2 is ahead of the expected stable-2.11 channel.
```

**Root cause**: ACM 2.17.1 bundles MCE 2.17.x but the console check expects stable-2.11 channel. This is a bug in the ACM console validation logic. The warning is cosmetic and does not affect functionality.

**Solution**: Ignore the warning, or use ACM 2.16 + MCE 2.11 instead.

### ACM 2.16 CRD Chicken-and-Egg Problem

**Symptom**: After fresh install, ACM 2.16 CSV shows Succeeded but addon CRDs are not created:
- `managedclusteraddons.addon.open-cluster-management.io`
- `clustermanagementaddons.addon.open-cluster-management.io`
- `addondeploymentconfigs.addon.open-cluster-management.io`
- `managedclusters.cluster.open-cluster-management.io`
- `manifestworks.work.open-cluster-management.io`

**Root cause**: Old CRDs from previous installation corrupt the CRD state. The new CSV thinks CRDs exist but they don't.

**Solution**: Complete uninstall (remove all CRDs, wait 10-15 minutes), then fresh install.

### ClusterManager CR Finalizer

**Symptom**: CRD deletion stuck because of `customresourcecleanup.apiextensions.k8s.io` finalizer.

**Fix**:
```bash
oc get clustermanager -A
oc patch clustermanager <name> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete clustermanager <name>
```

### ManagedClusterSet Finalizer

**Symptom**: ManagedClusterSet stuck in Terminating.

**Fix**:
```bash
oc get managedclusterset
oc patch managedclusterset <name> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete managedclusterset <name>
```

## Key Learnings

1. **Always delete MCH CR first** - triggers cascading cleanup
2. **Delete managed clusters before uninstalling** - prevents orphaned resources
3. **Check for quay finalizer** - common blocker on namespaces (repeatedly re-added by quay webhook)
4. **Check for stale webhooks** - can block resource deletion
5. **CRD deletion is slow** - may take minutes with large clusters
6. **API throttling** - cluster may be slow during cleanup due to many API calls
7. **MCH CR has finalizer** - must remove `finalizer.operator.open-cluster-management.io` before deletion
8. **Check for MCE CRDs** - `internalenginecomponents`, `multiclusterengines`, `multiclusterhubs` may remain
9. **Check aggregated APIs** - `v1.operator.open-cluster-management.io` may remain as Local API
10. **quay webhook keeps recreating** - delete `quayintegration.quay.redhat.com-*` mutatingwebhookconfiguration before namespace cleanup
11. **ACM manages MCE subscription** - cannot change MCE channel while MCH exists; must delete MCH first
12. **Complete uninstall requires CRD cleanup** - including ClusterManager and ManagedClusterSet CRs with their finalizers

## References

- [Red Hat ACM 2.17 Uninstall Docs](https://docs.redhat.com/zh-cn/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/install/uninstalling)
- [Cleanup Artifacts Before Reinstallation](https://docs.redhat.com/zh-cn/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/install/uninstalling#cleanup-artifacts-before-reinstallation)

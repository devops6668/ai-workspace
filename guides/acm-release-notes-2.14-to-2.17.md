# Red Hat Advanced Cluster Management (RHACM) Release Notes — ACM 2.14 to 2.17

> **Document Date:** September 2025
> **Source:** [Red Hat ACM Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes)
> **Scope:** New features, fixed issues, known issues, deprecations, and removals for ACM 2.14 through 2.17

---

## Table of Contents

- [Version Compatibility Matrix](#version-compatibility-matrix)
- [ACM 2.14 (MCE 2.9)](#acm-214-mce-29)
  - [New Features](#acm-214-new-features)
  - [Fixed Issues](#acm-214-fixed-issues)
  - [Known Issues](#acm-214-known-issues)
  - [Deprecations and Removals](#acm-214-deprecations-and-removals)
- [ACM 2.15 (MCE 2.10)](#acm-215-mce-210)
  - [New Features](#acm-215-new-features)
  - [Fixed Issues](#acm-215-fixed-issues)
  - [Known Issues](#acm-215-known-issues)
  - [Deprecations and Removals](#acm-215-deprecations-and-removals)
- [ACM 2.16 (MCE 2.11)](#acm-216-mce-211)
  - [New Features](#acm-216-new-features)
  - [Fixed Issues](#acm-216-fixed-issues)
  - [Known Issues](#acm-216-known-issues)
  - [Deprecations and Removals](#acm-216-deprecations-and-removals)
- [ACM 2.17 (MCE 2.12)](#acm-217-mce-212)
  - [New Features](#acm-217-new-features)
  - [Fixed Issues](#acm-217-fixed-issues)
  - [Known Issues](#acm-217-known-issues)
  - [Deprecations and Removals](#acm-217-deprecations-and-removals)
- [Upgrade Considerations](#upgrade-considerations)
  - [MCE Version Progression](#mce-version-progression)
  - [OCP Compatibility](#ocp-compatibility)
  - [Critical Upgrade Notes](#critical-upgrade-notes)
  - [Subscription App Deprecation Timeline](#subscription-app-deprecation-timeline)
  - [Known Data Loss Risk](#known-data-loss-risk)

---

## Version Compatibility Matrix

| ACM Version | MCE Version | OCP Support Range |
|-------------|-------------|-------------------|
| ACM 2.14   | MCE 2.9     | OCP 4.16, 4.17, 4.18 |
| ACM 2.15   | MCE 2.10    | OCP 4.18, 4.19, 4.20 |
| ACM 2.16   | MCE 2.11    | OCP 4.19, 4.20, 4.21 |
| ACM 2.17   | MCE 2.12    | OCP 4.20, 4.21, 4.22 |

> **Note:** Always check the [Red Hat Advanced Cluster Management Support Matrix](https://access.redhat.com/articles/7120842) for the most current compatibility information.

---

## ACM 2.14 (MCE 2.9)

### ACM 2.14 New Features

#### General
- **AWS Marketplace**: ACM is now available on the [AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-s2nb6rqz2i3ru) with on-demand or annual pricing for ROSA (classic) clusters.

#### Installation
- Support for non-`local-cluster` hub cluster names via `disableHubSelfManagement` setting.

#### Clusters
- **ClusterInstance** enhancements for Zero Touch Provisioning (ZTP) workflow.

#### Applications
- **ClusterPermission** for fine-grained RBAC per application per cluster.
- **ClusterRole** integration with ClusterPermission.
- **ApplicationSet** improvements for GitOps-based deployment.

#### Observability
- `mco-disable-uwl-alerting` option to disable user workload alerting.

#### Governance
- `.Object`, `.ObjectName`, `.ObjectNamespace` template variables in `ConfigurationPolicy`.
- `fromYaml`/`toYaml` functions for `ConfigurationPolicy`.
- `dryrun` mode for `ConfigurationPolicy`.
- `policytools` for `ConfigurationPolicy`.
- `versions` field for `OperatorPolicy`.

#### Business Continuity
- `namespaceMapping` for backup/restore.
- `startingCSV` for VolSync.
- **VolSync** persistent volume replication service (async PV replication within a cluster).

#### Multicluster Global Hub
- **AMQ Strimzi** messaging improvements.

### ACM 2.14 Fixed Issues

#### Errata 2.14.1
- `annotation.repository` issues resolved.
- Pull-integration-controller `Refreshing` state fixes.
- `certificate-policy-controller` fixes.
- `namespaceSelector`/`objectSelector` handling fixes.
- `metric-collector`/`nmstatectl` issues resolved.

#### Errata 2.14.2
- `CrashLoopBackOff` in `console-mce-console` fixed.
- `ClusterInstance` "detected unauthorized changes in immutable fields" resolved.
- `ImageClusterInstall` `AdditionalNTPSources` fix.
- `multicluster-observability-addon` missing fix.
- `ClusterInstance` "Provisioning in progress" fix.

### ACM 2.14 Known Issues

#### Installation
- **Uninstall/reinstall with upgrade can fail**: If CRs are not removed when uninstalling ACM, reinstalling an earlier version and upgrading may fail. Follow [Cleaning up artifacts before reinstalling](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.14/html/install/cleanup-reinstall) procedure.
- **Data image resources stuck after cluster reinstallation** with Image-Based Break/Fix when `bmcAddress` is changed.

#### Business Continuity
- **Bare metal hub resources no longer backed up** by managed clusters backup (affects ZTP-deployed `BareMetalHost` resources).
- **Velero restore limitations**: New hub with pre-existing resources can have different configuration.
- **Passive configurations** don't display managed clusters until activation data is restored.
- **`local-cluster` managed cluster resource** not properly restored (must manually reconfigure).
- **Restored Hive managed clusters** may not connect to new hub (rotated CA kubeconfig invalid).
- **Imported managed clusters** show `Pending Import` status after restore.

#### Console
- **klusterlet-addon-search pod fails** (memory limit OOM). Fix: annotate `search-collector` addon.
- **Search PostgreSQL CrashLoopBackOff** on nodes with `hugepages` enabled.
- **Cannot upgrade OpenShift Dedicated** in console (error: `Cannot upgrade non openshift cluster`).
- **Cannot edit namespace bindings** for cluster set with `admin` or `bind` roles.

#### Observability
- **Retention change causes data loss**: Default 1h resolution retention changed from indefinite (`0d`) to 365d.
- **Observatorium API gateway stale tenant data** after backup/restore.
- **No proxy support** for Prometheus `AdditionalAlertManagerConfig`.

#### Governance
- **ConfigurationPolicy incorrectly processes** `objectSelector` and `namespaceSelector` results.
- **Config policy listed compliant** when namespace stuck in Terminating state.
- **ConfigurationPolicy CRD stuck in terminating** after add-on removal.

### ACM 2.14 Deprecations and Removals

#### Deprecated (still supported but not recommended)

| Item | Since | Recommended Action |
|------|-------|--------------------|
| ACM API documentation | 2.13 | View APIs from console/terminal instead |
| **Subscription** (application mgmt) | 2.13 | Use OpenShift GitOps instead (extended for 5 releases) |
| **PlacementRule** | 2.8 | Use `Placement` instead |
| PostgreSQL manual upgrade (global hub) | 2.14 | Use automatic upgrades (global hub v1.5+) |

#### Removed

| Item | Removed In | Replacement |
|------|-----------|-------------|
| VM actions in Search (Technology Preview) | 2.14 | Fine-grained RBAC |
| OCP 3.11 cluster import from console | 2.14 | Upgrade to supported OCP |
| Old Overview page layout | 2.13 | Enable Fleet view switch |
| `ingress.sslCiphers` field | 2.9 | See Advanced Configuration docs |
| Policy compliance history API | 2.13 | Use policy metrics / pod logs |
| Edge manager | 2.13 | Red Hat Edge Manager 1.0 |

---

## ACM 2.15 (MCE 2.10)

### ACM 2.15 New Features

#### General
- **CNCF conformance certified provider support**: ACM supports all providers certified through the CNCF Kubernetes Conformance Program.

#### Installation
- Support for non-`local-cluster` hub names continued.
- CNCF provider documentation and support paths.

#### Clusters
- **ClusterInstance** improvements for ZTP.
- **Agent-based installer** enhancements.
- **Managed cluster migration** between cluster sets by name or by `Placement` resource, with migration status tracking.

#### Applications
- Subscription deprecation continues (migrate to GitOps).
- GitOps-based application management improvements.

#### Observability
- `MultiClusterObservability` improvements.
- Metrics collector enhancements.

#### Governance
- `ConfigurationPolicy` continued improvements.
- `OperatorPolicy` enhancements.

#### Business Continuity
- Backup/restore continued improvements.
- VolSync continued enhancements.

### ACM 2.15 Fixed Issues

- Multiple errata releases addressing stability.
- Console integration fixes.
- Cluster management stability improvements.

### ACM 2.15 Known Issues

- Same as 2.14 plus:
- **ManagedClusterMigration resources** need deletion before multicluster global hub upgrade.

### ACM 2.15 Deprecations and Removals

#### Deprecated
- Subscription app management (continued).
- PlacementRule (continued).
- ACM API documentation (continued).

#### Removed (new in 2.15)
| Item | Removed In | Replacement |
|------|-----------|-------------|
| `edge-manager-preview` in MCH | 2.15 | Red Hat Edge Manager 1.0 |
| Infrastructure > Virtual machines console page | 2.15 | OpenShift Virtualization 4.20 + Fleet Virtualization perspective, or Search |
| Global hub ConfigMap/Secret migration requirement | 2.15 | Must now migrate managed clusters directly |

---

## ACM 2.16 (MCE 2.11)

### ACM 2.16 New Features

#### Console
- **ManagedClusterInfo pagination**: `limit`, `offset`, `orderBy` support.
- New alert: `SearchPVCNotPresentCritical`.

#### Observability
- **RightSizingRecommendation** CRD support.
- **AddonDeploymentConfig** enhancements.
- **Thanos compact scaling** (4 replicas).
- `PUT`/`DELETE` operations support.
- **Metrics allowlist migration** (`allowlist-migration`, `observability-metrics-allowlist`).
- `ScrapeConfig` and `PrometheusRule` resource support.
- `multicluster-observability-addon` improvements.

#### Virtualization
- **MultiClusterRoleAssignment** support.
- **HyperConverged** integration.

### ACM 2.16 Fixed Issues

#### Errata 2.16.2
- `kube-rbac-proxy`/`nodeExporterHostPort` fixes.
- `AddonDeploymentConfig` fixes ([ACM-30490](https://issues.redhat.com/browse/ACM-30490)).

#### Errata 2.16.1 (Deprecated)
- Various stability fixes ([ACM-32930](https://redhat.atlassian.net/browse/ACM-32930)).

### ACM 2.16 Known Issues

#### Installation
- **CRD chicken-and-egg problem on fresh install**: ACM 2.16 CSV shows Succeeded but addon CRDs are not created. Fix: complete uninstall (remove all CRDs, wait 10-15 minutes), then fresh install.
- **Role Assignments page fails after 2.15 → 2.16 upgrade**: `MulticlusterRoleAssignment` CRD change requires `clusterSelection.placements` field. Fix: `oc delete multiclusterroleassignment --all` then recreate. ([ACM-33106](https://issues.redhat.com/browse/ACM-33106))
- **kubevirt-hyperconverged add-on stuck** during 2.15 → 2.16 upgrade. Fix: delete and recreate `ClusterManagementAddOn` as `v1beta1`. ([ACM-31036](https://issues.redhat.com/browse/ACM-31036))

#### Observability
- **Manual alert forwarding fails after 2.15+ upgrade** (secret name changes). ([ACM-26604](https://issues.redhat.com/browse/ACM-26604))

#### Networking
- **Submariner installation on IBM Power Systems fails**. ([ACM-27270](https://issues.redhat.com/browse/ACM-27270))

### ACM 2.16 Deprecations and Removals

#### Deprecated
- Subscription app management (continued).
- PlacementRule (continued).
- ACM API documentation (continued).

#### Removed (new in 2.16)
| Item | Removed In | Replacement |
|------|-----------|-------------|
| `backup-restore-auto-import` policy | 2.16 | Use `backup-restore-enabled` policy |

---

## ACM 2.17 (MCE 2.12)

### ACM 2.17 New Features

#### General
- **Red Hat OpenShift Lightspeed integration**: The `Attach` feature adds `ManagedCluster`/`ManagedClusterInfo` YAML as context to the Lightspeed AI assistant from cluster detail pages.

#### Clusters
- **Label propagation for hosted clusters**: User-defined labels on `HostedCluster` CRs on MCE clusters are automatically applied to corresponding `ManagedCluster` resources across ACM and MCE hub clusters. Labels added to `ManagedCluster` on ACM hub sync to MCE clusters.

#### Applications
- **Technology Preview**: Argo CD agent with **destination-based mapping** for `ApplicationSet` deployment, reducing prerequisite configuration needs.

#### Observability
- **Technology Preview**: **Perses dashboards** viewable in OCP console alongside Grafana dashboards. Enabled via the `ui` parameter in the `MultiClusterObservability` CR. Rendered through the Cluster Observability Operator console plugin.

#### Governance
- The `spec.complianceConfig` **operator policy** can now detect if a minor version upgrade is available for operators on different channels.

#### Virtualization
- **Custom `ClusterRole` resources** for virtualization workloads: define environment-specific permissions, distribute via governance policies, and assign users through `MulticlusterRoleAssignment` resources (e.g., console-only VM access without lifecycle control).

### ACM 2.17 Fixed Issues

- **No errata published yet** for ACM 2.17 as of document date.

### ACM 2.17 Known Issues

#### Installation
- **kubevirt-hyperconverged add-on stuck** during 2.16 → 2.17 upgrade (`operatorpolicies` RBAC error). ([ACM-31036](https://issues.redhat.com/browse/ACM-31036))
- **Console warning (cosmetic)**: "MCE 2.12.x is ahead of the expected stable-2.11 channel". This is a bug in the ACM console validation logic. The warning is cosmetic and does not affect functionality.

#### Business Continuity
- Same backup/restore known issues carried from previous versions (Velero restore limitations, `local-cluster` not restored, Hive CA rotation, `Pending Import` status).

#### Console
- Same console known issues carried from previous versions (klusterlet-addon-search OOM, Search PostgreSQL hugepages, OpenShift Dedicated upgrade).

### ACM 2.17 Deprecations and Removals

#### Deprecated
- Subscription app management (continued — deprecated since 2.13, extended for 5 releases before removal).
- PlacementRule (continued — deprecated since 2.8).
- ACM API documentation (continued — deprecated since 2.13).

#### Removed
No new removals in ACM 2.17 beyond what was already removed in 2.14-2.16.

---

## Upgrade Considerations

### MCE Version Progression

```
ACM 2.14  →  MCE 2.9
ACM 2.15  →  MCE 2.10
ACM 2.16  →  MCE 2.11
ACM 2.17  →  MCE 2.12
```

The MCE version follows a linear +1 progression across these four releases.

### OCP Compatibility

| Minimum OCP Version | Minimum ACM Version |
|---------------------|---------------------|
| OCP 4.18            | ACM 2.14            |
| OCP 4.20            | ACM 2.15            |
| OCP 4.21            | ACM 2.16            |
| OCP 4.22            | ACM 2.17            |

### Critical Upgrade Notes

> **WARNING:** Always plan upgrades carefully and test in non-production first.

1. **ACM manages MCE subscription**: You cannot change the MCE channel while the MultiClusterHub (MCH) exists. Must delete MCH first to change MCE channel.

2. **2.15 → 2.16**: `MulticlusterRoleAssignment` CRD changed — requires `clusterSelection.placements` field. Delete existing resources before upgrading:
   ```bash
   oc delete multiclusterroleassignment --all
   ```

3. **2.16 → 2.17**: `kubevirt-hyperconverged` add-on may get stuck. Fix:
   ```bash
   # Get the ClusterManagementAddOn
   oc get clustermanagementaddon kubevirt-hyperconverged -o jsonpath='{.metadata.labels.installer\.namespace}'
   # Delete the v1alpha1 version
   oc delete clustermanagementaddon kubevirt-hyperconverged
   # Recreate as v1beta1
   ```

4. **Always remove CRs before uninstall/reinstall**: Follow the [Cleaning up artifacts before reinstalling](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/install/cleanup-reinstall) procedure.

5. **MCH CR has finalizer**: Must remove `finalizer.operator.open-cluster-management.io` before deletion if MCH is stuck:
   ```bash
   oc patch multiclusterhub <name> -n open-cluster-management \
     --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
   ```

### Subscription App Deprecation Timeline

| Version | Status |
|---------|--------|
| ACM 2.13 | Subscription deprecated |
| ACM 2.14-2.18 | Extended deprecation period (5 releases) |
| Future | Removal — use OpenShift GitOps |

**Recommendation**: Start migrating to OpenShift GitOps + Argo CD pull model.

### Known Data Loss Risk

> **WARNING:** Default retention for 1h resolution changed from indefinite (`0d`) to 365d.

If you did not set an explicit value for `retentionResolution1h` in your `MultiClusterObservability` `spec.advanced.retentionConfig`, you may lose historical data beyond 365 days.

**Fix**: Set explicit retention values:
```yaml
apiVersion: observability.open-cluster-management.io/v1
kind: MultiClusterObservability
spec:
  advanced:
    retentionConfig:
      retentionResolutionRaw: 365d
      retentionResolution5m: 365d
      retentionResolution1h: 0d  # indefinite, or set as needed
```

---

## References

- [ACM 2.14 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.14/html/release_notes/acm-release-notes)
- [ACM 2.15 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/release_notes/acm-release-notes)
- [ACM 2.16 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/release_notes/acm-release-notes)
- [ACM 2.17 Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/release_notes/acm-release-notes)
- [Red Hat ACM Support Matrix](https://access.redhat.com/articles/7120842)
- [MCE Release Notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/clusters)

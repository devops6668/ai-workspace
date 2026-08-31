Homelab .local domains need CoreDNS NodeHosts entries (coredns ConfigMap, NodeHosts key). kubectl patch cm -n kube-system coredns to add entries like nexus/rancher/apm.paulhome.local. K3s at 192.168.48.111, node k3s-luban.
§
Paul Wong. Prefers Traditional Chinese / English. fcitx5 + Cangjie. Ubuntu. Homelab: k3s-luban (192.168.48.111), k3s disabled at boot, Cilium, ECK/Elastic APM, Rancher, ArgoCD, Harbor, Keycloak, OpenLDAP, Luban CI. Prefers NodePort+direct IP, external gateway (apm.luban.paulhome.local)+Luban CA cert. Values verified results. Prefers practical workarounds. Follows docs strictly. Hermes: --port 9119 --host 0.0.0.0 --insecure --no-open --tui.
§
User's luban-ci project uses luban-project-setup-template (Argo WorkflowTemplate) for project provisioning with 5 steps: git-project-setup, harbor-project-setup, ci-infra-provision, argocd-project (×2 envs), namespace-provision (×2 envs). Resources created: Source/GitOps repos, Harbor project, ci-infra RBAC/SA, AppProjects, namespaces with Cilium policies.
§
Dagster 1.12.19: zero OTel spans (metrics-exporter only, 10 gauges). Code locations do NOT add OTel SDK per Luban CI docs. Kibana index-pattern API returns 0 fields; must refresh in UI.
§
MinIO Operator: Helm lacks CRDs — use kustomize "github.com/minio/operator?ref=v7.1.1". Paul uses cert-manager+Nginx Ingress+Envoy Gateway for TLS/access.
# Kubewarden 學習指南

## 目錄

- [1. Kubewarden 係乜](#1-kubewarden-係乜)
- [2. 解決嘅問題](#2-解決嘅問題)
- [3. 架構](#3-架構)
- [4. 安裝](#4-安裝)
- [5. 基本概念](#5-基本概念)
- [6. 實際例子](#6-實際例子)
- [7. 現成 Policy 清單](#7-現成-policy-清單)
- [8. 自己寫 Policy](#8-自己寫-policy)
- [9. 管理工具](#9-管理工具)
- [10. 同其他方案比較](#10-同其他方案比較)
- [11. 參考資源](#11-參考資源)
- [12. GitOps 部署](#12-gitops-部署)

---

## 1. Kubewarden 係乜

Kubewarden 係一個 **Kubernetes admission controller 框架**，用嚟喺集群入面執行安全同合規 policy。

核心理念：
- Policy 用 **WebAssembly (Wasm)** 編寫，跑喺隔離沙箱入面
- 可以用 Rust、Go、CEL、Rego 等語言寫 policy
- 已經有 40+ 現成 policy 可以直接用，唔使自己寫 code
- Policy 可以 push 到 OCI registry，用法同 Docker image 一樣

官方文檔：https://docs.kubewarden.io/

---

## 2. 解決嘅問題

### 2.1 冇人管得住 K8s 集群安全

Kubernetes 本身冇內建機制去阻止：
- 部署特權容器（可以取到宿主機 root）
- 用不明來源嘅 image
- 唔 set resource limits（一個 pod 可以食晒所有 CPU/RAM）
- 掛載 `/etc`、`/var/run` 出嚟

冇 policy engine 嘅話，靠人手 review、靠 CI check，但 dev 總有方法繞過。

### 2.2 現有方案學習曲線太陡

之前嘅替代方案（OPA Gatekeeper）有問題：
- OPA 要學 Rego language，唔係一般 developer 懂嘅
- 寫簡單 policy 就算，寫複雜啲就卡住
- 企業要搵人專門負責寫 policy，變成瓶頸

Kubewarden 嘅做法：可以用 **Rust、Go、CEL、Rego** 寫 policy，唔使學新語言。

### 2.3 Policy 要安全隔離

一個 policy 出咗 bug 會點？
- 如果 policy server 同其他嘢一齊跑，有機會影響整個集群
- Policy 本身可能有漏洞

Kubewarden 用 **WebAssembly 沙箱**，每個 policy 跑喺獨立隔離環境，就算 policy 有問題都唔會影響其他 policy 或者宿主機。

### 2.4 Policy 要可分發、可版本控制

- Policy 本身係 Wasm module，可以 push 到 OCI registry（同 Docker image 一樣）
- 同一個 policy 可以用唔同 configuration 部署多次
- 版本更新可以用 Helm / GitOps 管理

### 一句話總結

> 喺 Kubernetes 集群入面，強制執行「邊個可以做咩」嘅規則，而且唔使學新語言、唔使担心隔離安全、唔使自己從頭造輪子。

---

## 3. 架構

```
Kubernetes API Server
        ↓ (admission webhook)
   PolicyServer (跑喺 kubewarden namespace)
        ↓
   Policy (Wasm module，隔離沙箱)
        ↓
   ACCEPT / DENY
```

主要組件：

| 組件 | 功能 |
|------|------|
| **PolicyServer** | 跑 policy 嘅 server，可以有多個 |
| **ClusterAdmissionPolicy** | Cluster-wide 嘅規則 |
| **AdmissionPolicy** | 指定 namespace 嘅規則 |
| **kubewarden-controller** | 管理 PolicyServer 同 Policy 嘅 lifecycle |
| **kwctl** | CLI 工具，用嚟管理同測試 policy |

自 1.36 版本開始，Kubewarden 分咗兩個組件：
1. **Kubewarden Admission Controller** — 核心，執行 policy
2. **SBOMScanner** — 掃描 SBOM（Software Bill of Materials）

---

## 4. 安裝

### 4.1 Helm 安裝

```bash
# 加 repo
helm repo add kubewarden https://charts.kubewarden.io
helm repo update kubewarden

# 1. 安裝 CRDs
helm install --wait -n kubewarden --create-namespace \
  kubewarden-crds kubewarden/kubewarden-crds

# 2. 安裝 Controller
helm install --wait -n kubewarden \
  kubewarden-controller kubewarden/kubewarden-controller

# 3. 安裝 Default PolicyServer
helm install --wait -n kubewarden \
  kubewarden-defaults kubewarden/kubewarden-defaults
```

裝完之後自動會有一個 `default` PolicyServer 喺 `kubewarden` namespace 入面跑。

### 4.2 安裝 kwctl CLI

```bash
# Linux
curl -sSfL https://github.com/kubewarden/kwctl/releases/latest/download/kwctl-linux-amd64 -o kwctl
chmod +x kwctl && mv kwctl /usr/local/bin/

# macOS
curl -sSfL https://github.com/kubewarden/kwctl/releases/latest/download/kwctl-macos-amd64 -o kwctl
chmod +x kwctl && mv kwctl /usr/local/bin/
```

### 4.3 卸載

```bash
helm uninstall --namespace kubewarden kubewarden-defaults
helm uninstall --namespace kubewarden kubewarden-controller
helm uninstall --namespace kubewarden kubewarden-crds
kubectl delete namespace kubewarden
```

---

## 5. 基本概念

### 5.1 PolicyServer

PolicyServer 係跑 policy 嘅 server，由 kubewarden-controller 管理。可以有多個 PolicyServer，例如一個畀 production 用、一個畀 staging 用。

```yaml
apiVersion: policies.kubewarden.io/v1
kind: PolicyServer
metadata:
  name: production
spec:
  image: ghcr.io/kubewarden/policy-server:v1.3.0
  replicas: 2
  env:
    - name: KUBEWARDEN_LOG_LEVEL
      value: info
```

### 5.2 ClusterAdmissionPolicy

Cluster-wide 嘅 policy，適用於整個集群：

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-privileged
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/privileged-pods:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
  mutating: false
```

### 5.3 AdmissionPolicy

只適用於指定 namespace 嘅 policy：

```yaml
apiVersion: policies.kubewarden.io/v1
kind: AdmissionPolicy
metadata:
  name: require-labels
  namespace: production
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/labels:v0.1.6
  rules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      resources: ["deployments"]
      operations:
        - CREATE
        - UPDATE
  settings:
    requiredLabels:
      - key: "app.kubernetes.io/managed-by"
        message: "must have managed-by label"
```

### 5.4 CRD 短名

| Resource | 短名 |
|----------|------|
| AdmissionPolicy | ap |
| ClusterAdmissionPolicy | cap |
| AdmissionPolicyGroups | apg |
| ClusterAdmissionPolicyGroups | capg |
| PolicyServers | ps |

---

## 6. 實際例子

### 6.1 禁止特權容器

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-privileged
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/privileged-pods:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
```

測試：
```bash
# 正常 pod → 通過
kubectl run nginx --image=nginx

# 特權 pod → 被拒絕
kubectl run priv --image=nginx --overrides='{"spec":{"containers":[{"name":"priv","image":"nginx","securityContext":{"privileged":true}}]}}'
```

### 6.2 只允許特定 registry 嘅 image

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: trusted-repos
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/trusted-repos:v0.3.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
  settings:
    registries:
      - "docker.io/library/"
      - "ghcr.io/"
      - "harbor.paulhome.local/"
```

### 6.3 強制 set resource limits

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: require-limits
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/require-resource-limits:v0.3.2
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
  settings:
    cpuRequestRequired: true
    memoryRequestRequired: true
    cpuLimitRequired: true
    memoryLimitRequired: true
```

### 6.4 強制必須有 annotation

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: require-annotations
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/annotations:v0.2.6
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["namespaces"]
      operations:
        - CREATE
  settings:
    requiredAnnotations:
      - key: "compliance.my-company.com/team-contact-email"
        message: "must have team contact email"
      - key: "compliance.my-company.com/team-region"
        allowedValues: ["AMER", "APAC", "EMEA"]
        message: "must have valid team region"
```

### 6.5 禁止 NodePort Service

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-nodeport
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/disallow-service-nodeport:v0.1.4
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["services"]
      operations:
        - CREATE
        - UPDATE
  settings:
    excludeNamespaces: ["kube-system"]
```

### 6.6 強制必須有 liveness/readiness probe

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: require-probes
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/require-probes:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
  settings:
    excludeNamespaces: ["kube-system"]
```

### 6.7 限制 hostPath 掛載

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: restricted-hostpaths
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/hostpaths:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
  settings:
    allowedHostPaths:
      - pathPrefix: "/var/run/containerd"
        readOnly: true
      - pathPrefix: "/etc/kubernetes"
        readOnly: true
```

### 6.8 強制必須有 label

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: require-labels
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/labels:v0.1.6
  rules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      resources: ["deployments"]
      operations:
        - CREATE
        - UPDATE
  settings:
    requiredLabels:
      - key: "app.kubernetes.io/managed-by"
        message: "must have managed-by label"
      - key: "team"
        message: "must have team label"
```

### 6.9 禁止特權升級

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-privilege-escalation
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/disallow-privilege-escalation:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations:
        - CREATE
        - UPDATE
```

### 6.10 限制 PVC StorageClass

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: restrict-storageclass
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/persistentvolumeclaim-storageclass:v0.2.0
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["persistentvolumeclaims"]
      operations:
        - CREATE
  settings:
    allowedStorageClasses:
      - "nfs-csi"
      - "local-path"
    rejectEmptyClaim: true
```

### 6.11 禁止 deprecated API version

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-deprecated-apis
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/deprecated-api-versions:v0.2.4
  rules:
    - apiGroups: ["*"]
      apiVersions: ["*"]
      resources: ["*"]
      operations:
        - CREATE
        - UPDATE
  settings:
    kubernetesVersion: "1.28.0"
```

---

## 7. 現成 Policy 清單

官方 monorepo 入面有 40+ 個現成 policy：

| Policy | 用途 |
|--------|------|
| privileged-pods | 禁止特權容器 |
| trusted-repos | 只允許指定 registry |
| container-resources | 強制 set resource limits |
| require-probes | 必須有 liveness/readiness probe |
| annotations | 強制必須有 annotation |
| labels | 強制必須有 label |
| hostpaths | 限制 hostPath 掛載路徑 |
| disallow-service-nodeport | 禁止 NodePort |
| disallow-service-loadbalancer | 禁止 LoadBalancer |
| disallow-privilege-escalation | 禁止特權升級 |
| env-variable-secrets-scanner | 掃描 env 有冇敏感資料 |
| verify-image-signatures | 驗證 image 簽名 |
| image-cve-policy | 掃描 image CVE |
| allow-privilege-escalation-psp | PSP 特權升級 |
| allowed-fsgroups-psp | PSP fsGroup |
| allowed-proc-mount-types PSP | PSP proc mount |
| apparmor-psp | PSP AppArmor |
| capabilities-psp | PSP capabilities |
| flexvolume-drivers-psp | PSP flexvolume |
| host-namespaces-psp | PSP host namespaces |
| sysctl-psp | PSP sysctl |
| user-group-psp | PSP user/group |
| volumes-psp | PSP volumes |
| cel-policy | CEL 語言 policy |
| kyverno-dsl-policy | Kyverno DSL policy |
| raw-validation-policy | Raw validation |
| raw-mutation-policy | Raw mutation |
| raw-validation-opa-policy | OPA Rego policy |
| context-aware-demo | Context-aware policy |
| priority-class-policy | PriorityClass |
| pod-runtime-class-policy | RuntimeClass |
| pod-ndots-policy | Pod ndots |
| share-pid-namespace-policy | Share PID namespace |
| volumeMounts-policy | Volume mounts |
| unique-service-selector-policy | Unique service selector |
| unique-ingress-policy | Unique ingress |
| namespace-label-propagator-policy | Namespace label propagator |
| rancher-project-propagate-labels | Rancher project labels |
| rancher-project-quotas-namespace-validator | Rancher project quotas |
| psa-label-enforcer-policy | PSA label enforcer |
| high-risk-service-account-policy | High-risk SA |
| sleeping-policy | Sleeping policy |
| echo | Echo policy (demo) |

完整 list：
- GitHub: https://github.com/kubewarden/policies/tree/main/policies
- ArtifactHub: https://artifacthub.io/packages/search?kind=13

---

## 8. 自己寫 Policy

### 8.1 幾時先要自己寫？

只有當你有 **特殊需求** 嘅時候：
- 例如你要 check 某個公司專屬嘅 annotation 規則
- 或者你要做一啲現成 policy 做唔到嘅邏輯

對於 90% 嘅場景，**現成 policy 已經夠用。**

### 8.2 支援嘅語言

| 語言 | SDK | 適合場景 |
|------|-----|----------|
| Rust | policy-sdk-rust | 高效能、型別安全 |
| Go (TinyGo) | policy-sdk-go | 團隊熟悉 Go |
| CEL | cel-policy | 簡單邏輯、K8s 內建 |
| Rego | raw-validation-opa-policy | OPA 背景團隊 |
| AssemblyScript | policy-sdk-as | JavaScript 背景 |
| Swift | policy-sdk-swift | Apple 生態 |

### 8.3 Go 範例

```go
package main

import (
    wapc "github.com/wapc/wapc-guest-tinygo"
    kubewarden "github.com/kubewarden/policy-sdk-go"
)

func main() {
    wapc.RegisterFunctions(wapc.Functions{
        "validate": func(payload []byte) ([]byte, error) {
            request := parseRequest(payload)
            
            for _, container := range request.Containers {
                if container.SecurityContext.Privileged == true {
                    return kubewarden.RejectRequest(
                        kubewarden.Message("特權容器唔允許"),
                    )
                }
            }
            
            return kubewarden.AcceptRequest()
        },
        "validate_settings": func(payload []byte) ([]byte, error) {
            return kubewarden.AcceptSettings()
        },
    })
}
```

### 8.4 Rust 範例

```rust
use kubewarden_policy_sdk::status::{accept_request, reject_request};
use kubewarden_policy_sdk::wasm::Payload;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct Request {
    containers: Vec<Container>,
}

#[derive(Serialize, Deserialize)]
struct Container {
    name: String,
    security_context: Option<SecurityContext>,
}

#[derive(Serialize, Deserialize)]
struct SecurityContext {
    privileged: Option<bool>,
}

fn validate(payload: Payload) -> Result<ValidationResponse, String> {
    let request: Request = serde_json::from_slice(payload.request)?;
    
    for container in &request.containers {
        if let Some(ctx) = &container.security_context {
            if ctx.privileged == Some(true) {
                return Ok(reject_request(
                    "特權容器唔允許".to_string(),
                    None,
                ));
            }
        }
    }
    
    Ok(accept_request())
}
```

### 8.5 CEL 範例

```yaml
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: cel-privileged-check
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/cel-policy:v0.1.0
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations: ["CREATE", "UPDATE"]
  settings:
    cel: |
      !object.spec.containers.exists(c, 
        has(c.securityContext) && 
        has(c.securityContext.privileged) && 
        c.securityContext.privileged == true)
```

### 8.6 本地測試

用 `kwctl` 可以喺本地測試 policy，唔使連集群：

```bash
# 測試 policy
kwctl run policy.wasm --request-path request.json 2>/dev/null | jq

# request.json 係 Kubernetes AdmissionRequest 對象
```

---

## 9. 管理工具

### 9.1 kwctl CLI

```bash
# 列出已有 policy
kubectl get clusteradmissionpolicies
kubectl get clusteradmissionpolicies -o wide

# 列出 PolicyServer
kubectl get policyservers

# 查看 policy 狀態
kubectl describe clusteradmissionpolicy <name>

# 刪除 policy
kubectl delete clusteradmissionpolicy <name>
```

### 9.2 Audit Scanner

Kubewarden 內建 audit scanner，可以掃描現有資源有冇違反 policy：

```bash
# 查看 audit 結果
kubectl get policyreports -A
kubectl describe policyreport <name>
```

---

## 10. 同其他方案比較

| | Kubewarden | OPA Gatekeeper | Kyverno |
|---|---|---|---|
| Policy 語言 | Rust / Go / CEL / Rego | Rego only | YAML (專用 DSL) |
| 學習成本 | 用已經識嘅語言 | 要學 Rego | 要學 Kyverno DSL |
| 隔離 | WebAssembly 沙箱 | 同進程 | 同進程 |
| 效能 | 高（Wasm 執行） | 中 | 中 |
| Policy 分發 | OCI registry | Bundle | Git / OCI |
| 現成 Policy | 40+ 官方 | 社區 | 200+ 社區 |
| Rancher 整合 | 原生支援 | 需要額外設定 | 需要額外設定 |

---

## 11. 參考資源

### 官方資源
- 文檔：https://docs.kubewarden.io/
- GitHub：https://github.com/kubewarden
- Policy Hub：https://hub.kubewarden.io/
- ArtifactHub：https://artifacthub.io/packages/search?kind=13
- Blog：https://www.kubewarden.io/blog/

### GitHub Repos
- Policies monorepo：https://github.com/kubewarden/policies
- Admission Controller：https://github.com/kubewarden/adm-controller
- kwctl CLI：https://github.com/kubewarden/kwctl
- Go SDK：https://github.com/kubewarden/policy-sdk-go
- Rust SDK：https://github.com/kubewarden/policy-sdk-rust

### 相關博客
- Writing your first policy：https://www.kubewarden.io/blog/2021/06/writing-your-first-policy-with-kubewarden
- Kubewarden overview (SUSE)：https://www.suse.com/c/rancher_blog/kubewarden-an-open-source-security-policy-engine

---

## 附錄：快速開始 cheat sheet

```bash
# 安裝
helm repo add kubewarden https://charts.kubewarden.io
helm repo update kubewarden
helm install --wait -n kubewarden --create-namespace kubewarden-crds kubewarden/kubewarden-crds
helm install --wait -n kubewarden kubewarden-controller kubewarden/kubewarden-controller
helm install --wait -n kubewarden kubewarden-defaults kubewarden/kubewarden-defaults

# 部署第一條 policy
kubectl apply -f - <<EOF
apiVersion: policies.kubewarden.io/v1
kind: ClusterAdmissionPolicy
metadata:
  name: disallow-privileged
spec:
  policyServer: default
  module: registry://ghcr.io/kubewarden/policies/privileged-pods:v0.2.1
  rules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
      operations: ["CREATE", "UPDATE"]
EOF

# 測試
kubectl run nginx --image=nginx  # 應該通過
kubectl run priv --image=nginx --overrides='{"spec":{"containers":[{"name":"priv","image":"nginx","securityContext":{"privileged":true}}]}}'  # 應該被拒絕

# 查看狀態
kubectl get clusteradmissionpolicies
kubectl get policyreports -A

# 卸載
helm uninstall --namespace kubewarden kubewarden-defaults
helm uninstall --namespace kubewarden kubewarden-controller
helm uninstall --namespace kubewarden kubewarden-crds
kubectl delete namespace kubewarden
```

## 12. GitOps 部署

Kubewarden policy 本身就係 Kubernetes CRD（Custom Resource），所以同 deploy Deployment、Service 一樣，直接用 GitOps 管理就得。

### 12.1 用 ArgoCD 部署

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubewarden-policies
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/devops6668/paul-ai-worksapce.git
    targetRevision: main
    path: k8s-ctl-deploy/kubewarden/policies
  destination:
    server: https://kubernetes.default.svc
    namespace: kubewarden
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 12.2 用 Flux 部署

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kubewarden-policies
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/devops6668/paul-ai-worksapce.git
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kubewarden-policies
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: kubewarden-policies
  path: ./k8s-ctl-deploy/kubewarden/policies
  prune: true
```

### 12.3 推薦嘅目錄結構

```
kubewarden/
├── base/
│   ├── policy-server.yaml
│   ├── disallow-privileged.yaml
│   ├── trusted-repos.yaml
│   ├── require-limits.yaml
│   └── require-probes.yaml
├── overlays/
│   ├── production/
│   │   ├── kustomization.yaml
│   │   └── policies.yaml   # 有 audit mode
│   └── staging/
│       ├── kustomization.yaml
│       └── policies.yaml   # 有 enforce mode
```

### 12.4 同 Helm 一齊用

如果你想用 Helm chart 裝 Kubewarden 本身，policy 可以分開管理：

```yaml
# helmfile.yaml
repositories:
  - name: kubewarden
    url: https://charts.kubewarden.io

releases:
  - name: kubewarden-crds
    namespace: kubewarden
    chart: kubewarden/kubewarden-crds
  - name: kubewarden-controller
    namespace: kubewarden
    chart: kubewarden/kubewarden-controller
  - name: kubewarden-defaults
    namespace: kubewarden
    chart: kubewarden/kubewarden-defaults
```

然後 Policy 用 ArgoCD / Flux 獨立管理，互不干擾。

### 12.5 Policy 版本更新

```bash
# 喺 repo 入面改 module 版本
# 例如由 v0.2.1 → v0.3.0
spec:
  module: registry://ghcr.io/kubewarden/policies/privileged-pods:v0.3.0

# GitOps controller 自動 sync，policy 自動更新
```

### 12.6 總結

- Kubewarden policy 係 standard K8s CRD
- 你平時用開咩 GitOps tool 就用返咩，冇任何特殊設定
- Kubewarden 本身用 Helm 裝，Policy 用 ArgoCD / Flux 管理，兩者互不干擾

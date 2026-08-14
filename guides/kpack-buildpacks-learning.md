# kpack & Cloud Native Buildpacks 學習指南

> 整理日期: 2026-08-14
> 來源: https://github.com/buildpacks-community/kpack
> 作者: Paul Wong

---

## 目錄

1. [核心概念](#1-核心概念)
2. [Buildpack 係咩](#2-buildpack-係咩)
3. [Buildpackage 係咩](#3-buildpackage-係咩)
4. [kpack 係咩](#4-kpack-係咩)
5. [三者嘅關係](#5-三者嘅關係)
6. [kpack CRD 資源](#6-kpack-crd-資源)
7. [Buildpack 生態](#7-buildpack-生態)
8. [邊度搵現成 Buildpacks](#8-邊度搵現成-buildpacks)
9. [kpack vs pack CLI](#9-kpack-vs-pack-cli)
10. [自己寫 Buildpack](#10-自己寫-buildpack)
11. [Luban CI 整合](#11-luban-ci-整合)
12. [快速入門](#12-快速入門)

---

## 1. 核心概念

```
Buildpack = 標準 + 實現 (點樣將 source code 變成 OCI image)
kpack     = 喺 K8s 上面跑 buildpacks 嘅平台
pack CLI  = 喺本地跑 buildpacks 嘅工具
```

---

## 2. Buildpack 係咩

Buildpack 係一組 **executable scripts + metadata**，打包成一個 docker image (叫 buildpackage)。

佢嘅工作：**自動 detect 你嘅 app 語言，然後 build 成 OCI image**。

### 2.1 Buildpack 入面有咩？

```
my-buildpack/
├── buildpack.toml     ← metadata (id, version, 兼容嘅 stack)
└── bin/
    ├── detect         ← 偵測腳本
    └── build          ← 建構腳本
```

### 2.2 兩種 Buildpack

| 類型 | 包含 | 作用 |
|------|------|------|
| Component Buildpack | bin/detect + bin/build | 真正做 detect + build |
| Composite Buildpack | 只有 buildpack.toml + order | 定義 buildpack 組合順序 |

### 2.3 Detection Phase

Buildpack 嘅 `detect` script 會掃你嘅 source code：

```
Java buildpack:  搵 pom.xml / build.gradle → pass
Node.js buildpack: 搵 package.json → pass
Python buildpack: 搵 requirements.txt / pyproject.toml / uv.lock → pass
```

### 2.4 Build Phase

`build` script 會：
1. 安裝 runtime (JDK, Node.js, etc.)
2. 安裝 build tool (Maven, npm, etc.)
3. Download dependencies
4. Compile (如果需要)
5. 定義 process type (web, worker, etc.)
6. 產出 OCI image layers

### 2.5 Layer 機制

```
launch layer  → 喺最終 OCI image 入面
build layer   → 只存在喺 build 環境，build 完就丟
cache layer   → 存喺 build cache，下次 build 可以 restore
```

---

## 3. Buildpackage 係咩

Buildpackage 係一個 **docker image**，入面打包咗一個或一組 buildpack。

```
paketobuildpacks/java (buildpackage = docker image)
├── buildpack.toml
├── bin/detect
├── bin/build
├── jvmcommon/          ← sub-buildpack
├── gradle/             ← sub-buildpack
└── maven/              ← sub-buildpack
```

### 打包方式

```bash
# 用 pack CLI
pack buildpack package my-buildpack \
  --path ./my-buildpack/ \
  --format image

# 或者自己寫 Dockerfile
FROM buildpacksio/buildpack
COPY --chown=1000:1000 buildpack.toml /buildpacks/my-buildpack/
COPY --chown=1000:1000 bin/ /buildpacks/my-buildpack/bin/
```

---

## 4. kpack 係咩

kpack 係一個 **Kubernetes controller**，佢唔識 build app，只係幫手 orchestrate 成個 build 流程。

### 4.1 kpack 做咩？

```
1. watch Image CRD
2. 自動 create Build CRD
3. 自動 create build Pod
4. Pod 入面跑 lifecycle
5. Lifecycle 調用 buildpacks
6. 最終 push OCI image 到 registry
```

### 4.2 額外功能

```
- 自動 rebuild (source/buildpack/stack 變)
- 自動 rebase (stack update)
- Cache management (volume / registry)
- Multi-tenancy (namespace 隔離)
- RBAC (邊個 team 可以 build)
- Cosign 簽名 (自動簽名 image)
```

---

## 5. 三者嘅關係

```
kpack ──引用──▶ ClusterStore ──包含──▶ Buildpackage ──包含──▶ Buildpack
(controller)  (資料庫)          (docker image)        (scripts)
```

### 類比

```
Buildpack  = 食譜 (點樣煮某道菜)
Buildpackage = 一本書 (打包好嘅食譜)
kpack      = 自動煮食機 (喺 K8s 上面幫你煮)
pack CLI   = 你喺屋企廚房煮 (自己執行食譜)
ClusterStore = 書架 (存放所有書)
Builder    = 借書證 (定義你有權借邊啲書)
Image      = 你嘅借書請求 (我要呢本書)
```

---

## 6. kpack CRD 資源

### 6.1 ClusterStore — Buildpackage 嘅倉庫

```yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterStore
metadata:
  name: paketo
spec:
  sources:
  - image: paketobuildpacks/java
  - image: paketobuildpacks/nodejs
  - image: paketobuildpacks/go
```

可以按語言 / team / project 拆分多個 Store。

### 6.2 ClusterStack — Build 嘅基礎 OS

```yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterStack
metadata:
  name: base
spec:
  id: "io.buildpacks.stacks.jammy"
  buildImage:
    image: "paketobuildpacks/build-jammy-base"
  runImage:
    image: "paketobuildpacks/run-jammy-base"
```

### 6.3 ClusterLifecycle — Lifecycle binary

```yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterLifecycle
metadata:
  name: default-lifecycle
spec:
  image: buildpacksio/lifecycle
```

### 6.4 Builder / ClusterBuilder — 整合配置

```yaml
apiVersion: kpack.io/v1alpha2
kind: Builder
metadata:
  name: my-builder
  namespace: default
spec:
  serviceAccountName: kpack-sa
  tag: harbor.paulhome.local/kpack/builder
  stack:
    name: base
    kind: ClusterStack
  store:
    name: paketo
    kind: ClusterStore
  order:
  - group:
    - id: paketo-buildpacks/java
  - group:
    - id: paketo-buildpacks/nodejs
  - group:
    - id: paketo-buildpacks/go
```

### 6.5 Image — 你嘅 App 定義

```yaml
apiVersion: kpack.io/v1alpha2
kind: Image
metadata:
  name: my-app
  namespace: default
spec:
  tag: harbor.paulhome.local/apps/my-app
  serviceAccountName: kpack-sa
  builder:
    name: my-builder
    kind: Builder
  source:
    git:
      url: https://github.com/myorg/myapp.git
      revision: main
  cache:
    volume:
      size: "2Gi"
  build:
    env:
    - name: BP_JAVA_VERSION
      value: "21"
```

### 6.6 Secrets

```yaml
# Registry secret
apiVersion: v1
kind: Secret
metadata:
  name: harbor-credentials
  annotations:
    kpack.io/docker: harbor.paulhome.local
type: kubernetes.io/basic-auth
stringData:
  username: admin
  password: xxx

# Git secret
apiVersion: v1
kind: Secret
metadata:
  name: github-credentials
  annotations:
    kpack.io/git: https://github.com
type: kubernetes.io/basic-auth
stringData:
  username: xxx
  password: xxx
```

---

## 7. Buildpack 生態

### 主要維護者

| 維護者 | 適用場景 | 狀態 |
|--------|----------|------|
| **Paketo** | 最主流，支援 Java/Node/Go/Python/Ruby/.NET/PHP | 活躍，CNCF 生態 |
| **Google Cloud** | GCP 專屬，整合 Cloud Build | 活躍 |
| **Heroku** | Heroku 平台用 | 活躍 |
| **Luban CI** | Python uv + dbt 整合 | 活躍 |

### 幾時要自己寫 Buildpack？

```
1. 你有 proprietary framework → 外面冇 buildpack
2. 你有特殊 build 邏輯 → 要加額外 step
3. 語言/工具太新 → 社群仲未有
4. 你要整合內部工具鏈 → private mirror 等
```

---

## 8. 邊度搵現成 Buildpacks

### Paketo Buildpacks (推薦)

```
官網: https://paketo.io
GitHub: https://github.com/paketo-buildpacks

語言         buildpackage image
─────────────────────────────────────
Java         paketobuildpacks/java
Node.js      paketobuildpacks/nodejs
Go           paketobuildpacks/go
Python       paketobuildpacks/python
Ruby         paketobuildpacks/ruby
PHP          paketobuildpacks/php
.NET Core    paketobuildpacks/dotnet-core
Rust         paketobuildpacks/rust
```

### Google Cloud Buildpacks

```
GitHub: https://github.com/GoogleCloudPlatform/buildpacks
Image: gcr.io/buildpacks/builder/v1
```

### Heroku Buildpacks

```
Docker Hub: https://hub.docker.com/r/heroku/buildpacks
Image: heroku/buildpacks:24
```

---

## 9. kpack vs pack CLI

```
              pack CLI         kpack
─────────────────────────────────────────
需要 K8s      唔使              要
需要 Docker   要                唔使 (k8s pod)
自動 rebuild  唔使 (手動)       ✅ 自動
適合場景      本地開發/CI/CD    生產環境
學習成本      低                高
```

### pack CLI 快速試玩

```bash
# 安裝
brew install buildpacks/tap/pack

# Build
pack build my-app \
  --builder paketobuildpacks/builder:base \
  --path .

# Run
docker run -p 8080:8080 my-app
```

---

## 10. 自己寫 Buildpack

### 最簡單嘅結構

```
my-buildpack/
├── buildpack.toml
└── bin/
    ├── detect
    └── build
```

### buildpack.toml

```toml
api = "0.12"
[buildpack]
  id = "com.mycompany/my-runtime"
  version = "1.0.0"
[[targets]]
  os = "linux"
```

### bin/detect

```bash
#!/bin/bash
if [ -f "/workspace/my-config.yaml" ]; then
    echo "MyCompany Runtime"
    exit 0
fi
exit 1
```

### bin/build

```bash
#!/bin/bash
# 安裝 runtime、copy files、設定 process
cp /workspace/my-config.yaml /layers/config/
cat <<EOF > "$CNB_PLATFORM_DIR/launch.toml"
[[processes]]
  type = "web"
  command = "my-app --config /layers/config/my-config.yaml"
  default = true
EOF
```

---

## 11. Luban CI 整合

### Luban CI 係咩？

GitOps-based CI system，跑喺 K8s 上面，用 Argo Workflows + Cloud Native Buildpacks。

### 為咩要自己寫 Buildpack？

因為 Paketo 嘅 Python buildpack 唔支援 `uv` (超快 Python package manager)。

```
Paketo Python buildpack:
  ✓ pip / poetry / pipenv
  ✗ uv

Luban CI python-uv buildpack:
  ✓ uv (快 10-100 倍)
  ✓ dbt 整合
  ✓ Private mirror (netrc + CA cert)
  ✓ Direct execution mode
```

### Luban CI Buildpack 特色

```
1. uv 版本管理 (.uv-version file)
2. SHA256 checksum 校驗
3. Service Binding (netrc + CA cert)
4. dbt project 自動偵測 + manifest 生成
5. Standard / Direct execution mode
6. Layer caching (uv, python, venv, cache)
```

---

## 12. 快速入門

### 安裝 kpack

```bash
kubectl apply --filename release-<version>.yaml
kubectl get pods --namespace kpack --watch
```

### 前設

```
1. K8s cluster 1.22+
2. kubectl CLI
3. cluster-admin 權限
4. 可以寫嘅 Docker V2 registry (例如 Harbor)
```

### 基本部署

```bash
# 1. Registry credentials
kubectl create secret docker-registry harbor-credentials \
  --docker-username=admin \
  --docker-password=xxx \
  --docker-server=harbor.paulhome.local

# 2. ServiceAccount
kubectl apply -f service-account.yaml

# 3. ClusterStore
kubectl apply -f store.yaml

# 4. ClusterStack
kubectl apply -f stack.yaml

# 5. ClusterLifecycle
kubectl apply -f lifecycle.yaml

# 6. Builder
kubectl apply -f builder.yaml

# 7. Image
kubectl apply -f image.yaml

# 8. 睇 build status
kubectl get images
kubectl get builds
```

---

## 參考連結

- kpack: https://github.com/buildpacks-community/kpack
- CNB Spec: https://github.com/buildpacks/spec
- Paketo Buildpacks: https://paketo.io
- Google Buildpacks: https://github.com/GoogleCloudPlatform/buildpacks
- Heroku Buildpacks: https://hub.docker.com/r/heroku/buildpacks
- Luban CI: https://github.com/metasync/luban-ci
- pack CLI: https://github.com/buildpacks/pack

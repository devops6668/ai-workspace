# kpack & Cloud Native Buildpacks 學習指南

> 整理日期: 2026-08-14
> 來源: https://github.com/buildpacks-community/kpack
> Luban CI: https://github.com/metasync/luban-ci
> 作者: Paul Wong

---

## 目錄

1. [核心概念](#1-核心概念)
2. [kpack 設置指南](#2-kpack-設置指南)
3. [Buildpack 係咩](#3-buildpack-係咩)
4. [Buildpackage 係咩](#4-buildpackage-係咩)
5. [kpack 係咩](#5-kpack-係咩)
6. [三者嘅關係](#6-三者嘅關係)
7. [kpack CRD 資源](#7-kpack-crd-資源)
8. [Buildpack 生態](#8-buildpack-生態)
9. [邊度搵現成 Buildpacks](#9-邊度搵現成-buildpacks)
10. [kpack vs pack CLI](#10-kpack-vs-pack-cli)
11. [自己寫 Buildpack](#11-自己寫-buildpack)
12. [Luban CI 整合](#12-luban-ci-整合)
13. [快速入門](#13-快速入門)

---

## 1. 核心概念

```
Buildpack   = 標準 + 實現 (點樣將 source code 變成 OCI image)
kpack       = 喺 K8s 上面跑 buildpacks 嘅平台 (CRD-based)
pack CLI    = 喺本地跑 buildpacks 嘅工具
Luban CI    = 喺 K8s 上面跑 buildpacks 嘅 CI 系統 (Argo Workflows-based)
```

### 平台全景

```
Buildpacks (CNB 標準)
    │
    ├── 本地開發 ──── pack CLI
    │
    ├── CI/CD ──── Luban CI / GitHub Actions / GitLab CI / Tekton
    │
    ├── 雲平台 ──── Heroku / Google App Engine / Cloud Foundry
    │
    └── K8s ──── kpack (CRD-based, 自動 rebuild)
                 Luban CI (Argo Workflows-based, pipeline orchestration)
```

---

## 2. kpack 設置指南

安裝完 kpack 之後，要按順序設置以下 CRD 先至可以 build 到 image。

### 2.1 必須設置嘅 7 樣嘢

```
順序:
1. Secret           ← 憑證 (registry + git)
2. ServiceAccount   ← 掛 secret
3. ClusterStore     ← buildpackage 倉庫
4. ClusterStack     ← OS base image
5. ClusterLifecycle ← lifecycle binary
6. Builder          ← 整合以上全部
7. Image            ← 你嘅 app (終於可以 build)
```

### 2.2 Secret — Registry + Git 憑證

```yaml
# Registry push credentials (你嘅 Harbor)
apiVersion: v1
kind: Secret
metadata:
  name: harbor-credentials
  annotations:
    kpack.io/docker: harbor.paulhome.local    # ← registry 地址
type: kubernetes.io/basic-auth
stringData:
  username: admin
  password: Harbor12345

---
# Git source credentials (私有 repo 先需要)
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

### 2.3 ServiceAccount — 掛 Secret

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kpack-sa
  namespace: default
secrets:
- name: harbor-credentials
imagePullSecrets:
- name: harbor-credentials
```

### 2.4 ClusterStore — Buildpackage 倉庫

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
  # 如果用 Luban CI:
  # - image: your-registry/luban-ci/python-uv
```

### 2.5 ClusterStack — OS Base Image

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

### 2.6 ClusterLifecycle — Lifecycle Binary

```yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterLifecycle
metadata:
  name: default-lifecycle
spec:
  image: buildpacksio/lifecycle
```

### 2.7 Builder — 整合配置

```yaml
apiVersion: kpack.io/v1alpha2
kind: Builder
metadata:
  name: my-builder
  namespace: default
spec:
  serviceAccountName: kpack-sa
  tag: harbor.paulhome.local/kpack/builder    # builder image 嘅位置
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

### 2.8 Image — 你嘅 App

```yaml
apiVersion: kpack.io/v1alpha2
kind: Image
metadata:
  name: my-app
  namespace: default
spec:
  tag: harbor.paulhome.local/apps/my-app     # 出 image 嘅位置
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
```

### 2.9 一覽表

```
資源               必須?   作用
─────────────────────────────────────────────
Secret             ✓      registry + git credentials
ServiceAccount     ✓      掛 secret
ClusterStore       ✓      buildpackage 倉庫
ClusterStack       ✓      OS base image
ClusterLifecycle   ✓      lifecycle binary
Builder            ✓      整合 stack + store + order
Image              ✓      你嘅 app
```

### 2.10 完整流程圖

```
1. kpack 安裝
   kubectl apply -f release.yaml
   ↓
2. Secret (registry + git)
   kubectl apply -f secret.yaml
   ↓
3. ServiceAccount
   kubectl apply -f sa.yaml
   ↓
4. ClusterStore (buildpackages)
   kubectl apply -f store.yaml
   ↓
5. ClusterStack (OS base)
   kubectl apply -f stack.yaml
   ↓
6. ClusterLifecycle
   kubectl apply -f lifecycle.yaml
   ↓
7. Builder
   kubectl apply -f builder.yaml
   ↓
8. Image ← 終於可以 build!
   kubectl apply -f image.yaml
   ↓
9. kpack 自動 create Build + Pod
   ↓
10. OCI Image 出咗去 registry
```

### 2.11 你嘅環境 (k3s + Harbor) 嘅具體設定

```yaml
# Secret — 用你嘅 Harbor
kpack.io/docker: harbor.paulhome.local

# Builder tag — 寫入 Harbor
tag: harbor.paulhome.local/kpack/builder

# Image tag — 寫入 Harbor
tag: harbor.paulhome.local/apps/my-app

# Store — 用 Paketo
- image: paketobuildpacks/java
- image: paketobuildpacks/nodejs
```

### 2.12 常見問題

```
Q: ClusterStore 唔 reconcile?
A: 檢查 ServiceAccount 有冇 registry 權限

Q: Builder 一直 pending?
A: 檢查 ClusterStore + ClusterStack 係咪 Ready

Q: Image build fail?
A: kp build logs <image-name> -n <namespace> 睇 log
```

---

## 3. Buildpack 係咩

Buildpack 係一組 **executable scripts + metadata**，打包成一個 docker image (叫 buildpackage)。

佢嘅工作：**自動 detect 你嘅 app 語言，然後 build 成 OCI image**。

### 3.1 兩種 Buildpack

| 類型 | 包含 | 作用 | 類比 |
|------|------|------|------|
| **Component** | buildpack.toml + bin/detect + bin/build | 真正做 detect + build | 工人 (識砌牆) |
| **Composite** | 只有 buildpack.toml + order | 定義 buildpack 組合順序 | 圖紙 (定義用邊個工人) |

#### Component Buildpack (有 scripts)

```
paketo-buildpacks/gradle/        ← component buildpack
├── buildpack.toml                ← metadata
└── bin/
    ├── detect                    ← 搵 build.gradle / gradlew
    └── build                     ← 安裝 Gradle + run build
```

#### Composite Buildpack (冇 scripts，只有 order)

```
paketo-buildpacks/java/          ← composite buildpack
├── buildpack.toml                ← 只有呢個，冇 bin/ directory
│   order:
│   - group: [bellsoft-liberica, gradle, syft, spring-boot]
│   - group: [bellsoft-liberica, maven, syft, spring-boot]
│
└── (冇 bin/ directory)
```

**Composite 唔係 "集合"，係 "配方"** — 只係列出 "用邊啲 component buildpacks、咩順序"，入面冇任何 code。

### 3.2 Composite vs Component 嘅分別

```
                    Component Buildpack    Composite Buildpack
────────────────────────────────────────────────────────────
有 bin/detect       ✓                      ✗
有 bin/build        ✓                      ✗
有 buildpack.toml   ✓                      ✓
有 order definition ✗ (喺 builder.toml)    ✓
做 detect           ✓ (真正跑 script)       ✗ (只定義組合)
做 build            ✓ (真正跑 script)       ✗ (只定義組合)
檔案大小            幾 MB (有 code)        幾 KB (只有 toml)
```

### 3.3 Composite 嘅真實例子

#### Paketo Java (composite) — 22 個 component buildpacks

```toml
# buildpack.toml — 呢個就係全部，冇 bin/

api = "0.7"

[buildpack]
id = "paketo-buildpacks/java"
name = "Paketo Buildpack for Java"
keywords = ["java", "composite"]    # ← 標記咗係 composite

# 一個 group，22 個 component buildpacks
[[order]]
  [[order.group]]
  id = "paketo-buildpacks/ca-certificates"
  optional = true
  version = "3.12.6"

  [[order.group]]
  id = "paketo-buildpacks/bellsoft-liberica"     # JDK
  version = "11.8.2"

  [[order.group]]
  id = "paketo-buildpacks/gradle"
  optional = true
  version = "8.7.3"

  [[order.group]]
  id = "paketo-buildpacks/maven"
  optional = true
  version = "6.24.1"

  [[order.group]]
  id = "paketo-buildpacks/syft"                   # SBOM
  optional = true
  version = "2.39.0"

  [[order.group]]
  id = "paketo-buildpacks/spring-boot"
  optional = true
  version = "5.36.6"

  [[order.group]]
  id = "paketo-buildpacks/executable-jar"
  optional = true
  version = "6.15.6"

  [[order.group]]
  id = "paketo-buildpacks/procfile"
  optional = true
  version = "5.13.6"

  # ... 省略其他 14 個 optional buildpacks
```

#### Paketo Node.js (composite) — 三個 group

```toml
api = "0.7"

[buildpack]
id = "paketo-buildpacks/nodejs"
name = "Paketo Buildpack for Node.js"

# Group 1: yarn + node (有 yarn.lock 時用)
[[order]]
  [[order.group]]
  id = "paketo-buildpacks/node-engine"
  version = "8.5.0"

  [[order.group]]
  id = "paketo-buildpacks/yarn"
  version = "2.4.0"

  [[order.group]]
  id = "paketo-buildpacks/yarn-install"
  version = "2.7.24"

  [[order.group]]
  id = "paketo-buildpacks/yarn-start"
  optional = true
  version = "2.5.30"

# Group 2: npm + node (有 package.json 時用)
[[order]]
  [[order.group]]
  id = "paketo-buildpacks/node-engine"
  version = "8.5.0"

  [[order.group]]
  id = "paketo-buildpacks/npm-install"
  version = "2.3.29"

  [[order.group]]
  id = "paketo-buildpacks/npm-start"
  optional = true
  version = "2.5.0"

# Group 3: 純 node (冇 package manager 時用)
[[order]]
  [[order.group]]
  id = "paketo-buildpacks/node-engine"
  version = "8.5.0"

  [[order.group]]
  id = "paketo-buildpacks/node-start"
  version = "2.7.0"
```

#### Detection 流程 (Node.js)

```
你嘅 app 有 yarn.lock?
  │
  ├─ Yes → Group 1: [node-engine, yarn, yarn-install] → pass ✅
  │
  └─ No → Group 2: [node-engine, npm-install]
            │
            ├─ 有 package.json? → pass ✅
            │
            └─ No → Group 3: [node-engine, node-start]
                      │
                      ├─ 有 JS files? → pass ✅
                      └─ No → fail ❌
```

### 3.4 Buildpack ID — 自己定義嘅名

Buildpack ID 係你自己定義嘅，冇人幫你註冊，冇 registry。

```
格式: 任意字串 (但有慣例)
慣例: 反向域名 + 名稱

Paketo:       paketo-buildpacks/java
Google:       google-buildpacks/python
Luban CI:     luban-ci/python-uv
你自己:       com.yourcompany/my-buildpack
```

**唯一性靠三個嘢加埋：**
```
ID + version + image location = 唯一

例如:
  ID:      paketo-buildpacks/java
  Version: 11.8.2
  Image:   gcr.io/paketo-buildpacks/java@sha256:abc123
```

### 3.5 TOML — Buildpack 嘅設定檔格式

Buildpack 用 TOML (Tom's Obvious, Minimal Language) 做設定檔。

#### 基本語法

```toml
# Key-value
name = "My Buildpack"
version = "1.0.0"
debug = true

# Table (物件)
[buildpack]
id = "com.example/my-bp"
version = "1.0.0"

# Array of Tables (陣列)
[[order]]
  [[order.group]]
  id = "com/example/gradle"

  [[order.group]]
  id = "com/example/syft"
```

#### TOML vs YAML vs JSON

```
YAML  = 用縮排 (indentation) 表示層級
JSON  = 用大括號 {} 表示物件，用方括號 [] 表示陣列
TOML  = 用 [table] 表示物件，用 [[array]] 表示陣列
```

#### 你會見到 TOML 嘅地方

```
buildpack.toml     ← buildpack 嘅 metadata
builder.toml       ← builder 嘅配置
package.toml       ← 打包配置
project.toml       ← 項目 descriptor
Cargo.toml         ← Rust 嘅 package manager
pyproject.toml     ← Python 嘅 project config
```

### 3.6 Detection Phase

Buildpack 嘅 `detect` script 會掃你嘅 source code：

```
Java buildpack:    搵 pom.xml / build.gradle → pass
Node.js buildpack: 搵 package.json / yarn.lock → pass
Python buildpack:  搵 requirements.txt / pyproject.toml / uv.lock → pass
Go buildpack:      搵 go.mod → pass
Ruby buildpack:    搵 Gemfile → pass
PHP buildpack:     搵 composer.json → pass
```

### 3.7 Build Phase

`build` script 會：
1. 安裝 runtime (JDK, Node.js, etc.)
2. 安裝 build tool (Maven, npm, etc.)
3. Download dependencies
4. Compile (如果需要)
5. 定義 process type (web, worker, etc.)
6. 產出 OCI image layers

### 3.8 Layer 機制

```
launch layer  → 喺最終 OCI image 入面 (runtime + dependencies)
build layer   → 只存在喺 build 環境，build 完就丟 (編譯工具)
cache layer   → 存喺 build cache，下次 build 可以 restore (npm cache)
```

### 3.9 Luban CI 嘅 Buildpack 做法

Luban CI 寫咗一個 `python-uv` buildpack (component)，支援 `uv` (超快 Python package manager)：

```
luban-ci/buildpacks/python-uv/    ← component buildpack
├── buildpack.toml
├── package.toml
├── README.md
└── bin/
    ├── detect          ← 搵 pyproject.toml / uv.lock / .python-version
    ├── build           ← 安裝 uv + Python + uv sync + dbt
    └── parse_config.py ← 解析 pyproject.toml entry points (額外加嘅)
```

#### 為咩 Luban CI 要自己寫？

因為 Paketo 嘅 Python buildpack 唔支援 `uv`：
```
Paketo Python buildpack:  ✓ pip / poetry / pipenv  ✗ uv
Luban CI python-uv:       ✓ uv (快 10-100 倍)
```

#### parse_config.py 嘅作用

`parse_config.py` 係 Luban CI **額外加嘅 helper script**，唔係 CNB spec 要求嘅。

```
CNB Spec 只要求:
  ✓ bin/detect 存在
  ✓ bin/build 存在
  ✓ 輸出 launch.toml (定義 process)

CNB Spec 唔要求:
  ✗ 你要跑邊個 script
  ✗ 你要點解析 config
  ✗ 你要用咩 language 寫
```

**`parse_config.py` 做咩：**
```python
# 讀 /workspace/pyproject.toml (你嘅 app config)
# 搵 [project.scripts] 入面嘅 entry point
# 輸出: MODE=standard, SCRIPT_NAME=app

# 例如你嘅 pyproject.toml:
[project.scripts]
app = "my_app:main"

# parse_config.py 輸出:
MODE=standard
SCRIPT_NAME=app
```

**點解需要佢？** 因為 bash 冇 TOML parser：
```
Paketo (Go 寫嘅 buildpack):
  → Go 內建 TOML parser
  → 直接喺 Go code 入面解析 pyproject.toml
  → 冇額外 script

Luban CI (bash 寫嘅 buildpack):
  → bash 唔識讀 TOML
  → 要用 Python (tomllib) 解析
  → 所以寫咗 parse_config.py
  → build script 再 eval 佢嘅輸出
```

#### parse_config.py 點被打包入 buildpackage？

```
源碼目錄:
luban-ci/buildpacks/python-uv/
├── bin/
│   ├── detect
│   ├── build
│   └── parse_config.py    ← 佢喺度

打包命令:
pack buildpack package your-registry/luban-ci/python-uv \
  --path . \
  --format image

pack CLI 自動做:
  1. 讀 bin/ 目錄入面所有檔案
  2. detect + build + parse_config.py 全部打包入去
  3. 組合成一個 docker image
  4. push 到 registry

結果:
your-registry/luban-ci/python-uv (docker image)
└── /buildpacks/python-uv/
    └── bin/
        ├── detect
        ├── build
        └── parse_config.py    ← 喺 image 入面
```

#### parse_config.py 點被執行？

**`bin/build` 入面自己寫嘅，冇任何 config 指定：**

```bash
# bin/build 入面，其中一步:

PYTHON_BIN=".venv/bin/python"
PARSE_SCRIPT="$CNB_BUILDPACK_DIR/bin/parse_config.py"

# 跑佢
PARSED_OUTPUT=$($PYTHON_BIN "$PARSE_SCRIPT")
eval "$PARSED_OUTPUT"

# eval 之後:
# $MODE = "standard"
# $SCRIPT_NAME = "app"

# 然後用呢啲值寫 launch.toml
```

**因果關係：**
```
1. bin/build 入面寫咗要跑 parse_config.py
2. 所以 build 嘅時候會執行佢
3. parse_config.py 讀 /workspace/pyproject.toml
4. 輸出 MODE + SCRIPT_NAME
5. eval 之後有值
6. 用呢啲值寫 launch.toml
7. 最終 image 入面跑你嘅 app
```

#### 完整嘅 Build Flow

```
你嘅 Git Repo (GitHub)
┌─────────────────────────────┐
│ my-python-app/              │
│ ├── pyproject.toml          │ ← parse_config 讀呢個
│ ├── uv.lock                 │
│ └── src/my_app/main.py      │
└─────────────┬───────────────┘
              │ git clone
              ▼
Build Pod /workspace/
┌─────────────────────────────┐
│ /workspace/                 │
│ ├── pyproject.toml          │ ← 同一份，copy 咗過嚟
│ ├── uv.lock                 │
│ └── src/my_app/main.py      │
└─────────────┬───────────────┘
              │ bin/build 執行
              ▼
┌─────────────────────────────┐
│ 1. 安裝 uv                  │
│ 2. 安裝 Python              │
│ 3. uv sync                  │
│ 4. python parse_config.py   │ ← 讀 pyproject.toml
│    → MODE=standard          │
│    → SCRIPT_NAME=app        │
│ 5. 寫 launch.toml           │
└─────────────┬───────────────┘
              │
              ▼
OCI Image (可以 run)
```

#### 你可以用 Composite Buildpack 組合 Luban CI + Paketo

```toml
# com.mycompany/python-suite (composite)
[buildpack]
id = "com.mycompany/python-suite"
version = "1.0.0"

# Group 1: uv-based (最快)
[[order]]
  [[order.group]]
  id = "luban-ci/python-uv"
  version = "1.0.0"
  [[order.group]]
  id = "paketo-buildpacks/syft"
  optional = true

# Group 2: pip-based (fallback)
[[order]]
  [[order.group]]
  id = "paketo-buildpacks/python"
  version = "5.0.0"
  [[order.group]]
  id = "paketo-buildpacks/pip"
  version = "3.0.0"
```

---

## 4. Buildpackage 係咩

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

### Luban CI 嘅 Buildpackage

```
luban-ci/python-uv (buildpackage)
├── buildpack.toml
├── package.toml
├── bin/
│   ├── detect          ← 搵 pyproject.toml / uv.lock
│   ├── build           ← 安裝 uv + Python + dependencies
│   └── parse_config.py ← 解析 pyproject.toml entry points
└── README.md
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

## 5. kpack 係咩

kpack 係一個 **Kubernetes controller**，佢唔識 build app，只係幫手 orchestrate 成個 build 流程。

### 5.1 kpack 做咩？

```
1. watch Image CRD
2. 自動 create Build CRD
3. 自動 create build Pod
4. Pod 入面跑 lifecycle
5. Lifecycle 調用 buildpacks
6. 最終 push OCI image 到 registry
```

### 5.2 額外功能

```
- 自動 rebuild (source/buildpack/stack 變)
- 自動 rebase (stack update)
- Cache management (volume / registry)
- Multi-tenancy (namespace 隔離)
- RBAC (邊個 team 可以 build)
- Cosign 簽名 (自動簽名 image)
```

### 5.3 kpack vs Luban CI

```
              kpack                    Luban CI
─────────────────────────────────────────────────────
架構          CRD-based controller     Argo Workflows-based
触发方式      watch CRD 自動 rebuild   webhook / 手動 trigger
Pipeline      冇 (只 build image)      有 (多 stage pipeline)
適用場景      純 image build           完整 CI/CD pipeline
Buildpack     引用 ClusterStore        自帶 custom buildpacks
整合          獨立                      Argo CD + Argo Workflows
```

---

## 6. 三者嘅關係

```
kpack ──引用──▶ ClusterStore ──包含──▶ Buildpackage ──包含──▶ Buildpack
(controller)  (資料庫)          (docker image)        (scripts)
```

### Luban CI 嘅做法

```
Luban CI ──引用──▶ 自帶 buildpacks ──打包成──▶ Buildpackage
(Argo Workflow)   (python-uv)                (docker image)
      │
      └── Argo Workflow → create build Pod → run lifecycle → push image
```

### 類比

```
Buildpack      = 食譜 (點樣煮某道菜)
Buildpackage   = 一本書 (打包好嘅食譜)
kpack          = 自動煮食機 (喺 K8s 上面幫你煮)
pack CLI       = 你喺屋企廚房煮 (自己執行食譜)
Luban CI       = 自動煮食流水線 (喺 K8s 上面幫你煮，仲有成條 production line)
ClusterStore   = 書架 (存放所有書)
Builder        = 借書證 (定義你有權借邊啲書)
Image          = 你嘅借書請求 (我要呢本書)
```

---

## 7. kpack CRD 資源

### 7.1 ClusterStore — Buildpackage 嘅倉庫

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
  # 可以加入 Luban CI 嘅 buildpackage:
  # - image: your-registry/luban-ci/python-uv
```

可以按語言 / team / project 拆分多個 Store。

### 7.2 ClusterStack — Build 嘅基礎 OS

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

# Luban CI 有自己嘅 custom stack:
#   stack/ 目錄入面定義 Ubuntu-based stack
#   支援 uv 嘅 Python runtime
```

### 7.3 ClusterLifecycle — Lifecycle binary

```yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterLifecycle
metadata:
  name: default-lifecycle
spec:
  image: buildpacksio/lifecycle
```

### 7.4 Builder / ClusterBuilder — 整合配置

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
  # 如果用 Luban CI 嘅 python-uv buildpack:
  # - group:
  #   - id: luban-ci/python-uv
```

### 7.5 Image — 你嘅 App 定義

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

### 7.6 Secrets

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

# Luban CI 嘅 buildpack 支援 Service Binding:
#   - netrc (private PyPI mirror credentials)
#   - ca-certificates (self-signed mirror CA)
#   自動偵測 SERVICE_BINDING_ROOT 入面嘅 binding
```

---

## 8. Buildpack 生態

### 主要維護者

| 維護者 | 適用場景 | 狀態 |
|--------|----------|------|
| **Paketo** | 最主流，支援 Java/Node/Go/Python/Ruby/.NET/PHP | 活躍，CNCF 生態 |
| **Google Cloud** | GCP 專屬，整合 Cloud Build | 活躍 |
| **Heroku** | Heroku 平台用 | 活躍 |
| **Luban CI** | Python uv + dbt 整合，支援 private mirror | 活躍 |

### 幾時要自己寫 Buildpack？

```
1. 你有 proprietary framework → 外面冇 buildpack
2. 你有特殊 build 邏輯 → 要加額外 step
3. 語言/工具太新 → 社群仲未有 (例如 Luban CI 嘅 uv)
4. 你要整合內部工具鏈 → private mirror 等 (Luban CI 嘅 Service Binding)
```

### Luban CI 嘅典型 Use Case

```
你嘅 Python app 用 uv 做 package manager:
  → Paketo 冇支援
  → Luban CI 有 python-uv buildpack
  → 直接用就得

你嘅公司有 private PyPI mirror:
  → Paketo 唔知道點 access
  → Luban CI 支援 Service Binding (netrc + CA cert)
  → 自動偵測同使用

你嘅 app 有 dbt project:
  → Paketo 唔知 dbt 係咩
  → Luban CI 自動偵測 + 跑 dbt deps + parse
  → 生成 manifest.json
```

---

## 9. 邊度搵現成 Buildpacks

### Paketo Buildpacks (推薦)

```
官網: https://paketo.io
GitHub: https://github.com/paketo-buildpacks

語言         buildpackage image
─────────────────────────────────────
Java         paketobuildpacks/java
Node.js      paketobuildpacks/nodejs
Go           paketobuildpacks/go
Python       paketobuildpacks/python (pip/poetry/pipenv)
Ruby         paketobuildpacks/ruby
PHP          paketobuildpacks/php
.NET Core    paketobuildpacks/dotnet-core
Rust         paketobuildpacks/rust
```

### Luban CI Buildpacks

```
GitHub: https://github.com/metasync/luban-ci/tree/main/buildpacks

語言         buildpackage                    特色
─────────────────────────────────────────────────────
Python (uv)  luban-ci/python-uv              uv + dbt + private mirror
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

## 10. kpack vs pack CLI vs Luban CI

```
              pack CLI         kpack              Luban CI
──────────────────────────────────────────────────────────────
需要 K8s      唔使              要                  要
需要 Docker   要                唔使 (k8s pod)      唔使 (k8s pod)
自動 rebuild  唔使 (手動)       ✅ 自動             webhook trigger
Pipeline      冇                冇                  ✅ Argo Workflows
Custom BP     要自己打包        放 ClusterStore      自帶
適用場景      本地開發/CI/CD    生產環境 image build  完整 CI/CD pipeline
學習成本      低                高                   中高
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

### Luban CI 快速試玩

```bash
# Luban CI 用 Argo Workflows orchestrate build
# 你嘅 workflow 入面會:
#   1. pull source code
#   2. create build Pod
#   3. Pod 入面跑 luban-ci/python-uv buildpack
#   4. push OCI image 到 registry
```

---

## 11. 自己寫 Buildpack

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

### 真實案例：Luban CI 嘅 python-uv buildpack

```
luban-ci/buildpacks/python-uv/
├── buildpack.toml
├── package.toml
├── README.md
└── bin/
    ├── detect          ← 搵 pyproject.toml / uv.lock / .python-version
    ├── build           ← 安裝 uv + Python + uv sync + dbt
    └── parse_config.py ← 解析 pyproject.toml entry points

Build script 嘅關鍵步驟:
  1. 安裝 uv (version managed + SHA256 checksum)
  2. 安裝 Python (via uv)
  3. uv sync --frozen (裝 dependencies)
  4. 偵測 dbt project → 跑 dbt deps + parse
  5. 自動偵測 entry point (pyproject.toml scripts)
  6. 生成 launch.toml (定義 process)
```

---

## 12. Luban CI 整合

### Luban CI 係咩？

GitOps-based CI system，跑喺 K8s 上面，用 Argo Workflows + Cloud Native Buildpacks。

```
GitHub: https://github.com/metasync/luban-ci

組件:
├── Argo Workflows (pipeline orchestration)
├── Custom Buildpacks (python-uv)
├── Custom Stack (Ubuntu-based)
└── Manifests (K8s YAMLs)
```

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

### Luban CI 同 kpack 嘅分別

```
kpack:
  - 純 image build
  - CRD-based, 自動 rebuild
  - 冇 pipeline concept
  - 適合: 純 build 場景

Luban CI:
  - 完整 CI/CD pipeline
  - Argo Workflows-based
  - 多 stage (test → build → deploy)
  - 自帶 custom buildpacks
  - 適合: 完整 CI/CD 場景
```

### 整合方案

```
方案 A: 用 kpack 做 build
  → kpack 負責 image build
  → Argo CD 負責 deploy
  → 適合: 純 build + deploy 分離

方案 B: 用 Luban CI 做 build
  → Luban CI 負責完整 pipeline
  → Argo CD 負責 deploy
  → 適合: 需要 test stage 嘅場景

方案 C: 兩者並存
  → 簡單 app 用 kpack (自動 rebuild)
  → 複雜 app 用 Luban CI (多 stage pipeline)
  → 按需選擇
```

---

## 13. 快速入門

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

### 加入 Luban CI Buildpack

```bash
# 1. 將 Luban CI 嘅 buildpackage push 到你嘅 registry
cd luban-ci/buildpacks/python-uv
pack buildpack package your-registry/luban-ci/python-uv \
  --path . \
  --format image \
  --publish

# 2. 喺 ClusterStore 入面加呢個 buildpackage
# (更新 store.yaml)
spec:
  sources:
  - image: paketobuildpacks/java
  - image: paketobuildpacks/nodejs
  - image: your-registry/luban-ci/python-uv   # ← 加呢行

# 3. 喺 Builder order 入面加呢個 buildpack
# (更新 builder.yaml)
order:
- group:
  - id: paketo-buildpacks/java
- group:
  - id: paketo-buildpacks/nodejs
- group:
  - id: luban-ci/python-uv          # ← 加呢行

# 4. Apply
kubectl apply -f store.yaml
kubectl apply -f builder.yaml
```

---

## 參考連結

- kpack: https://github.com/buildpacks-community/kpack
- CNB Spec: https://github.com/buildpacks/spec
- Paketo Buildpacks: https://paketo.io
- Google Buildpacks: https://github.com/GoogleCloudPlatform/buildpacks
- Heroku Buildpacks: https://hub.docker.com/r/heroku/buildpacks
- Luban CI: https://github.com/metasync/luban-ci
- Luban CI Buildpacks: https://github.com/metasync/luban-ci/tree/main/buildpacks
- pack CLI: https://github.com/buildpacks/pack

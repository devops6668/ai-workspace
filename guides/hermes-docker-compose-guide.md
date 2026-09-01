# 用 Docker Compose 起 Hermes Agent — 完整指南

> 參考來源：[Hermes Agent 官方 Docker 文檔](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
> 日期：2026-09-01

---

## 目錄

1. [概述](#1-概述)
2. [前置條件](#2-前置條件)
3. [快速開始（3 步搞定）](#3-快速開始3-步搞定)
4. [docker-compose.yml 詳解](#4-docker-composeyml-詳解)
5. [連接本地推理伺服器（Ollama / vLLM 等）](#5-連接本地推理伺服器ollama--vllm-等)
6. [啟用 Dashboard](#6-啟用-dashboard)
7. [API Server 設定](#7-api-server-設定)
8. [聲音 / 語音功能](#8-聲音--語音功能)
9. [瀏覽器自動化](#9-瀏覽器自動化)
10. [資源限制建議](#10-資源限制建議)
11. [常用操作](#11-常用操作)
12. [日誌位置](#12-日誌位置)
13. [升級方法](#13-升級方法)
14. [Multi-Profile 支援](#14-multi-profile-支援)
15. [Multi-Agent 玩法](#15-multi-agent-玩法)
16. [實戰：每個 Agent 一個 Docker + WhatsApp + WeChat + 廣東話](#16-實戰每個-agent-一個-docker--whatsapp--wechat--廣東話)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. 概述

Hermes Agent 有兩種 Docker 用法：

| 用途 | 說明 |
|------|------|
| **Hermes 跑在 Docker 內**（本頁重點） | 整個 agent 跑喺 container 裏面 |
| **Docker 做 terminal backend** | Agent 跑喺 host，但執行命令時開一個 Docker sandbox |

Container 係 **stateless** 嘅——所有用戶數據（config、API keys、sessions、skills、memories）都喺 host 嘅 `~/.hermes/` 目錄，透過 volume mount 入去 `/opt/data`。升級時拉新 image 就得，唔會冇咗設定。

---

## 2. 前置條件

- Docker Engine (20.10+) 同 Docker Compose V2
- Git（如果要 build from repo）
- 已經有一個 LLM provider 嘅 API key（OpenRouter / Anthropic / OpenAI / 自建等）

---

## 3. 快速開始（3 步搞定）

### Step 1: 首次設定（setup wizard）

如果你已經有 `~/.hermes/` 目錄（例如之前已經裝過 Hermes），可以跳過 `mkdir`，直接跑 setup wizard：

```bash
# 如果 ~/.hermes 仲未有，先建目錄
# mkdir -p ~/.hermes

docker run -it --rm \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent:latest setup
```

呢個會開 setup wizard，問你 API key 同 model 設定。做完一次就得。

> 提示：可以直接 `hermes setup --portal`（如果用 Nous Portal）。

### Step 2: 複製 docker-compose.yml

建立一個工作目錄，然後建立 `docker-compose.yml`（見下方[第 4 節](#4-docker-composeyml-詳解)）。

### Step 3: 啟動

```bash
HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose up -d
```

搞掂！Gateway 會自動開機重啟（`restart: unless-stopped`）。

---

## 4. docker-compose.yml 詳解

### 最小版本（只有 gateway）

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8642:8642"       # Gateway API (OpenAI-compatible)
    volumes:
      - ~/.hermes:/opt/data
```

### 完整版（gateway + dashboard）

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host          # 直接用 host network（所有 port 都通）
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      # 如需對外暴露 API Server，取消下面兩行註釋：
      # - API_SERVER_HOST=0.0.0.0
      # - API_SERVER_KEY=${API_SERVER_KEY}
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "2.0"

  dashboard:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    network_mode: host
    depends_on:
      - hermes
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    command: ["dashboard", "--host", "127.0.0.1", "--no-open"]
```

### 各個重要設定解釋

| 設定 | 說明 |
|------|------|
| `network_mode: host` | Container 直接用 host network，所有 port 都暴露喺 host。最簡單但要留意安全 |
| `volumes: ~/.hermes:/opt/data` | 所有 Hermes 數據都喺呢個 mount。**永遠唔好俾兩個 container 共用同一個 data dir** |
| `restart: unless-stopped` | 除非手動 `docker stop`，否則自動重啟 |
| `command: ["gateway", "run"]` | 啟動 gateway 模式（支援 Telegram/Discord/Slack/WhatsApp 等） |
| `HERMES_UID / HERMES_GID` | Container 入面嘅 `hermes` 用戶會被 remap 去呢個 UID/GID，確保 host 上嘅檔案權限正確 |
| `deploy.resources.limits` | Container 嘅 memory 同 CPU 上限 |

### 如果唔用 host network

可以用 port mapping：

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8642:8642"
      - "9119:9119"       # Dashboard
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
```

---

## 5. 連接本地推理伺服器（Ollama / vLLM 等）

### 方法 A: Docker Compose（推薦）

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    volumes:
      - ~/.ollama:/root/.ollama
    ports:
      - "11434:11434"

  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    # 用 service name 做 hostname
```

喺 Hermes 嘅 `config.yaml` 設定：

```yaml
model:
  provider: custom
  model: llama3.2           # 你 Ollama 裏面嘅 model 名
  base_url: http://ollama:11434
  api_key: "none"
```

### 方法 B: Host 網絡

如果 host 上面已經有 Ollama 跑緊：

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    network_mode: host        # 咁就可以直接連 localhost:11434
    command: ["gateway", "run"]
    volumes:
      - ~/.hermes:/opt/data
```

`config.yaml`：

```yaml
model:
  provider: custom
  model: llama3.2
  base_url: http://localhost:11434
  api_key: "none"
```

### 驗證連接

```bash
docker exec hermes curl -s http://localhost:11434/api/tags
```

---

## 6. 啟用 Dashboard

加 `HERMES_DASHBOARD=1` 環境變數：

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_DASHBOARD=1
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
```

訪問：`http://localhost:9119`

### Dashboard 安全設定

Dashboard 在非 loopback bind 時需要認證。幾個選擇：

| 方式 | 環境變數 |
|------|----------|
| Username/Password | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` |
| Nous Portal OAuth | `HERMES_DASHBOARD_OAUTH_CLIENT_ID` |
| 自建 OIDC | `HERMES_DASHBOARD_OIDC_ISSUER` + `HERMES_DASHBOARD_OIDC_CLIENT_ID` |

如果只係 local 用，可以用 `--host 127.0.0.1`（上面嘅 compose 已經咁設咗）。

---

## 7. API Server 設定

API Server 係 OpenAI-compatible 嘅 API 端口（預設 8642），可以用嚟對接 Open WebUI、LobeChat 等。

要啟用：

```yaml
environment:
  - API_SERVER_ENABLED=true
  - API_SERVER_HOST=0.0.0.0
  - API_SERVER_KEY=your-secret-key-here
  - API_SERVER_CORS_ORIGINS='*'
```

生成 secure key：

```bash
openssl rand -hex 32
```

> ⚠️ 開放 API Server 到 0.0.0.0 有安全風險，建議用 reverse proxy + TLS。

---

## 8. 聲音 / 語音功能

如果需要喺 container 入面用語音功能，要 mount PulseAudio socket（Linux desktop only）：

```yaml
services:
  hermes:
    build:
      context: .
      dockerfile: Dockerfile.audio
    image: hermes-agent-audio
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    volumes:
      - ~/.hermes:/opt/data
      - /run/user/${HERMES_UID}/pulse:/run/user/${HERMES_UID}/pulse
      - ~/.config/pulse/cookie:/tmp/pulse-cookie:ro
      - ./asound.conf:/etc/asound.conf:ro
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      - XDG_RUNTIME_DIR=/run/user/${HERMES_UID}
      - PULSE_SERVER=unix:/run/user/${HERMES_UID}/pulse/native
      - PULSE_COOKIE=/tmp/pulse-cookie
```

需要額外建立 `asound.conf`：

```
pcm.!default {
    type pulse
    hint { show on }
}
ctl.!default {
    type pulse
}
```

同埋 `Dockerfile.audio`：

```dockerfile
FROM nousresearch/hermes-agent:latest
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends libasound2-plugins \
    && rm -rf /var/lib/apt/lists/*
```

---

## 9. 瀏覽器自動化

Playwright 需要 shared memory。加 `--shm-size=1g`：

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    volumes:
      - ~/.hermes:/opt/data
    shm_size: "1g"           # ← 呢個
```

---

## 10. 資源限制建議

| 資源 | 最低 | 建議 |
|------|------|------|
| Memory | 1 GB | 2–4 GB |
| CPU | 1 core | 2 cores |
| Disk（data volume） | 500 MB | 2+ GB |

> 瀏覽器自動化係最食 memory 嘅功能，唔用嘅話 1 GB 夠用。

---

## 11. 常用操作

```bash
# 啟動
HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose up -d

# 睇 log
docker compose logs -f

# 互動 CLI chat（直接對話）
docker run -it --rm \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent:latest

# 喺 running container 入面開 chat
docker exec -it hermes /opt/hermes/.venv/bin/hermes

# 停止
docker compose down

# 重啟
docker compose restart

# 睇 resource usage
docker stats hermes

# 檢查健康狀態
docker logs --tail 50 hermes

# 執行 hermes 命令
docker exec hermes hermes doctor
docker exec hermes hermes status --all
docker exec hermes hermes config
```

---

## 12. 日誌位置

| 來源 | 主機位置 |
|------|----------|
| Gateway log（per-profile） | `~/.hermes/logs/gateways/default/current` |
| Boot reconciler | `~/.hermes/logs/container-boot.log` |
| General logs | `~/.hermes/logs/agent.log`、`errors.log` |

實時 log：
```bash
docker logs -f hermes
# 或者直接睇 host 上嘅 rotated files
tail -F ~/.hermes/logs/gateways/default/current
```

---

## 13. 升級方法

```bash
# 拉最新 image
docker compose pull

# 重啟（s6 會自動 migrage config）
docker compose up -d
```

如果需要跳過 auto migration：
```yaml
environment:
  - HERMES_SKIP_CONFIG_MIGRATION=1
```

---

## 14. Multi-Profile 支援

Hermes 支援多個 profile（獨立嘅 config、skills、memories、sessions）。

**推薦做法：一個 container 入面跑多個 profile**（s6 supervisor 管理）：

```bash
# 建立新 profile
docker exec hermes hermes profile create coder

# 啟動特定 profile 嘅 gateway
docker exec hermes hermes -p coder gateway start

# 停止
docker exec hermes hermes -p coder gateway stop

# 狀態
docker exec hermes hermes -p coder gateway status
```

如果需要**完全隔離**（獨立 container、獨立資源限制）：

```yaml
services:
  hermes-work:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-work
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8642:8642"
    volumes:
      - ~/.hermes-work:/opt/data

  hermes-personal:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-personal
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8643:8642"
    volumes:
      - ~/.hermes-personal:/opt/data
```

> ⚠️ 永遠唔好俾兩個 container 共用同一個 `~/.hermes` 目錄！

---

## 15. Multi-Agent 玩法

Hermes 有兩層 multi-agent 能力：**Bot Mode**（多個獨立 agent）同 **Subagent Delegation**（parent agent 分派 subtask 畀 child agents）。

### 15.1 Bot Mode — 多個 Named Agents

每個 Bot 就係一個 Hermes profile——獨立嘅 config、model、memory、skills、sessions。

#### 建立 Bot

```bash
# 建立新 profile（= 新 Bot）
docker exec hermes hermes profile create coder
docker exec hermes hermes profile create researcher

# 查看所有 profiles
docker exec hermes hermes profile list
```

#### 每個 Bot 用唔同 Model

每個 profile 有獨立嘅 `config.yaml`：

```bash
# 設定 coder 用 deepseek
docker exec hermes hermes -p coder model

# 或者直接 edit profile 嘅 config
docker exec hermes hermes -p coder config edit
```

喺 profile 嘅 `~/.hermes/profiles/coder/config.yaml`：

```yaml
model:
  provider: openrouter
  model: deepseek/deepseek-coder
```

#### 每個 Bot 用唔同 Skills

```bash
# coder profile 裝 coding skills
docker exec hermes hermes -p coder skills install official/devops/docker-management

# researcher profile 裝 research skills
docker exec hermes hermes -p researcher skills install official/research/arxiv-search
```

#### Bot 之間傾偈（Group Chat）

Bot Mode 支援 Bot-to-Bot messaging——多個 Bot 可以喺同一個 group chat 入面合作：

```
┌─────────────────────────────────────┐
│  Group Chat: "project-alpha"        │
│                                     │
│  @coder: 我幫你寫咗 API handler     │
│  @researcher: 我搵到三個方案比較    │
│  @default: 多謝你哋，我整合返        │
└─────────────────────────────────────┘
```

#### 喺 Docker Compose 入面用 Bot Mode

Bot Mode 喺同一個 container 入面跑（s6 supervisor 管理），唔需要額外 container：

```yaml
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      - HERMES_DASHBOARD=1
```

所有 Bot 都喺同一個 container 入面，透過 `hermes profile create` 建立。s6 會自動管理每個 profile 嘅 gateway lifecycle。

#### Bot Mode 常用命令

```bash
# 列出所有 bots
docker exec hermes hermes profile list

# 同特定 bot chat
docker exec hermes hermes -p coder chat

# 查看 bot 嘅 cron routines
docker exec hermes hermes cron list

# 刪除 bot
docker exec hermes hermes profile delete coder
```

---

### 15.2 Subagent Delegation — 並行工作分派

`delegate_task` 讓 parent agent 開出隔離嘅 child agents，每個 child 有自己嘅 context、terminal session、同 toolset。Child 只有 final summary 會返到 parent。

#### 用途

| 適合 Delegate | 唔適合 Delegate |
|---------------|-----------------|
| Reasoning-heavy tasks（debug、code review、research） | 單一 tool call |
| 會爆 context window 嘅中間數據 | 需要用戶互動嘅 task |
| 多個獨立工作同時跑 | 簡單嘅 file edit |

#### 單一 Task

```
幫我 review /home/user/project/src/auth/ 嘅安全性，
搵 SQL injection、JWT 問題、password handling 問題，
搵到就修，然後跑 test。
```

Hermes 會自動用 `delegate_task` 分派。

#### 並行 Batch（最多 3 個 child 同時跑）

```
同時 research 呢三個 topic：
1. WebAssembly 喺 browser 以外嘅使用
2. RISC-V server chip 嘅 adoption
3. Quantum computing 嘅實際應用
```

Hermes 會開 3 個 child agents 同時做，做完自動整合。

#### Delegate 配置

喺 `~/.hermes/config.yaml`（或者 container 入面嘅 `/opt/data/config.yaml`）：

```yaml
delegation:
  max_iterations: 50        # 每個 child 最多幾多 tool call turns（default: 50）
  max_concurrent_children: 3  # 同時最多幾多個 child（default: 3）
  max_spawn_depth: 1         # 幾多層 nested delegation（default: 1 = flat）
  orchestrator_enabled: true  # child 可唔可以再 delegate

  # 可以指定 child 用唔同嘅 model（慳錢用便宜 model）
  model: "google/gemini-flash-2.0"
  provider: "openrouter"

  # 或者用 local model
  # model: "qwen2.5-coder"
  # base_url: "http://localhost:1234/v1"
  # api_key: "local-key"
```

#### 平行 30 Workers 嘅設定

```yaml
delegation:
  max_concurrent_children: 30
  max_spawn_depth: 2          # 咁 orchestrator child 可以再開 worker
```

#### Child Agent 嘅限制

- 冇 `clarify`（唔可以問用戶問題）
- 冇 `memory`（唔可以改 persistent memory）
- 冇 `cronjob`（唔可以開 cron）
- 冇 `send_message`
- 可以用 `execute_code`
- 繼承 parent 嘅 toolsets

---

### 15.3 獨立 Data Directory（唔攪亂現有 agent）

如果你已經有一個 `~/.hermes/` 喺跑緊，最安全嘅做法係用**獨立嘅 data folder**：

```bash
# 建一個全新嘅 data directory
mkdir -p ~/.hermes-worker1

# 首次設定呢個 worker
docker run -it --rm \
  -v ~/.hermes-worker1:/opt/data \
  nousresearch/hermes-agent:latest setup
```

咁呢個 worker 有自己嘅 `config.yaml`、`.env`、sessions、skills、memories——同你原本嘅 `~/.hermes/` 完全隔離，互不干擾。

---

### 15.4 完整 Multi-Agent Docker Compose 範例

#### 方案 A：共用 Data Directory（s6 管理多個 Bots）

同一個 container 入面用 profile 分 Bots，全部喺 `~/.hermes/`：

```yaml
# docker-compose.yml — Multi-Agent Hermes（共用 data dir）
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      - HERMES_DASHBOARD=1
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "2.0"

  dashboard:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    network_mode: host
    depends_on:
      - hermes
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    command: ["dashboard", "--host", "127.0.0.1", "--no-open"]
```

啟動後建立 Bots：
```bash
docker exec hermes hermes profile create coder
docker exec hermes hermes profile create researcher
```

#### 方案 B：獨立 Data Directory（完全隔離，推薦唔想攪亂現有 agent）

每個 worker 有自己嘅 `~/.hermes-workerN/`，完全獨立：

```yaml
# docker-compose.yml — Multi-Agent Hermes（獨立 data dirs）
#
# 每個 service 用唔同嘅 data folder
# 互不干擾，可以 independently 升級、備份、刪
#
services:
  # 你原本嘅 agent（唔動佢）
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
      - HERMES_DASHBOARD=1

  # Worker 1：專做 coding
  hermes-worker1:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-worker1
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8643:8642"
    volumes:
      - ~/.hermes-worker1:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    deploy:
      resources:
        limits:
          memory: 2G

  # Worker 2：專做 research
  hermes-worker2:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-worker2
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8644:8642"
    volumes:
      - ~/.hermes-worker2:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    deploy:
      resources:
        limits:
          memory: 2G

  # Dashboard（共用，可以睇所有 worker）
  dashboard:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-dashboard
    restart: unless-stopped
    network_mode: host
    depends_on:
      - hermes
    volumes:
      - ~/.hermes:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-10000}
      - HERMES_GID=${HERMES_GID:-10000}
    command: ["dashboard", "--host", "127.0.0.1", "--no-open"]
```

首次設定每個 worker：
```bash
docker run -it --rm -v ~/.hermes-worker1:/opt/data nousresearch/hermes-agent:latest setup
docker run -it --rm -v ~/.hermes-worker2:/opt/data nousresearch/hermes-agent:latest setup
```

#### 兩個方案比較

| | 方案 A（共用 data dir） | 方案 B（獨立 data dirs） |
|---|---|---|
| 隔離程度 | Profile 級別（config/memory/sessions 分開） | Container 級別（完全獨立） |
| 資源隔離 | 共用 container 嘅 memory/CPU limit | 每個 worker 獨立 limit |
| 備份 | 一個 `~/.hermes/` 搞掂 | 每個 worker 獨立備份 |
| 升級 | 一個 `docker compose pull` 搞掂 | 同左 |
| 適合場景 | 同一個人嘅多個 specialist bots | 不同用途 / 不同人 / 需要隔離 |
| **唔攪亂現有 agent** | ✅ profile 自己建自己嘅 | ✅✅ 完全唔掂現有 `~/.hermes/` |

> ⚠️ 唔好用 `network_mode: host` 同時跑多個 gateway，port 會撞。
> 用 port mapping 分開，或者只有一個用 host mode。

---

### 15.5 多 Container 完全隔離方案（進階）

如果需要**獨立 image 版本**（例如一個跑 latest、一個跑 stable）：

```yaml
services:
  hermes-stable:
    image: nousresearch/hermes-agent:1.0.0    # pin 版本
    container_name: hermes-stable
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8642:8642"
    volumes:
      - ~/.hermes-stable:/opt/data

  hermes-latest:
    image: nousresearch/hermes-agent:latest    # 跟 latest
    container_name: hermes-latest
    restart: unless-stopped
    command: ["gateway", "run"]
    ports:
      - "8643:8642"
    volumes:
      - ~/.hermes-latest:/opt/data
```

---

## 16. 實戰：每個 Agent 一個 Docker + WhatsApp + WeChat + 廣東話

呢節係 Paul 嘅具體需求：每個 agent 獨立 container，連 WhatsApp 同 WeChat，識講廣東話，各有職責。

### 16.1 架構總覽

```
┌──────────────────────────────────────────────────────────┐
│  Host Machine                                            │
│                                                          │
│  ┌─────────────────┐  ┌─────────────────┐               │
│  │  hermes-agent-a  │  │  hermes-agent-b  │  ...         │
│  │  (container)     │  │  (container)     │               │
│  │                  │  │                  │               │
│  │  WhatsApp: 号碼A  │  │  WhatsApp: 号碼B  │               │
│  │  WeChat:  帳號A   │  │  WeChat:  帳號B   │               │
│  │  職責:  coding    │  │  職責:  research  │               │
│  │  語言:  廣東話    │  │  語言:  廣東話    │               │
│  └─────────────────┘  └─────────────────┘               │
│                                                          │
│  ~/.hermes-agent-a/    ~/.hermes-agent-b/                │
│  (完全獨立 data dir)    (完全獨立 data dir)                │
└──────────────────────────────────────────────────────────┘
```

**重點：每個 agent 用獨立嘅 `~/.hermes-agent-N/` data directory，WhatsApp session 同 WeChat credentials 都唔會撞。**

---

### 16.2 每個 Agent 需要嘅嘢

| 項目 | 說明 |
|------|------|
| 獨立 data dir | `~/.hermes-agent-a/`、`~/.hermes-agent-b/` |
| 獨立 WhatsApp 號碼 | 每個 agent 一個號碼（Google Voice / 預付 SIM / VoIP） |
| 獨立 WeChat 帳號 | 每個 agent 掃一次 QR 登入 iLink Bot |
| 獨立 SOUL.md | 定義角色 + 廣東話風格 |
| 獨立 config.yaml | model、platform 設定 |
| 獨立 .env | API keys、WhatsApp/WeChat tokens |
| 獨立 port | 如果用 bridge network 要分開 port |

---

### 16.3 語音設定（聽 + 講廣東話）

每個 agent 要裝 STT（聽）同 TTS（講）先可以處理語音訊息。

#### 語音架構

```
用戶發語音訊息 (WhatsApp/WeChat)
        ↓
  STT 轉錄（聽）
  faster-whisper (本地免費) / Groq Whisper (雲端)
        ↓
  Agent 處理（LLM）
        ↓
  TTS 合成（講）
  Edge TTS zh-HK (免費) / ElevenLabs (付費)
        ↓
  回覆語音訊息
```

#### Cantonese 支援一覽

| 功能 | 方案 | 語言 | 費用 |
|------|------|------|------|
| **TTS（講廣東話）** | Edge TTS `zh-HK-WanLungNeural` | 粵語 | 免費 |
| **TTS（講廣東話）** | Edge TTS `zh-HK-HiuMaanNeural`（女聲） | 粵語 | 免費 |
| **STT（聽廣東話）** | faster-whisper local | 自動偵測（會轉做普通話文字） | 免費 |
| **STT（聽廣東話）** | Groq Whisper cloud | 自動偵測 | 免費 tier |

> ⚠️ **STT 限制**：faster-whisper 會將廣東話語音轉錄成**普通話書面文字**（例如「你食咗飯未」會變「你吃飯了嗎」）。呢個係 Whisper 嘅設計限制——佢將粵語歸類為 `zh`。如果需要保留廣東話文字，需要用其他 ASR 引擎（如 FunASR SenseVoice），但 Hermes 未內建支援。
>
> **實際影響**：Agent 聽得明你講咩，但 transcript 會係普通話文字。Agent 仍然會用廣東話回覆（因為 SOUL.md 指定咗）。

#### Edge TTS 廣東話 Voice 選擇

| Voice ID | 性別 | 風格 |
|----------|------|------|
| `zh-HK-HiuMaanNeural` | 女聲 | 友善、正面（**預設**） |
| `zh-HK-HiuGaaiNeural` | 女聲 | 友善、正面 |
| `zh-HK-WanLungNeural` | 男聲 | 友善、正面 |

#### 設定步驟

**Step A: 裝 faster-whisper（STT，免費本地）**

```bash
# 喺 container 入面裝
docker exec hermes-agent-a pip install faster-whisper
```

或者喺 Dockerfile 裝（永久生效）：

```dockerfile
FROM nousresearch/hermes-agent:latest
USER root
RUN pip install faster-whisper
```

**Step B: 設定 config.yaml（STT + TTS）**

```yaml
# ~/.hermes-agent-a/config.yaml

# STT（聽語音）
stt:
  enabled: true
  provider: "local"           # 本地，免費
  local:
    model: "base"             # tiny / base / small / medium / large-v3
    # language: "zh"          # 可選：強制中文（但會影響英文辨識）
    # 留空 = 自動偵測語言

# TTS（講廣東話）
tts:
  provider: "edge"            # Edge TTS，免費
  edge:
    voice: "zh-HK-HiuMaanNeural"   # 廣東話女聲（預設）
    # voice: "zh-HK-WanLungNeural" # 廣東話男聲（擇一）
```

**Step C: 如果用 Groq Whisper（更快更準，雲端）**

```yaml
stt:
  enabled: true
  provider: "groq"
  groq:
    language: ""              # 自動偵測
```

`.env` 加：
```bash
GROQ_API_KEY=your-groq-key   # 免費 tier 夠用
```

**Step D: 完整 .env（語音 + WhatsApp + WeChat）**

```bash
# ~/.hermes-agent-a/.env

# LLM
OPENROUTER_API_KEY=sk-or-xxxxx

# WhatsApp
WHATSAPP_ENABLED=true
WHATSAPP_MODE=bot
WHATSAPP_ALLOWED_USERS=853XXXXXXXX

# WeChat
WEIXIN_ACCOUNT_ID=agent-a-account-id
WEIXIN_DM_POLICY=open

# STT（如果用 Groq）
GROQ_API_KEY=gsk_xxxxx

# STT fallback（可選，OpenAI Whisper）
# VOICE_TOOLS_OPENAI_KEY=sk-xxxxx

# TTS（Edge TTS 免費，唔需要 key）
```

**Step E: SOUL.md 加語音指令**

喺 SOUL.md 加多一段，確保 agent 明白收到語音訊息時點處理：

```markdown
# 語音處理

- 當你收到語音訊息嘅轉錄文字時，正常回覆就得
- 你嘅回覆會自動被 TTS 轉成語音（廣東話）
- 語音轉錄可能有少少誤差（特別係廣東話轉普通話文字），盡量理解用戶嘅意思
- 如果唔確定用戶講咩，直接問返「你係咪話 XXX？」
```

---

### 16.4 Step-by-Step：用 Docker Compose 管理一切

全部操作都用 `docker compose`，唔需要額外 `docker run`。

#### Step 1: 建 data directory

```bash
mkdir -p ~/.hermes-agent-a
```

#### Step 2: 首次 Setup（interactive）

```bash
# 建好 docker-compose.yml 之後（見 Section 16.7）
cd /path/to/your/compose/dir

# 首次設定（model、API key）
docker compose run --rm agent-a setup
```

#### Step 3: 掃 WhatsApp QR

```bash
docker compose run --rm agent-a whatsapp
```

terminal 會出 QR code，用手機 WhatsApp 掃。完成後 session 自動存入 `~/.hermes-agent-a/platforms/whatsapp/session/`。

#### Step 4: 掃 WeChat QR

```bash
docker compose run --rm agent-a gateway setup
# 選擇 Weixin，跟指示掃 QR
```

credentials 自動存入 `~/.hermes-agent-a/weixin/accounts/`。

#### Step 5: 寫 SOUL.md + config.yaml + .env

（見下方各 Section）

#### Step 6: 正式啟動

```bash
docker compose up -d
```

搞掂！之後所有操作都係 `docker compose` 命令。

#### 之後嘅日常操作

```bash
# 啟動所有 agent
docker compose up -d

# 停止所有
docker compose down

# 重啟
docker compose restart

# 睇 log（所有 agent）
docker compose logs -f

# 睇特定 agent log
docker compose logs -f agent-a

# 重新掃 WhatsApp QR（斷線時）
docker compose run --rm agent-a whatsapp

# 重新掃 WeChat QR（斷線時）
docker compose run --rm agent-a gateway setup

# 裝新 skills
docker compose run --rm agent-a hermes skills install xxx

# 跑 doctor 檢查
docker compose run --rm agent-a hermes doctor
```

> **重點**：`docker compose run --rm` = 一次性互動操作（setup、掃 QR），`docker compose up -d` = 長期跑 gateway。

---

### 16.5 建立 Agent B（重複 Step 1-4）

只需要改 directory 同名字：

```bash
mkdir -p ~/.hermes-agent-b
docker compose run --rm agent-b setup
```

然後建立佢嘅 SOUL.md（唔同角色）。

---

### 16.5.1 實際範例：食店外賣訂單管理 Agent

呢個係第一個 agent 嘅實際設定——一間食店嘅老闆助手，透過 WeChat 管理外賣流程。

#### 工作流程圖

```
客人（WeChat）         阿姐（Agent）          廚師（WeChat）         車手（WeChat）
     │                    │                      │                      │
     │  1. 落單           │                      │                      │
     │ ──────────────────>│                      │                      │
     │                    │                      │                      │
     │  2. 確認訂單       │  3. 轉發訂單         │                      │
     │ <──────────────────│ ────────────────────>│                      │
     │                    │                      │                      │
     │                    │  4. 餐已準備好       │                      │
     │                    │ <────────────────────│                      │
     │                    │                      │                      │
     │  5. 出發通知       │  6. 派單             │                      │
     │ <──────────────────│ ──────────────────────────────────────────>│
     │                    │                      │                      │
     │                    │  7. 車手取餐         │                      │
     │                    │ <──────────────────────────────────────────│
     │  8. 已完成         │                      │                      │
     │ <──────────────────│                      │                      │
```

#### SOUL.md

完整嘅 SOUL.md 喺：`guides/hermes-agent-a-soul.md`

主要設定：
- **身份**：食店老闆助手「阿姐」
- **語言**：廣東話
- **職責**：收訂單 → 通知廚房 → 派單車手 → 通知客人
- **訂單格式**：統一嘅中文格式，方便廚師同車手睇

#### 環境角色分配

| 角色 | WeChat 帳號 | 點樣溝通 |
|------|------------|----------|
| 客人 | 客人自己嘅微信 | DM 落單 |
| 阿姐（Agent） | 食店官方微信 | 收DM + 轉發群組 |
| 廚師 | 廚師自己嘅微信 | 喺群組接訂單 |
| 車手 | 車手自己嘅微信 | 喺群組接派單 |

#### WeChat 群組設定建議

> ⚠️ **重要發現：iLink Bot 限制**
>
> QR login 建立嘅 iLink bot identity（`xxx@im.bot`）只係帳號自己嘅「自己同自己傾偈」功能。
> **其他人搵唔到呢個 bot，冇辦法 DM。**
>
> 如果需要客人可以 DM bot 落單，必須用以下方案之一：
>
> | 方案 | 說明 | 適合做食店 bot？ |
> |------|------|-----------------|
> | **WeCom（企業微信）** | 開 WeCom bot，有獨立 bot ID，其他人可以搜到同 DM | ✅ 推薦 |
> | **微信公眾號** | 開服務號/訂閱號，可以接收訊息 | ✅ 但申請較複雜 |
> | **WhatsApp** | 一個號碼一個 bot，客人可以直接 DM | ✅ 適合 |
>
> 以下係 iLink bot 仍然可以做嘅用途：
> - 做自己嘅個人助手（自己同自己傾偈）
> - 喺群組入面做 bot（但 iLink 群組支援有限）

```bash
cat > ~/.hermes-agent-b/SOUL.md << 'EOF'
# 身份

你係一個專業嘅研究助手 agent。你嘅名叫做「阿 Research」。

# 語言

- 所有回覆都用**繁體中文 / 廣東話**
- 語氣親切、有禮
- 引用 paper / article 時可以用英文原文

# 性格

- 好學、鍾意深挖
- 會主動搵更多相關資料
- 解釋複雜概念時會用淺白嘅比喻

# 職責

- 搜尋同整理資料
- 解釋論文同技術文章
- 幫手做市場調查
- 整理 meeting notes

# 邊啲唔做

- 唔會執行危險嘅 server 操作
- 唔會修改 code
EOF
```

---

### 16.6 SOUL.md 廣東話範例合集

#### 範例 A：DevOps 工程師

```markdown
你係一個資深 DevOps 工程師 agent。講嘢直接、實際，唔講廢話。
所有回覆用廣東話，技術術語可以用英文。
語氣好似 senior 同事教你嘢咁。
```

#### 範例 B：研究助手

```markdown
你係一個研究助手。鍾意深挖資料，解釋複雜概念時用淺白嘅比喻。
所有回覆用廣東話，引用原文時保留英文。
語氣親切有禮。
```

#### 範例 C：客服 Agent

```markdown
你係一個客服 agent。好有耐心，永遠唔會發脾氣。
用廣東話回覆，盡量用簡單嘅字眼。
遇到搞唔掂嘅問題，會話「我幫你轉俾同事跟進」。
```

#### 範例 D：個人助手

```markdown
你係一個個人助手。記性好，會記得用戶嘅偏好。
用廣東話溝通，語氣好似朋友咁自然。
會主動提醒重要嘅事。
```

---

### 16.7 完整 docker-compose.yml（多 Agent + Dashboard + 語音）

#### 先建立 Dockerfile（加裝 faster-whisper）

```dockerfile
# Dockerfile.heroku-agent-voice
FROM nousresearch/hermes-agent:latest
USER root
RUN pip install --no-cache-dir faster-whisper && \
    rm -rf /root/.cache/pip
```

#### docker-compose.yml

```yaml
# docker-compose.yml — Multi-Agent WhatsApp + WeChat + Cantonese Voice
#
# 使用方法：
#   1. 先建好 Dockerfile.heroku-agent-voice
#   2. 為每個 agent 跑 setup + whatsapp + weixin（interactive QR scan）
#   3. HERMES_UID=$(id -u) HERMES_GID=$(id -g) docker compose up -d
#
services:
  agent-a:
    build:
      context: .
      dockerfile: Dockerfile.heroku-agent-voice
    image: hermes-agent-voice
    container_name: hermes-agent-a
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes-agent-a:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-1000}
      - HERMES_GID=${HERMES_GID:-1000}
    deploy:
      resources:
        limits:
          memory: 3G
          cpus: "2.0"

  agent-b:
    image: hermes-agent-voice
    container_name: hermes-agent-b
    restart: unless-stopped
    command: ["gateway", "run"]
    network_mode: host
    volumes:
      - ~/.hermes-agent-b:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-1000}
      - HERMES_GID=${HERMES_GID:-1000}
    deploy:
      resources:
        limits:
          memory: 3G
          cpus: "2.0"

  dashboard:
    image: hermes-agent-voice
    container_name: hermes-dashboard
    restart: unless-stopped
    network_mode: host
    depends_on:
      - agent-a
      - agent-b
    volumes:
      - ~/.hermes-agent-a:/opt/data
    environment:
      - HERMES_UID=${HERMES_UID:-1000}
      - HERMES_GID=${HERMES_GID:-1000}
    command: ["dashboard", "--host", "127.0.0.1", "--no-open"]
```

> **語音訊息流程**：WhatsApp/WeChat 語音 → STT 轉錄 → Agent 處理 → TTS 合成 → 回覆語音
> 呢個 flow 唔需要 PulseAudio/microphone（嗰個只係 CLI voice mode 先用）。

---

### 16.8 各 Agent 嘅 .env 範例

#### Agent A (.env)

```bash
# ~/.hermes-agent-a/.env

# LLM
OPENROUTER_API_KEY=sk-or-xxxxx

# WhatsApp
WHATSAPP_ENABLED=true
WHATSAPP_MODE=bot
WHATSAPP_ALLOWED_USERS=853XXXXXXXX

# WeChat
WEIXIN_ACCOUNT_ID=agent-a-account-id
WEIXIN_DM_POLICY=open
```

#### Agent B (.env)

```bash
# ~/.hermes-agent-b/.env

# LLM（可以用唔同 model）
OPENROUTER_API_KEY=sk-or-xxxxx

# WhatsApp（第二個號碼）
WHATSAPP_ENABLED=true
WHATSAPP_MODE=bot
WHATSAPP_ALLOWED_USERS=853XXXXXXXX

# WeChat（第二個微信帳號）
WEIXIN_ACCOUNT_ID=agent-b-account-id
WEIXIN_DM_POLICY=open
```

---

### 16.9 常見問題

| 問題 | 解決方法 |
|------|----------|
| WhatsApp 掃唔到 QR code | 確保 terminal 有 60+ columns，支援 Unicode。可以試 `docker exec -it hermes-agent-a hermes whatsapp` |
| WeChat 掃唔到 QR | 裝 messaging extra：`docker exec hermes-agent-a pip install aiohttp cryptography` |
| 兩個 agent 嘅 WhatsApp session 衝突 | 確保用獨立 data dir，唔好共用同一個 `~/.hermes/` |
| Agent 講咗英文唔係廣東話 | 檢查 SOUL.md 有冇寫清楚「用廣東話回覆」。SOUL.md 係 system prompt slot #1，影響最大 |
| Agent 回覆太慢 | 檢查 model 速度。可以用 `delegation.model` 指定快嘅 model 做 subtask |
| Dashboard 淨係睇到一個 agent | Dashboard 預設跟 volume mount 嘅 data dir。多個 agent 要用 Desktop app 嘅 Connections 功能 |
| Container restart 之後 WhatsApp 斷咗 | 正常——Baileys session 可能要重連。`docker logs` 睇有冇 reconnection error，必要時重新掃 QR |
| 語音訊息聽唔到（STT 唔 work） | 確認 `faster-whisper` 已裝：`docker exec hermes pip install faster-whisper`。第一次用會 download model（~150MB） |
| TTS 講嘢唔係廣東話 | 檢查 `config.yaml` 嘅 `tts.edge.voice` 有冇設 `zh-HK-HiuMaanNeural` |
| STT 轉錄出嚟係普通話文字 | 正常——Whisper 將粵語歸類為 `zh`，會轉做普通話書面文字。Agent 仍然會用廣東話回覆 |
| 語音訊息太長被截斷 | 調高 `voice.max_recording_seconds`（預設 120 秒） |
| Edge TTS 講嘢好機械 | 可以試 ElevenLabs（付費但自然得多），設定 `tts.provider: elevenlabs` |
| WeChat iLink bot 搵唔到 / 收唔到 DM | iLink bot 只係帳號自己嘅「自己同自己傾偈」，其他人搵唔到。改用 WeCom 或 WhatsApp |

---

## 17. Troubleshooting

| 問題 | 解決方法 |
|------|----------|
| Container 即刻退出 | `docker logs hermes` 睇報錯。可能 config 有問題，先跑 `docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent:latest doctor` |
| Permission denied | 確認 `HERMES_UID` / `HERMES_GID` 係正確嘅 host user UID/GID |
| 瀏覽器工具唔 work | 加 `shm_size: "1g"` |
| Gateway 連唔到 | `docker restart hermes`。如果係 network 問題，試用 `network_mode: host` |
| Container 入面 curl 連唔到推理伺服器 | 如果用 bridge network，要連 Docker service name（如 `http://ollama:11434`），唔係 `localhost` |
| `hermes: command not found` | 用完整路徑 `/opt/hermes/.venv/bin/hermes`，或者確認 image 版本正確 |

---

## 附錄：完整 .env 範例

```bash
# ~/.hermes/.env

# LLM Provider keys（擇一）
OPENROUTER_API_KEY=sk-or-xxxxx
ANTHROPIC_API_KEY=sk-ant-xxxxx
# OPENAI_API_KEY=sk-xxxxx

# Messaging platforms（按需）
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
DISCORD_TOKEN=xxxxx

# API Server（按需）
# API_SERVER_ENABLED=true
# API_SERVER_HOST=0.0.0.0
# API_SERVER_KEY=xxxxxxxxxxxxxxxxxxxxxxxx
```

---

> 文檔版本：2026-09-01
> 官方文檔：https://hermes-agent.nousresearch.com/docs/user-guide/docker
> GitHub repo：https://github.com/NousResearch/hermes-agent

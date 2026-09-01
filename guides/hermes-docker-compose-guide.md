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
15. [Troubleshooting](#15-troubleshooting)

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

### Step 1: 建立 data 目錄 + 首次設定

```bash
mkdir -p ~/.hermes

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

## 15. Troubleshooting

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

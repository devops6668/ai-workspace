# Linux on Android - Termux 桌面環境及 Home Assistant 安裝指南

> 來源: https://github.com/mayukh4/linux-android

## 目錄

- [簡介](#簡介)
- [系統要求](#系統要求)
  - [硬件](#硬件)
  - [軟件](#軟件)
- [安裝步驟](#安裝步驟)
  - [步驟一 — 安裝所需 Apps](#步驟一--安裝所需-apps)
  - [步驟二 — 預先升級 Termux](#步驟二--預先升級-termux)
  - [步驟三 — 下載並執行腳本](#步驟三--下載並執行腳本)
  - [步驟四 — 啟動桌面](#步驟四--啟動桌面)
- [桌面環境選擇](#桌面環境選擇)
- [安裝組件](#安裝組件)
- [GPU 加速](#gpu-加速)
- [SSH 遠端連接](#ssh-遠端連接)
  - [首次設定 SSH](#首次設定-ssh)
  - [從電腦連接](#從電腦連接)
  - [檔案傳輸](#檔案傳輸)
  - [SSH 設定檔](#ssh-設定檔)
  - [保持 SSH 運行](#保持-ssh-運行)
  - [SSH 金鑰認證](#ssh-金鑰認證)
- [Windows 應用支援 (Wine)](#windows-應用支援-wine)
- [Home Assistant 智能家居伺服器](#home-assistant-智能家居伺服器)
  - [安裝 Home Assistant](#安裝-home-assistant)
  - [Home Assistant 限制](#home-assistant-限制)
  - [訪問控制面板](#訪問控制面板)
  - [添加設備](#添加設備)
- [進階設定](#進階設定)
- [常見問題排解](#常見問題排解)

---

## 簡介

將任何舊 Android 手機變成 **Linux 桌面** 或 **智能家居伺服器** — 無需電腦、無需 Root、無需雲端。只需 [Termux](https://termux.dev)。

兩個安裝路徑：

| | Linux 桌面 | 智能家居伺服器 |
|---|---|---|
| **用途** | 完整 GUI 桌面環境 | Home Assistant 控制 WiFi 設備 |
| **適用場景** | 學習 Linux、Python 開發、SSH 伺服器、上網、媒體 | 控制智能燈、智能插座、自動化、儀表板 |
| **腳本** | `bash termux-linux-setup.sh` | `bash setup-homeassistant.sh` |
| **時間** | 10–30 分鐘 | 15–45 分鐘 |

兩者可同時運行，互不衝突。

---

## 系統要求

### 硬件

- Android 手機，**arm64（64 位元）** 處理器
- **3GB+ RAM** 建議（KDE Plasma 需要 4GB+）
- **5–10GB** 可用空間（安裝 Wine 則需要更多）
- **Qualcomm Snapdragon** 晶片最佳 — GPU 加速效果最好（Turnip/Adreno）

### 軟體

| App | 下載來源 |
|---|---|
| **Termux** | [F-Droid](https://f-droid.org/en/packages/com.termux/) — **不要用 Play Store 版本** |
| **Termux-X11** | [GitHub Releases](https://github.com/termux/termux-x11/releases) — 下載最新 `.apk` |

> **注意：** 不需要 Root 或刷機。可在原廠 Android 上運行。

---

## 安裝步驟

### 步驟一 — 安裝所需 Apps

從 F-Droid 安裝 **Termux**，從 GitHub Releases 安裝 **Termux-X11**。授予兩個 App 所有權限。

### 步驟二 — 預先升級 Termux

> **重要 — 請先執行此步驟**

```bash
termux-wake-lock pkg upgrade -y
```

- `termux-wake-lock` 防止 Termux 在螢幕關閉時被 Android 殺死
- `pkg upgrade` 避免 `libpcre` 和 `libandroid-selinux` 衝突導致的已知崩潰

### 步驟三 — 下載並執行腳本

**Linux 桌面：**

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/termux-linux-setup.sh
chmod +x termux-linux-setup.sh
bash termux-linux-setup.sh
```

**Home Assistant：**

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/setup-homeassistant.sh
bash setup-homeassistant.sh
```

腳本會問你選擇哪種桌面環境，以及是否安裝 Wine。完整安裝日誌保存在 `~/termux-setup.log`。

### 步驟四 — 啟動桌面

```bash
bash ~/start-linux.sh
```

然後打開手機上的 **Termux-X11** App，Linux 桌面就會顯示。

**停止：**

```bash
bash ~/stop-linux.sh
```

---

## 桌面環境選擇

| # | 桌面環境 | 適用場景 | 資源佔用 |
|---|---|---|---|
| 1 | **XFCE4** *（預設）* | 大多數用戶。快速、可自訂 | 低–中 |
| 輕量級 | **LXQt** | 舊手機或低 RAM 手機（2–3GB） | 極低 |
| 經典 | **MATE** | 傳統桌面風格 | 中 |
| 重型 | **KDE Plasma** | 高性能手機 — Windows 11 風格 | 高 |

不確定就選 **XFCE4**。

---

## 安裝組件

| 組件 | 說明 |
|---|---|
| **Termux-X11** | 顯示伺服器 — 在螢幕上渲染桌面 |
| **桌面環境** | 你的選擇：XFCE4、LXQt、MATE 或 KDE |
| **Mesa / Zink** | 透過 Vulkan 實現 OpenGL — GPU 加速圖形 |
| **Turnip 驅動** | Qualcomm Adreno 開源 Vulkan 驅動（如有） |
| **PulseAudio** | 音訊伺服器 |
| **Firefox** | 完整桌面瀏覽器 |
| **VLC** | 影片和音樂播放器 |
| **Git、wget、curl** | 標準開發工具 |
| **Python 3 + pip** | Python 環境和套件管理器 |
| **OpenSSH** | SSH 伺服器和用戶端 — 遠端連接 |
| **Wine** *（可選）* | 透過 Hangover + Box64 運行 Windows x86 應用 |

---

## GPU 加速

腳本自動使用硬件屬性檢測 GPU（非品牌名稱）。

**Qualcomm Adreno（Snapdragon）：** 開源 **Turnip** Vulkan 驅動 + **Zink**（OpenGL on Vulkan）。接近原生 GPU 效能。

**Mali / 其他 GPU：** 退回 **Zink + SwRast**（軟件 Vulkan）。可運行但建議使用輕量級桌面（XFCE4、LXQt）。

GPU 設定保存在 `~/.config/linux-gpu.sh`，每次 `start-linux.sh` 自動載入。

---

## SSH 遠端連接

OpenSSH 自動安裝。可從同一 WiFi 網絡內的任何電腦 SSH 連接。

### 首次設定 SSH

在 Termux 中（**不要**在桌面內）：

```bash
# 啟動 SSH 伺服器
sshd

# 設定密碼
passwd

# 查詢手機 IP
ip addr show wlan0 | grep 'inet '
```

### 從電腦連接

```bash
ssh your-termux-username@192.168.1.42 -p 8022
```

> **端口 8022** 是 Termux SSH 預設端口（不是標準端口 22）。

在 Termux 中執行 `whoami` 查詢用戶名（通常為 `u0_a123`）。

### 檔案傳輸

```bash
# 電腦 → 手機
scp -P 8022 myfile.txt u0_a123@192.168.1.42:~/

# 手機 → 電腦
scp -P 8022 u0_a123@192.168.1.42:~/somefile.txt ./
```

或使用任何 SFTP 客戶端（FileZilla、Cyberduck），連接相同 IP:8022。

### SSH 設定檔

在電腦 `~/.ssh/config` 中加入：

```
Host myphone
    HostName 192.168.1.42
    User u0_a123
    Port 8022
```

之後只需：

```bash
ssh myphone
```

### 保持 SSH 運行

在 Termux 的 `~/.bashrc` 中加入：

```bash
echo 'sshd 2>/dev/null' >> ~/.bashrc
```

### SSH 金鑰認證

```bash
# 在電腦上生成金鑰
ssh-keygen -t ed25519

# 複製公鑰到手機
ssh-copy-id -p 8022 u0_a123@192.168.1.42
```

---

## Windows 應用支援 (Wine)

使用 **Hangover Wine** + **Box64** 將 Windows x86 調用轉譯為 ARM64。

簡單工具和實用程式通常可用；重型軟體或遊戲可能不支援。

在桌面終端中執行 `winecfg` 進行配置。

---

## Home Assistant 智能家居伺服器

### 安裝 Home Assistant

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/setup-homeassistant.sh
bash setup-homeassistant.sh
```

安裝時間 15–45 分鐘。最長步驟是在 Ubuntu 容器中編譯 Python 依賴項（numpy、cryptography 等）。

**啟動/停止：**

```bash
bash ~/start-homeassistant.sh
bash ~/stop-homeassistant.sh
```

### Home Assistant 限制

- **無 Bluetooth** — HA 無法透過 Termux 存取手機的藍牙
- **無 USB dongle** — Zigbee/Z-Wave USB 棒在無 Root 時不支援
- **無自動發現（mDNS）** — Android 10+ 封鎖 `/proc/net/dev`。必須以 IP 或雲端 API 添加設備
- **無 Docker/Add-ons** — 這是 HA Core，不是 HA OS。核心整合（2000+）正常運作

### 訪問控制面板

在同一 WiFi 網絡內的任何裝置瀏覽器中打開：

```
http://<your-phone-ip>:8123
```

首次啟動需要 5–10 分鐘初始化。首次訪問時創建管理員帳號。

### 添加設備

1. 打開設備配套 App，記錄設備 IP 地址
2. 在 HA 控制面板：**設定 → 設備與服務 → + 添加整合**
3. 搜尋設備整合（如「TP-Link Kasa Smart」）
4. 輸入設備 IP 地址

---

## 進階設定

**自訂 GPU 標誌** — 編輯 `~/.config/linux-gpu.sh`：

```bash
# 強制軟件渲染
export GALLIUM_DRIVER=llvmpipe

# 啟用 Mesa 調試
export MESA_DEBUG=1

# 更改 OpenGL 版本
export MESA_GL_VERSION_OVERRIDE=3.3
```

**Termux 啟動時自動載入桌面** — 在 `~/.bashrc` 中加入：

```bash
# bash ~/start-linux.sh
```

**衝突安全安裝器** — 腳本在每次安裝前檢查 `apt-cache show` 的 `Conflicts` 欄位。可在任何 Termux 環境中安全運行。

**非標準 Termux 路徑** — 所有路徑使用 `$PREFIX`，支援 Android 副帳號安裝的 Termux。

---

## 常見問題排解

| 問題 | 解決方法 |
|---|---|
| **無聲音** | 桌面出現後等待 5–10 秒 — PulseAudio 首次初始化需要時間 |
| **SSH 連接被拒** | 檢查 `ps aux | grep sshd`。若無運行則執行 `sshd`。使用端口 8022，不是 22 |
| **Wine 無法啟動** | 需要先啟動桌面，然後在桌面內的終端中執行 `winecfg` |
| **HA pip install 失敗** | 執行 `proot-distro login ubuntu`，安裝 `python3-dev libffi-dev libssl-dev cargo`，然後重試 |
| **HA 控制面板無法載入** | 首次啟動需要 5–10 分鐘。確認同一 WiFi 網絡。用 `hass -c ~/hass-config` 觀察輸出 |
| **HA「地址已被使用」** | 停止其他實例：`bash ~/stop-homeassistant.sh` 或 `pkill -f "hass -c"` |
| **HA 設備未自動發現** | 預期行為 — Android 封鎖了 mDNS。請手動以 IP 添加或使用雲端整合 |

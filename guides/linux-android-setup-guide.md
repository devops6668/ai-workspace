# Linux on Android - Termux Desktop & Home Assistant Setup Guide

> Source: https://github.com/mayukh4/linux-android

## Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
  - [Hardware](#hardware)
  - [Software](#software)
- [Installation](#installation)
  - [Step 1 - Install Required Apps](#step-1--install-required-apps)
  - [Step 2 - Pre-upgrade Termux](#step-2--pre-upgrade-termux)
  - [Step 3 - Download and Run the Script](#step-3--download-and-run-the-script)
  - [Step 4 - Start Your Desktop](#step-4--start-your-desktop)
- [Desktop Environments](#desktop-environments)
- [What Gets Installed](#what-gets-installed)
- [GPU Acceleration](#gpu-acceleration)
- [SSH Remote Access](#ssh-remote-access)
  - [First-time SSH Setup](#first-time-ssh-setup)
  - [Connect from PC](#connect-from-pc)
  - [File Transfer](#file-transfer)
  - [SSH Config](#ssh-config)
  - [Keep SSH Running](#keep-ssh-running)
  - [SSH Key Auth](#ssh-key-auth)
- [Windows App Support (Wine)](#windows-app-support-wine)
- [Home Assistant - Smart Home Server](#home-assistant--smart-home-server)
  - [Home Assistant Installation](#home-assistant-installation)
  - [Home Assistant Limitations](#home-assistant-limitations)
  - [Accessing the Dashboard](#accessing-the-dashboard)
  - [Adding Devices](#adding-devices)
- [Advanced Notes](#advanced-notes)
- [Troubleshooting](#troubleshooting)

---

## Overview

Turn any old Android phone into a **Linux desktop** or **smart home server** — no PC, no root, no cloud. Just [Termux](https://termux.dev).

Two paths available:

| | Linux Desktop | Smart Home Server |
|---|---|---|
| **What** | Full GUI desktop environment on your phone | Home Assistant hub that controls WiFi devices |
| **Use cases** | Learning Linux, Python dev, SSH server, web browsing, media | Control smart lights/plugs, automation, dashboards |
| **Script** | `bash termux-linux-setup.sh` | `bash setup-homeassistant.sh` |
| **Time** | 10–30 min | 15–45 min |

Both can run on the same phone without conflict.

---

## Requirements

### Hardware

- Android phone with an **arm64 (64-bit)** processor
- **3 GB+ RAM** recommended (4 GB+ for KDE Plasma)
- **5–10 GB** of free storage (more if you install Wine)
- **Qualcomm Snapdragon** chip is ideal — enables best GPU acceleration (Turnip/Adreno)

### Software

| App | Where to Get It |
|---|---|
| **Termux** | [F-Droid](https://f-droid.org/en/packages/com.termux/) — **do NOT use Play Store version** |
| **Termux-X11** | [GitHub Releases](https://github.com/termux/termux-x11/releases) — download latest `.apk` |

> **Note:** Rooting or custom ROMs are NOT required. Works on stock Android.

---

## Installation

### Step 1 — Install Required Apps

Install **Termux** from F-Droid and **Termux-X11** from GitHub releases. Grant both apps any permissions they request.

### Step 2 — Pre-upgrade Termux

> **Important — do this FIRST**

```bash
termux-wake-lock pkg upgrade -y
```

- `termux-wake-lock` keeps Termux alive when screen is off — prevents Android from killing the process mid-install
- `pkg upgrade` prevents a known crash involving `libpcre` and `libandroid-selinux`

### Step 3 — Download and Run the Script

**Linux Desktop:**

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/termux-linux-setup.sh
chmod +x termux-linux-setup.sh
bash termux-linux-setup.sh
```

**Home Assistant:**

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/setup-homeassistant.sh
bash setup-homeassistant.sh
```

The script asks you to choose a desktop environment and whether to install Wine. Full install log saved to `~/termux-setup.log`.

### Step 4 — Start Your Desktop

```bash
bash ~/start-linux.sh
```

Then open the **Termux-X11** app on your phone. Your Linux desktop will appear inside it.

**Stop:**

```bash
bash ~/stop-linux.sh
```

---

## Desktop Environments

| # | Desktop | Best For | Resource Usage |
|---|---|---|---|
| 1 | **XFCE4** *(default)* | Most users. Fast, customizable | Low–Medium |
| 2 | **LXQt** | Old or low-RAM phones (2–3 GB) | Very Low |
| 3 | **MATE** | Classic desktop feel | Medium |
| 4 | **KDE Plasma** | Powerful phones only — Windows 11 style | High |

If unsure, go with **XFCE4**.

---

## What Gets Installed

| Component | Details |
|---|---|
| **Termux-X11** | Display server — renders desktop on screen |
| **Desktop Environment** | Your choice: XFCE4, LXQt, MATE, or KDE |
| **Mesa / Zink** | OpenGL via Vulkan — GPU-accelerated graphics |
| **Turnip driver** | Qualcomm Adreno open-source Vulkan driver (if detected) |
| **PulseAudio** | Audio server |
| **Firefox** | Full desktop web browser |
| **VLC** | Video and audio player |
| **Git, wget, curl** | Standard developer tools |
| **Python 3 + pip** | Python runtime and package manager |
| **OpenSSH** | SSH server and client — remote access from PC |
| **Wine** *(optional)* | Run Windows x86 apps via Hangover + Box64 |

---

## GPU Acceleration

GPU detected automatically using hardware properties (not brand name).

**Qualcomm Adreno (Snapdragon):** Open-source **Turnip** Vulkan driver + **Zink** (OpenGL on Vulkan). Near-native GPU performance.

**Mali / Other GPUs:** Falls back to **Zink + SwRast** (software Vulkan). Functional but lighter desktops (XFCE4, LXQt) strongly recommended.

GPU config saved in `~/.config/linux-gpu.sh`, loaded on every `start-linux.sh`.

---

## SSH Remote Access

OpenSSH is installed automatically. Allows SSH from any computer on same WiFi.

### First-time SSH Setup

In Termux (NOT inside the desktop):

```bash
# Start SSH server
sshd

# Set password
passwd

# Find phone IP
ip addr show wlan0 | grep 'inet '
```

### Connect from PC

```bash
ssh your-termux-username@192.168.1.42 -p 8022
```

> **Port 8022** is the default Termux SSH port (not standard port 22).

Find username with `whoami` in Termux (usually `u0_a123`).

### File Transfer

```bash
# PC -> Phone
scp -P 8022 myfile.txt u0_a123@192.168.1.42:~/

# Phone -> PC
scp -P 8022 u0_a123@192.168.1.42:~/somefile.txt ./
```

Or use any SFTP client (FileZilla, Cyberduck) on same IP:8022.

### SSH Config

Add to `~/.ssh/config` on PC:

```
Host myphone
    HostName 192.168.1.42
    User u0_a123
    Port 8022
```

Then connect with just:

```bash
ssh myphone
```

### Keep SSH Running

Add to `~/.bashrc` in Termux:

```bash
echo 'sshd 2>/dev/null' >> ~/.bashrc
```

### SSH Key Auth

```bash
# On PC - generate key
ssh-keygen -t ed25519

# Copy to phone
ssh-copy-id -p 8022 u0_a123@192.168.1.42
```

---

## Windows App Support (Wine)

Uses **Hangover Wine** + **Box64** to translate Windows x86 calls to ARM64.

Simple tools and utilities tend to work; heavy software or games may not.

Configure with `winecfg` in desktop terminal.

---

## Home Assistant - Smart Home Server

### Home Assistant Installation

```bash
curl -O https://raw.githubusercontent.com/mayukh4/linux-anroid/main/setup-homeassistant.sh
bash setup-homeassistant.sh
```

Takes 15–45 minutes. Longest step is compiling Python dependencies (numpy, cryptography, etc.).

**Start/Stop:**

```bash
bash ~/start-homeassistant.sh
bash ~/stop-homeassistant.sh
```

### Home Assistant Limitations

- **No Bluetooth** — HA cannot access phone's Bluetooth stack through Termux
- **No USB dongles** — Zigbee/Z-Wave USB sticks won't work without root
- **No auto-discovery (mDNS)** — Android 10+ blocks `/proc/net/dev`. Must add devices by IP or cloud API
- **No Docker/Add-ons** — This is HA Core, not HA OS. Core integrations (2000+) work fine

### Accessing the Dashboard

Open browser on any device on same WiFi:

```
http://<your-phone-ip>:8123
```

First launch takes 5–10 minutes to initialize. Create admin account on first visit.

### Adding Devices

1. Open device's companion app and note IP address
2. In HA dashboard: **Settings → Devices & Services → + Add Integration**
3. Search for the device integration (e.g., "TP-Link Kasa Smart")
4. Enter device IP when prompted

---

## Advanced Notes

**Customize GPU flags** — edit `~/.config/linux-gpu.sh`:

```bash
# Force software rendering
export GALLIUM_DRIVER=llvmpipe

# Enable Mesa debug
export MESA_DEBUG=1

# Change OpenGL version
export MESA_GL_VERSION_OVERRIDE=3.3
```

**Auto-start desktop on Termux open** — add to `~/.bashrc`:

```bash
# bash ~/start-linux.sh
```

**Conflict-safe installer** — script checks `Conflicts` field from `apt-cache show` before each install. Safe to run on any Termux setup.

**Non-standard Termux paths** — all hardcoded paths use `$PREFIX`, works on secondary Android user profiles.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| **No audio** | Wait 5–10 seconds after desktop appears — PulseAudio needs time to initialize |
| **SSH connection refused** | Check `ps aux | grep sshd`. Run `sshd` if not running. Use port 8022, not 22 |
| **Wine doesn't launch** | Desktop must be running first, then run `winecfg` from terminal inside desktop |
| **HA pip install fails** | Run `proot-distro login ubuntu`, install `python3-dev libffi-dev libssl-dev cargo`, retry |
| **HA dashboard not loading** | First launch takes 5–10 min. Check same WiFi network. Watch output with `hass -c ~/hass-config` |
| **HA "address already in use"** | Stop other instance: `bash ~/stop-homeassistant.sh` or `pkill -f "hass -c"` |
| **HA devices not discovered** | Expected — Android blocks mDNS. Add manually by IP or use cloud integrations |

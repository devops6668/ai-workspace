---
name: linux-input-method
description: "Install and configure Chinese / CJK input methods (fcitx5) on Ubuntu/Debian — Cangjie, Quick/Sucheng, and other IME tables, profile configuration, and headless setup."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [input-method, ime, chinese, cjk, fcitx5, cangjie, quick, linux-desktop]
---

# Linux Input Method (IME) Setup

Install and configure fcitx5 with Chinese input methods (Cangjie, Quick/Sucheng) on Ubuntu/Debian. Works for both desktop (X11/Wayland) and headless environments.

## Installation

### Install fcitx5 + tables

```bash
# Core framework
DEBIAN_FRONTEND=noninteractive apt-get install -y fcitx5

# Cangjie (倉頡) tables
apt-get install -y fcitx5-table-cangjie5  fcitx5-table-cangjie3  fcitx5-table-cangjie-large

# Quick / Sucheng (速成) tables
apt-get install -y fcitx5-table-quick5  fcitx5-table-quick3  fcitx5-table-quick-classic
```

### Find available tables
```bash
apt-cache search fcitx5-table-
```

Available Cangjie variants: `cangjie5`, `cangjie3`, `cangjie-large`
Available Quick variants: `quick5`, `quick3`, `quick-classic`

## Configuration

### Create profile (`~/.config/fcitx5/profile`)

This defines the input method group and ordering:

```ini
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=cangjie5

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=cangjie5
# Layout
Layout=

[Groups/0/Items/2]
# Name
Name=quick5
# Layout
Layout=

[GroupOrder]
0=Default
```

To change the default, edit `DefaultIM=` to `cangjie3`, `quick5`, etc.

### Create config (`~/.config/fcitx5/config`)

```ini
[Behavior]
PreeditEnabledByDefault=True
ShowPreedit=True
PreeditFont="Sans 14"

[Hotkey]
# Switch between input methods
SwitchIM=Control+Shift
# Switch to next input method
NextIM=Shift
```

### Environment variables

Add to `~/.bashrc` or `~/.profile`:

```bash
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
```

## Usage

### Start fcitx5
```bash
fcitx5 -d           # daemon mode (background)
```

### Switch input methods
- `Ctrl + Shift` — cycle through configured IMEs: English → Cangjie → Quick
- `Shift` (tap) — next input method
- Click the fcitx5 tray icon in desktop environments

### Verify it's running
```bash
ps aux | grep fcitx5
```

## Headless / No-GUI Setup

On a server without a display (`$DISPLAY` unset), fcitx5 can still be configured so it's ready when a desktop session (VNC, SSH -X, local login) starts. The daemon will stay dormant until a display is available.

## Available Tables (installed paths)

```
/usr/share/fcitx5/table/
├── cangjie3.main.dict       # 倉頡三代
├── cangjie5.main.dict       # 倉頡五代 (most common)
├── cangjie-large.main.dict  # 倉頡大集
├── quick3.main.dict         # 速成三代
├── quick5.main.dict         # 速成五代
└── quick-classic.main.dict  # 速成經典
```

## Auto-start on Login

### Using Startup Applications (GUI)
Open **Startup Applications** from the app menu → click **Add**:
- Name: `fcitx5`
- Command: `fcitx5`

### Via systemd user service
```bash
# For headless servers with Linger enabled
sudo loginctl enable-linger $USER

# Enable the gateway if using Hermes
systemctl --user enable hermes-gateway
```

## Pitfalls

- **No display = no GUI toolbar** — fcitx5 works fine via keyboard shortcuts even without a tray icon. The `-d` daemon waits for a display to appear.
- **Profile edits require restart** — after changing `~/.config/fcitx5/profile`, kill the daemon (`pkill fcitx5`) and restart with `fcitx5 -d`.
- **Multiple users** — each user needs their own `~/.config/fcitx5/` directory. System-wide config goes in `/etc/fcitx5/`.
- **QCII (Quick/速成)** is Cangjie with only first+last code per character — easier to learn, slower to type accurately.
- **Special characters in passwords** — `@`, `!`, etc. work fine in both the fcitx5 config and the LDAP admin password if referenced.

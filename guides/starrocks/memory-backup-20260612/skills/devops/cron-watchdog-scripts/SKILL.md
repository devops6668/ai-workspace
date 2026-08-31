---
name: cron-watchdog-scripts
description: "Create no_agent=True cron scripts for silent monitoring with threshold-based alerts — stock prices, disk usage, certificate expiry, service health, and any 'watch for X to happen' pattern."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [cron, monitoring, watchdog, alerting, scripts, automation]
    related_skills: []
---

# Cron Watchdog Scripts

Build silent watchdog scripts that run on a schedule using `no_agent=True` — the script runs autonomously every tick, produces no output when everything is normal, and only alerts the user when a threshold is hit.

## Architecture

```
┌──────────────┐     silent if no match     ┌──────────────┐
│  Cron Job    │ ──────────────────────────→ │  No output   │
│  (every 15m) │                             │  (no alert)  │
│              │     prints on match         │              │
│              │ ──────────────────────────→ │  Alert sent  │
└──────────────┘                             └──────────────┘
```

- **Schedule:** cron expression (e.g. `*/15 1-9 * * 1-5` for every 15 min Mon-Fri)
- **Script mode:** `no_agent=True` — the script IS the job, no LLM involved
- **Delivery:** `origin` — output is delivered to the creating conversation

## When to Use no_agent=True vs no_agent=False (default)

| | `no_agent=True` | `no_agent=False` (default) |
|-|-----------------|---------------------------|
| **What runs** | Just the script. No LLM cost. | Full agent loop runs the prompt every tick. |
| **Output** | Script stdout = message text | Agent decides what to output |
| **Use case** | Mechanical checks (price ≥ X, disk > 90%, cert expires in < 7d) | Tasks requiring reasoning (summarize news, triage logs, draft report) |
| **Speed** | ~1-3s per tick | ~5-30s per tick |
| **Delivery** | Non-empty stdout → delivered. Empty stdout → silent. | Always runs through the agent |

**Rule:** If the output is purely a function of data (no LLM reasoning needed), use `no_agent=True`. You save tokens and get faster ticks.

## Watchdog Design Pattern

### 1. Silent-on-no-match

The script must **exit with no stdout** when the condition is not met. This is critical — every non-empty output becomes a message to the user.

```python
# Script stays silent when nothing to report
if condition_not_met:
    exit(0)

# Only print when there's something to say
print(f"🚨 Alert: {message}")
```

### 2. State file for deduplication

Use a marker file to prevent re-alerting every tick after the threshold is hit:

```python
import os
STATE_FILE = os.path.expanduser("~/.hermes/scripts/.my_alert_state")

already_alerted = False
if os.path.exists(STATE_FILE):
    with open(STATE_FILE) as f:
        already_alerted = bool(int(f.read().strip()))

if threshold_hit and not already_alerted:
    with open(STATE_FILE, "w") as f:
        f.write("1")
    print(f"🚨 Alert!")
elif not threshold_hit and already_alerted:
    os.remove(STATE_FILE)  # Reset when condition clears
```

State file naming convention: prepend with `.` to keep them hidden in ls output. Store in `~/.hermes/scripts/` alongside the script.

### 3. Timezone awareness

The script itself should handle timezone logic — cron runs in UTC but your check may need a different timezone:

```python
import datetime
tz_hkt = datetime.timezone(datetime.timedelta(hours=8))
now = datetime.datetime.now(tz_hkt)

# Only check during trading hours
if now.hour < 9 or now.hour >= 17:
    exit(0)

# Only check weekdays
if now.weekday() >= 5:  # Sat/Sun
    exit(0)
```

### 4. Graceful failure

API failures should be silent — the user gets paged when the condition is met, not when Yahoo Finance is slow:

```python
try:
    price = fetch_price()
except Exception:
    exit(0)  # Silent on transient errors
```

## Script Template

```python
#!/usr/bin/env python3
"""Watchdog: check <condition> every N minutes, alert when <threshold>."""
import json, urllib.request, os, datetime

STATE_FILE = os.path.expanduser("~/.hermes/scripts/.<name>_alerted")

# 1. Time scope filtering
now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
if now.weekday() >= 5:  # Skip weekends
    exit(0)
if now.hour < 9 or now.hour >= 17:  # Skip outside hours
    exit(0)

# 2. Fetch data
try:
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    value = extract_value(data)
except Exception:
    exit(0)

# 3. Dedup check
already_alerted = False
if os.path.exists(STATE_FILE):
    try:
        already_alerted = bool(int(open(STATE_FILE).read().strip()))
    except:
        pass

# 4. Alert or reset
if value >= THRESHOLD and not already_alerted:
    with open(STATE_FILE, "w") as f:
        f.write("1")
    print(f"🚨 Alert message...")
elif value < THRESHOLD and already_alerted:
    os.remove(STATE_FILE)
```

## Setting Up the Cron Job

```bash
hermes cron create \
  --name "My Watchdog" \
  --schedule "*/15 1-9 * * 1-5" \
  --script myscript.py \
  --no-agent
```

Or via the `cronjob` tool:

```
cronjob(
    action="create",
    name="My Watchdog",
    schedule="*/15 1-9 * * 1-5",
    script="myscript.py",
    no_agent=True
)
```

## Cron Schedule Cheat Sheet

| Schedule | Meaning |
|----------|---------|
| `*/15 * * * *` | Every 15 minutes, all day |
| `*/15 9-16 * * 1-5` | Every 15 min, 9am-4pm, Mon-Fri (for UTC) |
| `*/30 0-23 * * *` | Every 30 minutes, 24/7 |
| `0 0 * * 0` | Sunday midnight (weekly) |
| `0 9 * * 1` | Monday 9am (weekly) |
| `0 */6 * * *` | Every 6 hours |

**Note:** Server timezone is UTC. Adjust cron hours to match your target timezone (UTC+N subtract N from target hours, UTC+N add N).

## Testing Your Script

Before creating the cron job, run the script manually:

```bash
python3 ~/.hermes/scripts/myscript.py
echo "exit: $?"
```

- Exit 0 + no output = correct silent behavior
- Exit 0 + output = would deliver an alert now

Override the condition temporarily to test the alert path:

```bash
# Force the threshold in a test run
THRESHOLD=0 python3 -c "
import myscript  # or run with env var override
"
```

## Multi-Stock Reporting Mode

When the user wants price reporting (not just threshold alerts), modify the pattern: **always print the price regardless of condition met**:

```python
# Always report (newer pattern — user prefers this over silent-when-no-match)
change = round(price - prev_close, 2)
pct = round((change / prev_close) * 100, 2) if prev_close else 0
direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")
print(f"🏨 **{SYMBOL}** — **{price} {CURRENCY}** {direction}")
print(f"變動: {change:+.2f} ({pct:+.2f}%) | 高低: {low} - {high}")

# Check threshold alert separately
if price >= THRESHOLD and not already_alerted:
    # ... alert path
```

This supports **report-all + alert-on-threshold** mode where the user gets a regular price report every tick, with a special alert when the threshold is hit. The deduplication state file is still used for threshold alerts only.

## Pitfalls

- **Empty output is silent** — This is the core watchdog property. If you WANT a daily summary even when nothing is wrong, don't use this pattern; use `no_agent=False` with a prompt instead.
- **State file path** — Always use `os.path.expanduser("~/.hermes/scripts/.<name>_alerted")`. Absolute paths break if `HERMES_HOME` changes.
- **State file cleanup** — When the threshold is missed again (e.g. price drops below), clear the state file so the next hit re-alerts. Without this, the watchdog fires exactly once per lifetime.
- **API timeouts** — Set `timeout=10` on all network requests. A stuck API call delays the entire cron scheduler.
- **User-Agent headers** — Yahoo Finance and many APIs block requests without a realistic User-Agent. Always include one.
- **No stdlib imports beyond Python standard library** — Scripts under `~/.hermes/scripts/` run with the system Python, not the Hermes venv. If you need `requests`, `pandas`, or `argon2-cffi`, install them system-wide first.

- **Report-all mode is the default pattern** — User prefers always printing the metric (price, disk %, service status) every tick, with a special alert message only when the threshold is hit. The script always outputs something, not just on alert. This replaces the "silent-on-no-match" default for active monitoring tasks.

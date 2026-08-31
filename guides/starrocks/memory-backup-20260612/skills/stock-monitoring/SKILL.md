---
name: stock-monitoring
description: "Monitor stock prices via Tencent API (HK stocks) or Yahoo Finance (US/international) with cron-based watchdogs — regular reporting, threshold alerts, or both combined."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [stock, finance, yahoo-finance, monitoring, alerting, cron, watchdog]
---

# Stock Price Monitoring

Monitor stock prices via Yahoo Finance API using cron watchdog scripts. Supports three modes:
1. **Alert-only** — only notify when price hits a threshold
2. **Report-only** — always report current price
3. **Report + Alert** — report every tick, with extra alert when threshold hit

## API Selection

**HK stocks prefer Tencent API over Yahoo Finance** — Yahoo now returns 401/404 for many HK symbols.

### Tencent Realtime API (即時行情)

```python
import urllib.request
URL = "https://qt.gtimg.cn/q=hk00005"  # 騰訊港股代碼格式: hk<5位數字>
req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
resp = urllib.request.urlopen(req, timeout=10)
data = resp.read().decode('gbk', errors='ignore')

# 解析: 分割 "var hq_str_hk00005=" 後的 "字段1~字段2~..."
import re
match = re.search(r'"(.+)"', data)  # 或 r'(.+)'
fields = match.group(1).split('~')

# 關鍵字段索引: [3]=昨收  [5]=當前價  [9]=今開  [34]=最高  [35]=最低
# [36]=成交量(股)  [37]=成交额(元)  [39]=換手率(%)  [30]=時間戳
current = float(fields[5])
prev_close = float(fields[4])  # 注意: fields[4] 是昨收
change = current - prev_close
pct = (change / prev_close * 100) if prev_close else 0
```

### Tencent Historical K-Line API (日K線)

```python
import urllib.request, json

# 獲取 360 日 K 線 (前復權 qfq)
URL = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=hk00005,day,,,360,qfq"
req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
resp = urllib.request.urlopen(req, timeout=10)
data = json.loads(resp.read())

klines = data["data"]["hk00005"]["day"]
# 每條: [日期, 開盤, 收盤, 最高, 最低, 成交量]
for item in klines[-5:]:
    date, open_p, close_p, high_p, low_p, vol = item[:6]
```

### Yahoo Finance (fallback for non-HK)

Use the `v8/finance/chart/<SYMBOL>` endpoint for US/international stocks:

```python
import json, urllib.request

URL = "https://query1.finance.yahoo.com/v8/finance/chart/1928.HK"
req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=10) as resp:
    data = json.loads(resp.read())
meta = data["chart"]["result"][0]["meta"]

price = float(meta.get("regularMarketPrice", 0))
prev_close = float(meta.get("chartPreviousClose", 0))
high = float(meta.get("regularMarketDayHigh", 0))
low = float(meta.get("regularMarketDayLow", 0))
vol = meta.get("regularMarketVolume", 0)
change = round(price - prev_close, 2)
pct = round((change / prev_close) * 100, 2)
direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")
```

## Mode 1: Alert-Only (Classic Watchdog)

Script stays silent unless price hits threshold. Best for "watch until X happens."

```python
#!/usr/bin/env python3
"""Alert only when price >= threshold."""
import json, urllib.request, os, datetime

URL = "https://query1.finance.yahoo.com/v8/finance/chart/1928.HK"
STATE_FILE = os.path.expanduser("~/.hermes/scripts/.1928_alerted")
TARGET = 20.0

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
if now.weekday() >= 5 or now.hour < 9 or now.hour >= 17:
    exit(0)

try:
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        meta = json.loads(resp.read())["chart"]["result"][0]["meta"]
    price = float(meta.get("regularMarketPrice", 0))
except Exception:
    exit(0)

already_alerted = False
if os.path.exists(STATE_FILE):
    try:
        already_alerted = bool(int(open(STATE_FILE).read().strip()))
    except:
        pass

if price >= TARGET and not already_alerted:
    with open(STATE_FILE, "w") as f:
        f.write("1")
    print(f"🚨 **{price} HKD** reached target {TARGET}!")
elif price < TARGET and already_alerted:
    os.remove(STATE_FILE)
```

## Mode 2: Report + Alert (Recommended)

Always report the price; additionally alert when threshold hit. Best for active watching.

```python
#!/usr/bin/env python3
"""Report price every tick, alert when threshold hit."""
import json, urllib.request, os, datetime

URL = "https://query1.finance.yahoo.com/v8/finance/chart/1928.HK"
STATE_FILE = os.path.expanduser("~/.hermes/scripts/.1928_alerted")
TARGET = 20.0

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
if now.weekday() >= 5 or now.hour < 9 or now.hour >= 17:
    exit(0)

try:
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        meta = json.loads(resp.read())["chart"]["result"][0]["meta"]
    price = float(meta.get("regularMarketPrice", 0))
    prev_close = float(meta.get("chartPreviousClose", 0))
    high = float(meta.get("regularMarketDayHigh", 0))
    low = float(meta.get("regularMarketDayLow", 0))
    vol = meta.get("regularMarketVolume", 0)
except Exception:
    exit(0)

change = round(price - prev_close, 2)
pct = round((change / prev_close) * 100, 2) if prev_close else 0
direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")

# Always print
print(f"🏨 **1928.HK** — **{price} HKD** {direction}")
print(f"變動: {change:+.2f} ({pct:+.2f}%) | 高低: {low} - {high} | 成交量: {vol:,}")

# Check threshold
already_alerted = False
if os.path.exists(STATE_FILE):
    try:
        already_alerted = bool(int(open(STATE_FILE).read().strip()))
    except:
        pass

if price >= TARGET and not already_alerted:
    with open(STATE_FILE, "w") as f:
        f.write("1")
    print(f"🚨 **Target reached!** {TARGET} HKD!")
elif price < TARGET and already_alerted:
    os.remove(STATE_FILE)
```

## Creating the Cron Jobs

### Creating the Cron Jobs

```python
# Single stock
cronjob(
    action="create",
    name="1928.HK 股價監控",
    no_agent=True,
    schedule="*/15 1-9 * * 1-5",  # Every 15min, 9am-4pm HKT on weekdays
    script="check_1928_price.py"
)

# Second stock
cronjob(
    action="create",
    name="0027.HK 股價監控",
    no_agent=True,
    schedule="*/15 1-9 * * 1-5",
    script="check_0027_price.py"
)
```

### Multiple Stocks in One Report

You can also combine multiple stocks into a single script that reports all prices in one message — reduces cron job count:

```python
#!/usr/bin/env python3
"""Report multiple stock prices in one message."""
import json, urllib.request, os, datetime

STATE_FILE = os.path.expanduser("~/.hermes/scripts/.stocks_alerted")

def fetch(symbol, name):
    URL = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}"
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        meta = json.loads(resp.read())["chart"]["result"][0]["meta"]
    price = float(meta.get("regularMarketPrice", 0))
    prev_close = float(meta.get("chartPreviousClose", 0))
    high = float(meta.get("regularMarketDayHigh", 0))
    low = float(meta.get("regularMarketDayLow", 0))
    vol = meta.get("regularMarketVolume", 0)
    change = round(price - prev_close, 2)
    pct = round((change / prev_close) * 100, 2) if prev_close else 0
    direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")
    return name, price, change, pct, high, low, vol

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
if now.weekday() >= 5 or now.hour < 9 or now.hour >= 17:
    exit(0)

stocks = [
    ("1928.HK", "金沙中國"),
    ("0027.HK", "銀河娛樂"),
]

for symbol, name in stocks:
    try:
        n, price, change, pct, high, low, vol = fetch(symbol, name)
        direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")
        print(f"🏢 **{n}** — **{price} HKD** {direction} ({change:+.2f} {pct:+.2f}%)")
        print(f"  高低: {low} - {high} | 成交量: {vol:,}")
    except Exception:
        print(f"⚠️ **{name}** — fetch failed")
```

## State File Management

| State | File | Purpose |
|-------|------|---------|
| Not alerted | No file | Normal monitoring |
| Threshold hit | `~/.hermes/scripts/.<symbol>_alerted` (content: `1`) | Prevents re-alerting on same threshold |
| Reset | File deleted | Price dropped below threshold; next hit will re-alert |

## Pitfalls

- **Yahoo Finance may return stale data** during market hours if called right at market open. The first tick of the day might show yesterday's close.
- **`User-Agent` header is required** — Yahoo Finance blocks requests without a realistic User-Agent. Always include `Mozilla/5.0`.
- **API timeouts** — set `timeout=10` on `urllib.request.urlopen()`. A stuck API call blocks the entire cron scheduler.
- **State files use hidden names** — prepend with `.` so they don't appear in `ls` output. Store in `~/.hermes/scripts/`.
- **No external Python dependencies** — scripts run with system Python, not Hermes venv. Use only `json`, `urllib.request`, `os`, `datetime` from stdlib.
- **State file cleanup** — always remove the state file when price drops below threshold. Without this, the watchdog fires exactly once per threshold lifetime and never re-alerts.
- **Multiple stocks** — create one script per stock with distinct state files (`.1928_alerted`, `.0027_alerted`) to avoid conflicts.

### Cron Scheduling for HK Stock Trading Hours

Hermes cron scheduler does **not** support range/step cron expressions like `9:30-12:00/15`. Use a broad schedule and handle trading-hour filtering inside the script.

```yaml
# Cron schedule — broad window (HKT 9:00~16:00, Mon-Fri)
schedule: "*/15 9-16 * * 1-5"

# Script logic — exit early if not trading time
def is_hktrading_time(h, m):
    if h == 9 and m < 30: return False   # before 9:30
    if h == 12 and m == 0: return False  # 12:00 = market close
    if 9 < h < 13: return True           # 10,11,12 (12:01+ already past)
    if 13 <= h < 16: return True          # afternoon session
    if h == 16 and m == 0: return False   # 16:00 = market close
    return False

# At top of script, after getting HKT time:
if not is_hktrading_time(now.hour, now.minute):
    exit(0)
```

**HKSE trading hours**: Morning 09:30-12:00, Afternoon 13:00-16:00 (Mon-Fri). Closed weekends, public holidays, and lunch break 12:00-13:00.

### Timezone for Cron

**Important**: Hermes cron uses the **server's local timezone**, NOT UTC. If your server is set to HKT (CST, UTC+8), use `*/15 9-16 * * 1-5` directly. If the server is UTC, convert HKSE hours by subtracting 8: `*/15 1-8 * * 1-5` (round up as needed).

**Verify server timezone**: `date +%Z`

## Supporting Files

| File | Purpose |
|------|---------|
| `templates/hk-trading-time.py` | Reusable `is_hktrading_time()` function — copy into any script |
| `references/tencent-api-fields.md` | Tencent API field mapping, K-line docs, encoding notes |

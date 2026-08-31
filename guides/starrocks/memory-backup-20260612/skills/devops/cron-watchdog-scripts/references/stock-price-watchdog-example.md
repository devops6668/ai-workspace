# Stock Price Watchdog Example

Real-world watchdog script that monitors 1928.HK (Sands China) price every 15 minutes on HKSE trading days, alerts when price >= 20 HKD.

## Script

Script at `~/.hermes/scripts/check_1928_price.py`:

```python
#!/usr/bin/env python3
"""Check 1928.HK price every 15 min on trading days. Alert when >= 20 HKD."""
import json, urllib.request, os, datetime

URL = "https://query1.finance.yahoo.com/v8/finance/chart/1928.HK"
STATE_FILE = os.path.expanduser("~/.hermes/scripts/.1928_alerted")

now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
dow = now.weekday()

# Only run on weekdays (Mon-Fri)
if dow >= 5:
    exit(0)

# HKSE trading hours: 9:30-12:00, 13:00-16:00 HKT
hour = now.hour
if hour < 9 or hour >= 17:
    exit(0)

try:
    req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    meta = data["chart"]["result"][0]["meta"]
    price = float(meta.get("regularMarketPrice", 0))
    prev_close = float(meta.get("chartPreviousClose", 0))
    high = float(meta.get("regularMarketDayHigh", 0))
    low = float(meta.get("regularMarketDayLow", 0))
    vol = meta.get("regularMarketVolume", 0)
except Exception:
    exit(0)

# Check if we already alerted for this threshold
already_alerted = False
if os.path.exists(STATE_FILE):
    try:
        already_alerted = bool(int(open(STATE_FILE).read().strip()))
    except:
        pass

if price >= 20 and not already_alerted:
    with open(STATE_FILE, "w") as f:
        f.write("1")
    change = round(price - prev_close, 2)
    direction = "📈" if change >= 0 else "📉"
    print(f"🚨 **1928.HK 金沙中國 已到 20 HKD！**")
    print(f"")
    print(f"現價: **{price} HKD** {direction}")
    print(f"變動: {change:+.2f}")
    print(f"高低: {low} - {high}")
    print(f"成交量: {vol:,}")
    print(f"時間: {now.strftime('%Y-%m-%d %H:%M')} HKT")
elif price < 20 and already_alerted:
    os.remove(STATE_FILE)
```

## Cron Job Config

```json
{
  "name": "1928.HK 股價監控",
  "schedule": "*/15 1-9 * * 1-5",
  "script": "check_1928_price.py",
  "no_agent": true,
  "deliver": "origin"
}
```

## Schedule Explained

`*/15 1-9 * * 1-5` in UTC:

| Field | Value | Meaning |
|-------|-------|---------|
| Minute | */15 | Every 15 minutes |
| Hour | 1-9 | 01:00-09:59 UTC = 09:00-17:59 HKT |
| Day of month | * | Every day |
| Month | * | Every month |
| Day of week | 1-5 | Monday to Friday |

## Yahoo Finance API Notes

- Query: `https://query1.finance.yahoo.com/v8/finance/chart/{SYMBOL}`
- Symbol format: `1928.HK` for HKSE, `AAPL` for NASDAQ, `0700.HK` for Tencent
- Requires `User-Agent: Mozilla/5.0` header
- Returns JSON — no API key needed for basic quotes
- Rate limit: ~10 req/min before getting soft-blocked (fine for 15-min intervals)

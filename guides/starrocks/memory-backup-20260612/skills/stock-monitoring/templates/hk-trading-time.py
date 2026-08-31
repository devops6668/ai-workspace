#!/usr/bin/env python3
"""HK stock trading hours check. Returns 0 (trading) or 1 (not trading).

Usage: include at top of any stock-monitoring script before fetching data.
Call with: if not is_hktrading_time(now.hour, now.minute): exit(0)

HKSE hours: Morning 09:30-12:00, Afternoon 13:00-16:00 (Mon-Fri)
Uses datetime timezone offset — pass the offset matching your server TZ.
"""
import datetime

def is_hktrading_time(hour, minute):
    """Return True if the given local time is during HKSE trading hours."""
    # Before market opens
    if hour == 9 and minute < 30:
        return False
    # Morning close
    if hour == 12 and minute == 0:
        return False
    # Morning session: 09:30 - 12:00
    if 9 < hour < 13:
        return True
    # Lunch break: 12:00 - 13:00
    if hour == 12:
        return False
    # Afternoon session: 13:00 - 16:00
    if 13 <= hour < 16:
        return True
    # After market close
    if hour == 16 and minute == 0:
        return False
    return False

def is_weekday():
    """Return True if today is a weekday (Mon-Fri)."""
    return datetime.datetime.now().weekday() < 5

if __name__ == "__main__":
    now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    weekday = is_weekday()
    trading = is_hktrading_time(now.hour, now.minute)
    status = "🟢 TRADING" if (weekday and trading) else ("🔴 CLOSED" if not weekday else "🟡 PRE-MARKET / LUNCH / AFTER-HOURS")
    print(f"{now.strftime('%Y-%m-%d %H:%M:%S')} HKT — Weekday: {weekday} | Trading: {trading} | {status}")

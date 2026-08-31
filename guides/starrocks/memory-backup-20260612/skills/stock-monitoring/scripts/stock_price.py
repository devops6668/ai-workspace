#!/usr/bin/env python3
"""Fetch current price for a stock via Yahoo Finance API. Supports multiple symbols."""
import json, urllib.request, os, sys

URL = "https://query1.finance.yahoo.com/v8/finance/chart/"
SYMBOLS = os.environ.get("STOCK_SYMBOLS", "").split(",") or sys.argv[1:]

if not SYMBOLS:
    print("Usage: STOCK_SYMBOLS=1928.HK,0027.HK python3 stock_price.py OR python3 stock_price.py 1928.HK 0027.HK")
    exit(0)

results = []
for symbol in SYMBOLS:
    symbol = symbol.strip()
    if not symbol:
        continue
    try:
        req = urllib.request.Request(f"{URL}{symbol}", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        meta = data["chart"]["result"][0]["meta"]
        results.append(meta)
    except Exception as e:
        print(f"Failed to fetch {symbol}: {e}", file=sys.stderr)

# Print structured output (pipe-delimited for easy parsing)
for meta in results:
    symbol = meta.get("symbol", "")
    price = float(meta.get("regularMarketPrice", 0))
    prev_close = float(meta.get("chartPreviousClose", 0))
    high = float(meta.get("regularMarketDayHigh", 0))
    low = float(meta.get("regularMarketDayLow", 0))
    vol = meta.get("regularMarketVolume", 0)
    change = round(price - prev_close, 2) if prev_close else 0
    pct = round((change / prev_close) * 100, 2) if prev_close else 0
    direction = "📈" if change > 0 else ("📉" if change < 0 else "➡️")
    print(f"{symbol}|{price}|{change}|{pct}|{direction}|{high}|{low}|{vol}")

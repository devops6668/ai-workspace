#!/usr/bin/env python3
"""Backtest all strategies on 1128.HK (Wynn Macau)."""

import sys
sys.path.insert(0, '.')
from backtest import *

ticker = '1128.HK'
name = '永利澳門 (Wynn Macau)'

print(f"\n{'#'*60}")
print(f"# {ticker} — {name}")
print(f"{'#'*60}")

try:
    df = fetch_data(ticker, start="2020-01-01", end="2025-12-31")
except Exception as e:
    print(f"Failed to fetch {ticker}: {e}")
    sys.exit(1)

strategy_configs = {
    'ma':       (strategy_ma_cross,       'MA20/60 Crossover',         {}),
    'rsi':      (strategy_rsi,            'RSI Reversal (14d)',        {}),
    'bb':       (strategy_bollinger,      'Bollinger Band Reversal',   {}),
    'breakout': (strategy_breakout,       '20-Day Breakout',           {}),
}

for s, (func, sname, kwargs) in strategy_configs.items():
    result = run_backtest(df, func, sname, **kwargs)
    print_report(result)

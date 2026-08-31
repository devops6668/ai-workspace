#!/usr/bin/env python3
"""Backtest trading strategies on HK stocks using Yahoo Finance data."""

import yfinance as yf
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import json
import os
import sys

def fetch_data(ticker, start="2020-01-01", end="2025-12-31"):
    """Fetch OHLCV data from Yahoo Finance."""
    df = yf.download(ticker, start=start, end=end, progress=False)
    if df.empty:
        print(f"ERROR: No data for {ticker}")
        sys.exit(1)
    # Multi-column to single-column
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    return df.reset_index()

# ============================================================
# Strategy A: Moving Average Crossover (MA5 / MA20)
# ============================================================
def strategy_ma_cross(df, fast=20, slow=60):
    """MA fast crosses above MA slow → buy. MA fast crosses below MA slow → sell."""
    df[f'MA{fast}'] = df['Close'].rolling(window=fast).mean()
    df[f'MA{slow}'] = df['Close'].rolling(window=slow).mean()
    
    positions = pd.Series(0, index=df.index)
    positions[df[f'MA{fast}'] > df[f'MA{slow}']] = 1
    positions[df[f'MA{fast}'] < df[f'MA{slow}']] = -1
    
    # Signal: 1 = hold, 0 = flat (no position)
    # We only need positions, not diff
    df['signal'] = positions
    return df

# ============================================================
# Strategy B: RSI Reversal (RSI < 30 buy, RSI > 70 sell)
# ============================================================
def strategy_rsi(df, period=14, buy_thresh=30, sell_thresh=70):
    """RSI < threshold → buy. RSI > threshold → sell."""
    delta = df['Close'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=period).mean()
    rs = gain / loss
    df['RSI'] = 100 - (100 / (1 + rs))
    
    df['signal'] = 0
    df.loc[df['RSI'] < buy_thresh, 'signal'] = 1   # Buy signal
    df.loc[df['RSI'] > sell_thresh, 'signal'] = -1  # Sell signal
    
    return df

# ============================================================
# Strategy C: Bollinger Band Reversal
# ============================================================
def strategy_bollinger(df, period=20, num_std=2):
    """Price touches lower band → buy. Price touches upper band → sell."""
    df['BB_mid'] = df['Close'].rolling(window=period).mean()
    bb_std = df['Close'].rolling(window=period).std()
    df['BB_upper'] = df['BB_mid'] + (num_std * bb_std)
    df['BB_lower'] = df['BB_mid'] - (num_std * bb_std)
    
    df['signal'] = 0
    df.loc[df['Close'] <= df['BB_lower'], 'signal'] = 1   # Buy: below lower band
    df.loc[df['Close'] >= df['BB_upper'], 'signal'] = -1  # Sell: above upper band
    
    return df

# ============================================================
# Strategy D: Breakout (N-day high/low)
# ============================================================
def strategy_breakout(df, lookback=20):
    """Break above N-day high → buy. Break below N-day low → sell."""
    df['high_N'] = df['High'].rolling(window=lookback).max()
    df['low_N'] = df['Low'].rolling(window=lookback).min()
    
    df['signal'] = 0
    # Buy: today's close > yesterday's N-day high
    df.loc[df['Close'].shift(1) < df['high_N'].shift(1), 'signal'] = 1
    # Sell: today's close < yesterday's N-day low
    df.loc[df['Close'].shift(1) > df['low_N'].shift(1), 'signal'] = -1
    
    return df

# ============================================================
# Backtest engine
# ============================================================
def run_backtest(df, strategy_func, strategy_name, **kwargs):
    """Run a backtest with transaction cost."""
    df = strategy_func(df, **kwargs)
    
    # Drop NaN from rolling windows
    df = df.dropna()
    
    if df.empty:
        return None
    
    # Simple simulation: hold 1 share, 0.1% commission per trade
    commission = 0.001
    balance = 100000.0  # Starting capital HKD
    shares = 0
    entry_price = 0
    trades = []
    
    for i in range(1, len(df)):
        signal = df.loc[df.index[i], 'signal']
        current_price = df.loc[df.index[i], 'Close']
        prev_signal = df.loc[df.index[i-1], 'signal']
        
        # Buy signal (0 → 1)
        if signal == 1 and prev_signal != 1 and shares == 0:
            cost = current_price * (1 + commission)
            if balance >= cost:
                balance -= cost
                shares = 1
                entry_price = current_price
                trades.append({
                    'date': str(df.loc[df.index[i], 'Date']),
                    'type': 'BUY',
                    'price': current_price,
                    'balance': balance
                })
        
        # Sell signal (1 → -1 or 1 → 0)
        elif signal == -1 and prev_signal != -1 and shares > 0:
            proceeds = current_price * (1 - commission)
            pnl = (proceeds - entry_price) * shares
            balance += proceeds
            trades.append({
                'date': str(df.loc[df.index[i], 'Date']),
                'type': 'SELL',
                'price': current_price,
                'pnl': round(pnl, 2),
                'pnl_pct': round(((proceeds/entry_price) - 1) * 100, 2),
                'balance': balance
            })
            shares = 0
            entry_price = 0
    
    # Calculate final P&L if still holding
    final_price = df.iloc[-1]['Close']
    total_return = balance - 100000.0
    if shares > 0:
        final_value = balance + final_price * shares  # Assume sold at last price
        pnl = final_value - 100000.0
    else:
        pnl = total_return
    
    total_trades = len(trades)
    wins = sum(1 for t in trades if t['type'] == 'SELL' and t.get('pnl', 0) > 0)
    losses = total_trades - wins
    win_rate = (wins / total_trades * 100) if total_trades > 0 else 0
    
    return {
        'strategy': strategy_name,
        'ticker': df['Date'].name if hasattr(df['Date'], 'name') else 'N/A',
        'period': f"{df['Date'].min().strftime('%Y-%m-%d')} to {df['Date'].max().strftime('%Y-%m-%d')}",
        'starting_capital': 100000,
        'final_capital': round(balance, 2),
        'total_pnl': round(pnl, 2),
        'total_pnl_pct': round((pnl / 100000) * 100, 2),
        'total_trades': total_trades,
        'wins': wins,
        'losses': losses,
        'win_rate': round(win_rate, 1),
        'trades': trades[:20],  # First 20 trades
        'data_points': len(df)
    }

# ============================================================
# Pretty print
# ============================================================
def print_report(result):
    if not result:
        print("No valid trades found.\n")
        return
    
    print("=" * 70)
    print(f"📊 {result['strategy']} — {result['ticker']}")
    print("=" * 70)
    print(f"Period:       {result['period']}")
    print(f"Data points:  {result['data_points']}")
    print(f"Starting:     HKD {result['starting_capital']:,.0f}")
    print(f"Final:        HKD {result['final_capital']:,.2f}")
    print(f"P&L:          HKD {result['total_pnl']:,.2f} ({result['total_pnl_pct']:+.2f}%)")
    print(f"Total trades: {result['total_trades']}")
    print(f"Wins/Losses:  {result['wins']}/{result['losses']}")
    print(f"Win rate:     {result['win_rate']:.1f}%")
    print("-" * 70)
    print("Trade log (first 20):")
    print(f"{'Date':<12} {'Type':<6} {'Price':>10} {'P&L':>12} {'Balance':>14}")
    print("-" * 70)
    for t in result['trades']:
        pnl_str = f"  {t.get('pnl', 0):>+.2f}" if t['type'] == 'SELL' else "        —"
        print(f"{t['date']:<12} {t['type']:<6} {t['price']:>10.2f} {pnl_str:>12} {t.get('balance', 0):>14,.2f}")
    print("=" * 70)
    print()

# ============================================================
# Main
# ============================================================
TICKER_MAP = {
    '1928.HK': '金沙中國 (Sands China)',
    '0027.HK': '银河娱乐 (Galaxy Entertainment)',
}

def main():
    if len(sys.argv) < 2:
        print("Usage: python backtest.py [ticker] [strategy]")
        print(f"\nAvailable tickers:")
        for t, name in TICKER_MAP.items():
            print(f"  {t} — {name}")
        print("\nAvailable strategies:")
        print("  ma     — Moving Average crossover (MA5/MA20)")
        print("  rsi    — RSI reversal (buy <30, sell >70)")
        print("  bb     — Bollinger Band reversal")
        print("  breakout — N-day high/low breakout (20-day)")
        print("  all    — Run all strategies")
        print("\nExamples:")
        print(f"  python backtest.py 1928.HK ma")
        print(f"  python backtest.py 1928.HK rsi")
        print(f"  python backtest.py all all")
        return
    
    ticker = sys.argv[1].upper()
    strategy_filter = sys.argv[2] if len(sys.argv) > 2 else 'all'
    
    if ticker not in TICKER_MAP and ticker != 'ALL':
        print(f"Unknown ticker: {ticker}")
        return
    
    tickers = list(TICKER_MAP.keys()) if ticker == 'ALL' else [ticker]
    strategies = ['ma', 'rsi', 'bb', 'breakout'] if strategy_filter == 'all' else [strategy_filter]
    
    strategy_configs = {
        'ma':       (strategy_ma_cross,       'MA20/60 Crossover',         {}),
        'rsi':      (strategy_rsi,            'RSI Reversal (14d)',        {}),
        'bb':       (strategy_bollinger,      'Bollinger Band Reversal',   {}),
        'breakout': (strategy_breakout,       '20-Day Breakout',           {}),
    }
    
    for ticker in tickers:
        print(f"\n{'#'*60}")
        print(f"# {ticker} — {TICKER_MAP[ticker]}")
        print(f"{'#'*60}")
        
        try:
            df = fetch_data(ticker, start="2020-01-01", end="2025-12-31")
        except Exception as e:
            print(f"Failed to fetch {ticker}: {e}")
            continue
        
        for s in strategies:
            if s not in strategy_configs:
                print(f"Unknown strategy: {s}")
                continue
            
            func, name, kwargs = strategy_configs[s]
            result = run_backtest(df, func, name, **kwargs)
            print_report(result)

if __name__ == '__main__':
    main()

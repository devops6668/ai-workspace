#!/usr/bin/env python3
"""Backtest with stop-loss and take-profit, plus buy-on-dip strategy."""

import yfinance as yf
import pandas as pd
import numpy as np
from datetime import datetime
import sys

def fetch_data(ticker, start="2020-01-01", end="2025-12-31"):
    df = yf.download(ticker, start=start, end=end, progress=False)
    if df.empty:
        print(f"ERROR: No data for {ticker}")
        sys.exit(1)
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    return df.reset_index()

# ============================================================
# Strategy: RSI Reversal + Stop Loss + Take Profit
# ============================================================
def strategy_rsi_with_sl_tp(df, rsi_period=14, buy_thresh=30, sell_thresh=70,
                             stop_loss_pct=5, take_profit_pct=5):
    """RSI buy/sell with stop-loss and take-profit on each trade."""
    delta = df['Close'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=rsi_period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=rsi_period).mean()
    rs = gain / loss
    df['RSI'] = 100 - (100 / (1 + rs))
    
    df['signal'] = 0
    df.loc[df['RSI'] < buy_thresh, 'signal'] = 1
    df.loc[df['RSI'] > sell_thresh, 'signal'] = -1
    
    return df

# ============================================================
# Strategy: Buy-the-Dip (after N-day drop)
# ============================================================
def strategy_buy_dip(df, lookback=5, drop_thresh=5, hold_days=10):
    """After N-day drop of X%, buy and hold for Y days."""
    df['change_N'] = df['Close'].pct_change(lookback) * 100
    df['signal'] = 0
    df['entry_date'] = pd.NaT
    df['exit_date'] = pd.NaT
    
    # Buy: dropped more than threshold in lookback days
    buy_mask = df['change_N'] < -drop_thresh
    df.loc[buy_mask, 'signal'] = 1
    df.loc[buy_mask, 'entry_date'] = df['Date']
    
    # Hold for N days (simple exit)
    for i in range(len(df)):
        if pd.notna(df.loc[df.index[i], 'entry_date']) and df.loc[df.index[i], 'signal'] == 1:
            exit_idx = min(i + hold_days, len(df) - 1)
            df.loc[df.index[i], 'exit_date'] = df.loc[df.index[exit_idx], 'Date']
            df.loc[df.index[i], 'signal'] = 2  # signal = exit on exit_date
    
    return df

# ============================================================
# Strategy: RSI + Volume Confirmation
# ============================================================
def strategy_rsi_volume(df, rsi_period=14, buy_thresh=30, sell_thresh=70):
    """RSI reversal but only if volume > 20-day average."""
    delta = df['Close'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=rsi_period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=rsi_period).mean()
    rs = gain / loss
    df['RSI'] = 100 - (100 / (1 + rs))
    df['vol_ma20'] = df['Volume'].rolling(window=20).mean()
    
    df['signal'] = 0
    # Only buy when RSI is low AND volume is above average (confirmation)
    df.loc[(df['RSI'] < buy_thresh) & (df['Volume'] > df['vol_ma20']), 'signal'] = 1
    df.loc[df['RSI'] > sell_thresh, 'signal'] = -1
    
    return df

# ============================================================
# Backtest engine with SL/TP
# ============================================================
def run_backtest_sl_tp(df, strategy_func, strategy_name, **kwargs):
    df = strategy_func(df, **kwargs)
    df = df.dropna()
    if df.empty:
        return None
    
    commission = 0.001
    balance = 100000.0
    shares = 0
    entry_price = 0
    in_trade = False
    trade_start_price = 0
    trades = []
    
    for i in range(1, len(df)):
        signal = df.loc[df.index[i], 'signal']
        current_price = df.loc[df.index[i], 'Close']
        prev_signal = df.loc[df.index[i-1], 'signal']
        
        # New buy signal
        if signal == 1 and not in_trade:
            cost = current_price * (1 + commission)
            if balance >= cost:
                balance -= cost
                shares = 1
                entry_price = current_price
                trade_start_price = current_price
                in_trade = True
                trades.append({
                    'date': str(df.loc[df.index[i], 'Date']),
                    'type': 'BUY',
                    'price': current_price,
                    'balance': balance
                })
        
        # Check SL/TP if in trade
        if in_trade and shares > 0:
            pnl_pct = (current_price / entry_price - 1) * 100
            
            # Stop loss
            if pnl_pct <= -kwargs.get('stop_loss_pct', 5):
                proceeds = current_price * (1 - commission)
                pnl = (proceeds - entry_price) * shares
                balance += proceeds
                trades.append({
                    'date': str(df.loc[df.index[i], 'Date']),
                    'type': 'SELL (SL)',
                    'price': current_price,
                    'pnl': round(pnl, 2),
                    'pnl_pct': round(pnl_pct, 2),
                    'balance': balance
                })
                shares = 0
                in_trade = False
                entry_price = 0
                continue
            
            # Take profit
            if pnl_pct >= kwargs.get('take_profit_pct', 5):
                proceeds = current_price * (1 - commission)
                pnl = (proceeds - entry_price) * shares
                balance += proceeds
                trades.append({
                    'date': str(df.loc[df.index[i], 'Date']),
                    'type': 'SELL (TP)',
                    'price': current_price,
                    'pnl': round(pnl, 2),
                    'pnl_pct': round(pnl_pct, 2),
                    'balance': balance
                })
                shares = 0
                in_trade = False
                entry_price = 0
                continue
        
        # Sell signal (RSI too high)
        if signal == -1 and in_trade:
            proceeds = current_price * (1 - commission)
            pnl = (proceeds - entry_price) * shares
            trades.append({
                'date': str(df.loc[df.index[i], 'Date']),
                'type': 'SELL',
                'price': current_price,
                'pnl': round(pnl, 2),
                'pnl_pct': round(((proceeds/entry_price) - 1) * 100, 2),
                'balance': balance
            })
            balance += proceeds
            shares = 0
            in_trade = False
            entry_price = 0
    
    final_price = df.iloc[-1]['Close']
    if shares > 0:
        final_value = balance + final_price * shares
        pnl = final_value - 100000.0
    else:
        pnl = balance - 100000.0
    
    total_trades = len([t for t in trades if t['type'] != 'BUY'])
    wins = sum(1 for t in trades if t['type'] in ('SELL', 'SELL (TP)') and t.get('pnl', 0) > 0)
    losses = total_trades - wins
    win_rate = (wins / total_trades * 100) if total_trades > 0 else 0
    
    return {
        'strategy': strategy_name,
        'period': f"{df['Date'].min().strftime('%Y-%m-%d')} to {df['Date'].max().strftime('%Y-%m-%d')}",
        'starting_capital': 100000,
        'final_capital': round(balance, 2),
        'total_pnl': round(pnl, 2),
        'total_pnl_pct': round((pnl / 100000) * 100, 2),
        'total_trades': total_trades,
        'wins': wins,
        'losses': losses,
        'win_rate': round(win_rate, 1),
        'trades': trades[:30],
        'data_points': len(df)
    }

def print_report(result):
    if not result:
        print("No valid trades found.\n")
        return
    print("=" * 70)
    print(f"📊 {result['strategy']}")
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
    print("Trade log (first 30):")
    print(f"{'Date':<12} {'Type':<12} {'Price':>10} {'P&L':>12} {'Bal':>14}")
    print("-" * 70)
    for t in result['trades']:
        pnl_str = f"  {t.get('pnl', 0):>+.2f}" if 'SELL' in t['type'] else "        —"
        print(f"{t['date']:<12} {t['type']:<12} {t['price']:>10.2f} {pnl_str:>12} {t.get('balance', 0):>14,.2f}")
    print("=" * 70)
    print()

TICKERS = {
    '1928.HK': '金沙中國 (Sands China)',
    '0027.HK': '银河娱乐 (Galaxy Entertainment)',
    '1128.HK': '永利澳門 (Wynn Macau)',
}

if __name__ == '__main__':
    ticker = sys.argv[1] if len(sys.argv) > 1 else '1928.HK'
    if ticker not in TICKERS:
        print(f"Usage: python backtest_sl_tp.py [1928.HK|0027.HK|1128.HK]")
        sys.exit(1)
    
    print(f"\n{'#'*60}")
    print(f"# {ticker} — {TICKERS[ticker]}")
    print(f"{'#'*60}")
    
    df = fetch_data(ticker, start="2020-01-01", end="2025-12-31")
    
    # Strategy 1: RSI + SL 5% + TP 5%
    result = run_backtest_sl_tp(df, strategy_rsi_with_sl_tp,
        'RSI + SL 5% + TP 5%', stop_loss_pct=5, take_profit_pct=5)
    print_report(result)
    
    # Strategy 2: RSI + SL 3% + TP 8% (wider TP, tighter SL)
    result = run_backtest_sl_tp(df, strategy_rsi_with_sl_tp,
        'RSI + SL 3% + TP 8%', stop_loss_pct=3, take_profit_pct=8)
    print_report(result)
    
    # Strategy 3: RSI + Volume confirmation
    result = run_backtest_sl_tp(df, strategy_rsi_volume,
        'RSI + Volume Filter')
    print_report(result)
    
    # Strategy 4: Buy the Dip (5-day drop 5%+, hold 10 days)
    df2 = strategy_buy_dip(df, lookback=5, drop_thresh=5, hold_days=10)
    # Manually run backtest for buy-dip
    df2 = df2.dropna()
    if not df2.empty:
        commission = 0.001
        balance = 100000.0
        in_trade = False
        entry_price = 0
        exit_date = pd.NaT
        trades = []
        
        for i in range(1, len(df2)):
            signal = df2.loc[df2.index[i], 'signal']
            current_price = df2.loc[df2.index[i], 'Close']
            
            if signal == 1 and not in_trade:
                cost = current_price * (1 + commission)
                if balance >= cost:
                    balance -= cost
                    entry_price = current_price
                    in_trade = True
                    exit_date = df2.loc[df2.index[i], 'exit_date']
                    trades.append({'date': str(df2.loc[df2.index[i], 'Date']), 'type': 'BUY', 'price': current_price, 'balance': balance})
            
            if in_trade and pd.notna(exit_date) and str(df2.loc[df2.index[i], 'Date']) == str(exit_date):
                proceeds = current_price * (1 - commission)
                pnl = (proceeds - entry_price)
                trades.append({
                    'date': str(df2.loc[df2.index[i], 'Date']),
                    'type': 'SELL',
                    'price': current_price,
                    'pnl': round(pnl, 2),
                    'pnl_pct': round((proceeds/entry_price - 1)*100, 2),
                    'balance': balance + proceeds
                })
                balance += proceeds
                in_trade = False
                entry_price = 0
                exit_date = pd.NaT
        
        final_price = df2.iloc[-1]['Close']
        pnl = balance + (final_price if in_trade else 0) - 100000
        total_trades = len([t for t in trades if 'SELL' in t['type']])
        wins = sum(1 for t in trades if 'SELL' in t['type'] and t.get('pnl', 0) > 0)
        losses = total_trades - wins
        
        print("=" * 70)
        print(f"📊 Buy-the-Dip (5d drop ≥5%, hold 10d)")
        print("=" * 70)
        print(f"Period:       {df2['Date'].min().strftime('%Y-%m-%d')} to {df2['Date'].max().strftime('%Y-%m-%d')}")
        print(f"Starting:     HKD 100,000")
        print(f"Final:        HKD {balance:.2f}")
        print(f"P&L:          HKD {pnl:.2f} ({(pnl/100000)*100:+.2f}%)")
        print(f"Total trades: {total_trades}")
        print(f"Wins/Losses:  {wins}/{losses}")
        print(f"Win rate:     {wins/total_trades*100:.1f}%" if total_trades else "Win rate:     0.0%")
        print("-" * 70)
        print("Trade log:")
        print(f"{'Date':<12} {'Type':<12} {'Price':>10} {'P&L':>12}")
        print("-" * 70)
        for t in trades[:30]:
            pnl_str = f"  {t.get('pnl', 0):>+.2f}" if 'SELL' in t['type'] else "        —"
            print(f"{t['date']:<12} {t['type']:<12} {t['price']:>10.2f} {pnl_str:>12}")
        print("=" * 70)
        print()

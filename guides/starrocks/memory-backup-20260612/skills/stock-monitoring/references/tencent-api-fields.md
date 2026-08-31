# Tencent Stock API Field Reference

## Realtime API: `https://qt.gtimg.cn/q=hk<5-digit-code>`

Returns a `~`-separated string with 78 fields for HK stocks.

## Historical K-Line API: `https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=hk<CODE>,day,,,<PERIOD>,qfq`

| Parameter | Value |
|-----------|-------|
| `hk<CODE>` | e.g. `hk00005` for HSBC |
| `day` | Timeframe: `day`, `week`, `month` |
| `<PERIOD>` | Number of days: `60`, `120`, `360`, `500` |
| `qfq` | Forward-adjusted (前復權); use `hfq` for backward |

Each K-line item: `[date, open, close, high, low, volume]`

## Pitfalls

- **Yahoo Finance 401/404 for HK stocks** — Yahoo's API now requires authentication for many HK symbols. Use Tencent API instead.
- **GBK encoding** — Tencent realtime API returns GBK-encoded data, NOT UTF-8. Use `decode('gbk', errors='ignore')`.
- **Field 30 has timestamp** — Contains both date and time: `2026/06/04 16:08:19`.
- **Volume units** — Realtime API volume is in shares (股); K-line volume also in shares.
- **Amount unit** — Realtime API amount [37] is in 元 (RMB converted from HKD); K-line volume is in shares.
- **Multiple quotes** — To fetch multiple stocks at once: `q=hk00005~hk00001~hk00700`
- **User-Agent required** — Always include a realistic `Mozilla/5.0` User-Agent header.

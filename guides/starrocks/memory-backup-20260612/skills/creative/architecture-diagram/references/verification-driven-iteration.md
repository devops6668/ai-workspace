# Verification-Driven Diagram Iteration: Dagster OTel Case Study

This reference documents a pattern where an architecture diagram went through 3 iterations as each
architectural claim was verified against running code. Use this when documenting systems where
the documented architecture may not match reality.

## The Pattern

```
Documentation → Form hypothesis → Diagram v1 → Verify → Discover gap → Diagram v2 → Verify → Diagram v3
```

### Key Principle: Verify every arrow

Every connection/flow in the diagram should be verifiable by checking actual runtime state:
- Environment variables on running pods
- Process entrypoints and startup code
- Data presence in the sink (Elasticsearch, database, etc.)
- Import/module availability in the actual container images

## Case Study: Dagster OTel Architecture (3 iterations)

### v1 — "As documented" (wrong)

Assumed all claims in the observability guide were true:
- Daemon/Webserver: configure_otel() → automatically export traces
- Metrics-exporter: polls PG → exports metrics
- Code locations: env vars injected → need OTel SDK

**Flaw:** Believed documentation without verifying each claim against running code.

### v2 — "Code locations don't need SDK" (partially wrong)

Verified code locations don't have OTel SDK (user correction + docs), reverted code changes.

**Still wrong about:** Daemon/Webserver producing traces.

### v3 — "Verify every claim" (correct)

Actual verification steps that revealed the truth:

| Claim | Verification Method | Result |
|-------|-------------------|--------|
| "Daemon exports traces" | Searched dagster package for `start_span` | **0 matches** — Dagster 1.12 has zero OTel instrumentation |
| "Webserver exports traces" | Same search | Same — no spans ever created |
| "Metrics-exporter exports metrics" | Read source code | ✅ Self-creates 10 gauges via `meter.create_observable_gauge()` |
| "Daemon initializes OTel SDK" | Read entrypoints.py → calls configure_otel() | ✅ SDK initialized, but no spans to export |
| "Code locations have env vars" | `kubectl exec` env check | ✅ Env vars present, but no SDK → no export |

### Verification Techniques Used

1. **Read the startup chain** — `entrypoints.py` → `configure_otel()` vs the actual dagster source
2. **Search for span creation** — `grep -r "start_as_current_span\|start_span" dagster/` → 0 results
3. **Test connectivity** — Send test trace from within the pod to verify OTLP endpoint works
4. **Check ES for data** — Query `traces-apm*` indices to confirm what actually arrived
5. **Compare running config vs documentation** — `kubectl exec` env vs ConfigMap values

## When to Use This Pattern

- Documenting systems that are already deployed (not planned)
- When documentation exists but may be outdated
- When multiple components interact and claims about data flow need validation
- After user corrects an assumption built into the diagram (treat corrections as gold)

## SVG/Layout Notes from This Session

### Status Badges inside Boxes

Use small text badges to annotate actual state vs documented state:

| Badge | Meaning | SVG Example |
|-------|---------|-------------|
| `✅ 唯一真正發送數據` | Verified working | `fill="#22d3ee"` |
| `❌ 無 traces` | Verified broken/missing | `fill="#fb7185"` (rose) |
| `⏸️ 無 SDK` | Known gap, intentional | `fill="#94a3b8"` (slate) |

### Summary Panel at Bottom

Add a summary box at the bottom of the diagram (above the legend) that states the key 
reality-vs-documentation gaps in plain language. Use:
- Tinted background (rose/orange) to draw attention
- Concise bullet points, not paragraphs
- Actionable next step if applicable (e.g. "upgrade Dagster to 1.14+ for OTel")

### Iteration File Strategy

```
~/dagster-otel-architecture.html   ← Always overwrite with latest
```

No need to keep v1/v2/v3 files — the user only cares about the current correct version.
But DO document the iteration history in this reference so the pattern isn't lost.

## Output Files from This Session

- `~/dagster-otel-architecture.html` — Final correct diagram (v3)
- Data verified against: snd-dwh namespace, Dagster 1.12.19, Elastic APM 8.15.0

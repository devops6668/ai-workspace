# CI Troubleshooting Quick Reference

## Common Failure Patterns

### Test Failures
**Signatures:** `FAILED ... AssertionError`, `ModuleNotFoundError`
**Fix:** Update assertions, add missing deps, fix flaky tests

### Lint / Formatting
**Signatures:** `E302`, `E501`, `would reformat`
**Fix:** `black .`, `isort .`, `ruff check --fix .`

### Type Check (mypy/pyright)
**Signatures:** `incompatible type`, `Missing return statement`
**Fix:** Add type casts, fix signatures

### Build Failures
**Signatures:** `ModuleNotFoundError`, `Could not find a version`
**Fix:** Add missing deps, update pins

### Permission / Auth
**Signatures:** `Resource not accessible`, `403 Forbidden`
**Fix:** Update workflow permissions, verify secrets

### Timeouts
**Signatures:** `exceeded maximum execution time`
**Fix:** Add `timeout-minutes`, fix perf

### Docker
**Signatures:** `COPY failed: file not found`
**Fix:** Fix paths, update base image

## Auto-Fix Decision Tree

```
CI Failed
├── Test failure → update test or fix logic
├── Lint failure → run formatter, fix style
├── Type error → fix types
├── Build failure → add missing dep
├── Permission error → update workflow permissions
└── Timeout → investigate performance
```

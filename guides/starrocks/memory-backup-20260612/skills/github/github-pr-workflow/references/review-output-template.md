# Review Output Template

## For PR Summary Comment

```markdown
## Code Review Summary

**Verdict: [Approved ✅ | Changes Requested 🔴 | Reviewed 💬]** ([N] issues, [N] suggestions)

**PR:** #[number] — [title]
**Author:** @[username]
**Files changed:** [N] (+[additions] -[deletions])

### 🔴 Critical
- **file.py:line** — [description]. Suggestion: [fix].

### ⚠️ Warnings
- **file.py:line** — [description].

### 💡 Suggestions
- **file.py:line** — [description].

### ✅ Looks Good
- [aspect that was done well]

---
*Reviewed by Hermes Agent*
```

## Severity Guide

| Level | Icon | When to use | Blocks merge? |
|-------|------|-------------|---------------|
| Critical | 🔴 | Security vulnerabilities, data loss, crashes | Yes |
| Warning | ⚠️ | Bugs in non-critical paths, missing tests | Usually |
| Suggestion | 💡 | Style, refactoring, performance, docs | No |
| Looks Good | ✅ | Clean patterns, good test coverage | N/A |

## Inline Comment Prefixes

```
🔴 **Critical:** User input passed directly to SQL query.
⚠️ **Warning:** Error silently swallowed. Log it.
💡 **Suggestion:** Use a dict comprehension here.
✅ **Nice:** Good use of context manager.
```

## Verdict Decision

- **Approved** — Zero critical/warning items
- **Changes Requested** — Any critical or warning item
- **Reviewed** — Observations only (draft PRs)

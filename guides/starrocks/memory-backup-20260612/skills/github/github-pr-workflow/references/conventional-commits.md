# Conventional Commits Quick Reference

Format: `type(scope): description`

## Types

| Type | When to use | Example |
|------|------------|---------|
| `feat` | New feature | `feat(auth): add OAuth2 login flow` |
| `fix` | Bug fix | `fix(api): handle null response` |
| `refactor` | Restructuring, no behavior change | `refactor(db): extract query builder` |
| `docs` | Documentation only | `docs: update API examples` |
| `test` | Adding/updating tests | `test(auth): add integration tests` |
| `ci` | CI/CD configuration | `ci: add Python 3.12 to test matrix` |
| `chore` | Maintenance, dependencies | `chore: upgrade pytest` |
| `perf` | Performance improvement | `perf(search): add index on email` |
| `style` | Formatting, whitespace | `style: run black formatter` |
| `build` | Build system | `build: switch to hatch` |
| `revert` | Reverts a commit | `revert: revert "feat(auth): ..."` |

## Breaking Changes

Add `!` after type:
```
feat(api)!: change auth to bearer tokens
```

Or `BREAKING CHANGE:` footer.

## Linking Issues

```
Closes #42          # auto-closes on merge
Fixes #42           # same effect
Refs #42            # references only
```

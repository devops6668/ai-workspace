---
name: github-workflow
description: "Complete GitHub workflow: auth setup, repo management, PR lifecycle, code review, and issue management via gh CLI or REST."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [GitHub, Pull-Requests, CI/CD, Git, Automation, Merge, Issues, Code-Review, Repositories, Authentication]
    related_skills: []
---

# GitHub Workflow

Complete guide for all GitHub operations. Each section shows the `gh` way first, then the `git` + `curl` fallback for machines without `gh`.

## Sections

| Section | Covers |
|---------|--------|
| [Auth & Setup](#auth--setup) | Tokens, SSH keys, gh CLI login, credential helpers |
| [Repo Management](#repo-management) | Clone, create, fork, settings, releases, secrets, gists |
| [PR Lifecycle](#pr-lifecycle) | Branch, commit, push, create PR, CI monitoring, merge |
| [Code Review](#code-review) | Local review, PR review, inline comments, approve/request changes |
| [Issue Management](#issue-management) | Create, triage, label, assign, search, bulk operations |

---

## Auth & Setup

See [references/github-auth-guide.md](references/github-auth-guide.md) for the complete authentication setup reference (tokens, SSH, gh CLI, credential helpers, detection patterns).

---

## Repo Management

See [references/repo-management.md](references/repo-management.md) for cloning, creating, forking repos, branch protection, releases, secrets, gists, and comparing tags.

---

## PR Lifecycle

### Quick Auth Detection

```bash
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  AUTH=***  AUTH=***  if [ -z "$GITHUB_TOKEN" ]; then
    if [ -f ~/.hermes/.env ] && grep -q "^GITHUB_TOKEN=*** ~/.hermes/.env; then
      GITHUB_TOKEN=*** "^GITHUB_TOKEN=*** ~/.hermes/.env | head -1 | cut -d= -f2 | tr -d '\n\r')
    elif grep -q "github.com" ~/.git-credentials 2>/dev/null; then
      GITHUB_TOKEN=*** "github.com" ~/.git-credentials 2>/dev/null | head -1 | sed 's|https://[^:]*:\([^@]*\}@.*|1|')
    fi
  fi
fi
echo "Using: $AUTH"
```

### Extracting Owner/Repo

```bash
REMOTE_URL=$(git remote get-url origin)
OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
```

### 1. Branch Creation

```bash
git fetch origin && git checkout main && git pull origin main
git checkout -b feat/add-user-authentication
```

Naming: `feat/`, `fix/`, `refactor/`, `docs/`, `ci/` prefix

### 2. Committing

```bash
git add .
git commit -m "feat: add JWT-based user authentication"
```

### 3. Create PR

```bash
git push -u origin HEAD
gh pr create --title "feat: add JWT-based user authentication" --body "## Summary\n- Adds login/register endpoints\n\nCloses #42"
```

### 4. Monitor CI

```bash
gh pr checks --watch
```

### 5. Auto-Fix CI Loop

Check CI → read logs → fix → commit & push → re-check (up to 3 attempts)

### 6. Merge

```bash
gh pr merge --squash --delete-branch
```

---

## Code Review

See [references/code-review.md](references/code-review.md) for local pre-push review and PR review workflows.

---

## Issue Management

See [references/issue-management.md](references/issue-management.md) for issue operations.

---

## Quick Reference

| Action | gh | git + curl |
|--------|-----|-----------|
| Clone | `gh repo clone o/r` | `git clone https://github.com/o/r.git` |
| Create PR | `gh pr create ...` | `curl POST /repos/o/r/pulls` |
| Review | `gh pr review N --approve` | `curl POST /repos/o/r/pulls/N/reviews` |
| Issues | `gh issue list` | `curl GET /repos/o/r/issues` |
| Merge | `gh pr merge --squash` | `curl PUT /repos/o/r/pulls/N/merge` |
| Releases | `gh release create v1.0` | `curl POST /repos/o/r/releases` |
| Secrets | `gh secret set KEY` | `curl PUT /repos/o/r/actions/secrets/KEY` |

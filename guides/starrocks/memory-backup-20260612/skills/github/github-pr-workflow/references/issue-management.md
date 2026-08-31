# Issue Management Reference

## Viewing Issues

```bash
gh issue list --state open --label "bug"
gh issue list --assignee @me
gh issue list --search "authentication error" --state all

# With curl
curl -s -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/$OWNER/$REPO/issues?state=open&per_page=20"
```

## Creating Issues

```bash
gh issue create --title "Login redirect ignores ?next= parameter" \
  --body "## Description\nAfter logging in, users always land on /dashboard.\n\n## Steps to Reproduce\n1. Navigate to /settings while logged out\n2. Get redirected to /login?next=/settings\n3. Log in\n4. Actual: redirected to /dashboard" \
  --label "bug,backend" --assignee "username"
```

## Managing Issues

```bash
gh issue edit 42 --add-label "priority:high,bug"
gh issue edit 42 --remove-label "needs-triage"
gh issue edit 42 --add-assignee username
gh issue comment 42 --body "Root cause identified. Working on fix."
gh issue close 42
gh issue reopen 42
```

## Bulk Operations

```bash
gh issue list --label "wontfix" --json number --jq '.[].number' | \
  xargs -I {} gh issue close {} --reason "not planned"
```

## Templates

- **Bug report**: `templates/bug-report.md`
- **Feature request**: `templates/feature-request.md`

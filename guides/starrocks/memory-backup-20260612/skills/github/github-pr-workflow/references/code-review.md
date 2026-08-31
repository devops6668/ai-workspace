# Code Review Reference

## Local (Pre-Push) Review

```bash
git diff main...HEAD --stat
git log main..HEAD --oneline
git diff main...HEAD | grep -n "print(\\|console\\.log\\|TODO\\|FIXME\\|HACK\\|XXX\\|debugger"
git diff main...HEAD | grep -in "password\\|secret\\|api_key\\|token.*=\\|private_key"
```

## Review Checklist

- **Correctness**: Edge cases, error paths
- **Security**: No hardcoded secrets, input validation, no SQLi/XSS
- **Quality**: Clear naming, no duplication, focused functions
- **Testing**: New paths covered
- **Performance**: No N+1 queries or blocking ops

## PR Review

```bash
git fetch origin pull/123/head:pr-123 && git checkout pr-123
gh pr review 123 --approve --body "LGTM!"
gh pr review 123 --request-changes --body "See inline comments."
```

## Inline Comments (curl)

```bash
HEAD_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['sha'])")
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
  -d "{\"body\":\"Fix here.\",\"path\":\"src/auth.py\",\"commit_id\":\"$HEAD_SHA\",\"line\":45}"
```

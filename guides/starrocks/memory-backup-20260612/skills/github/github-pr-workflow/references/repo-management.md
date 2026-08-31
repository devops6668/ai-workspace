# Repository Management Reference

## Cloning

```bash
gh repo clone owner/repo-name
git clone --depth 1 https://github.com/owner/repo-name.git  # shallow
```

## Creating Repos

```bash
gh repo create my-new-project --public --clone
gh repo create my-new-project --private --description "A tool" --license MIT

# With curl
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/user/repos \
  -d '{"name":"my-new-project","description":"A tool","private":false,"auto_init":true}'
```

## Forking

```bash
gh repo fork owner/repo-name --clone
# Manual: curl POST /repos/o/r/forks, then git clone + git remote add upstream
```

## Settings

```bash
gh repo edit --description "Updated" --visibility public
gh repo edit --enable-wiki=false --enable-issues=true
curl -s -X PATCH -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$OWNER/$REPO \
  -d '{"description":"Updated","has_wiki":false,"has_issues":true}'
```

## Branch Protection

```bash
curl -s -X PUT -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$OWNER/$REPO/branches/main/protection \
  -d '{"required_status_checks":{"strict":true},"required_pull_request_reviews":{"required_approving_review_count":1}}'
```

## Releases

```bash
gh release create v1.0.0 --title "v1.0.0" --generate-notes
gh release list
# With curl
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$OWNER/$REPO/releases \
  -d '{"tag_name":"v1.0.0","name":"v1.0.0","generate_release_notes":true}'
```

## Secrets (GitHub Actions)

```bash
gh secret set API_KEY --body "value"
gh secret list
gh secret delete API_KEY
```

Note: API requires encryption with repo's public key — `gh secret` is dramatically simpler.

## Actions Workflows

```bash
gh workflow list
gh run list --limit 10
gh run view <RUN_ID>
gh run rerun <RUN_ID> --failed
```

## Comparing Tags

```bash
git log v1.0.0..v1.1.0 --oneline
git diff v1.0.0..v1.1.0 --stat
```

Shallow clones need explicit tag fetch: `git fetch origin refs/tags/v1.0.0:refs/tags/v1.0.0`

## Gists

```bash
gh gist create script.py --public --desc "Useful script"
```

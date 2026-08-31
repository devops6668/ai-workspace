# GitHub REST API Cheatsheet

Base URL: `https://api.github.com`
All requests need: `-H "Authorization: token $GITHUB_TOKEN"`

## Repositories
| Action | Method | Endpoint |
|--------|--------|----------|
| Get repo | GET | `/repos/{owner}/{repo}` |
| Create repo | POST | `/user/repos` or `/orgs/{org}/repos` |
| Update repo | PATCH | `/repos/{owner}/{repo}` |
| Fork | POST | `/repos/{owner}/{repo}/forks` |
| List topics | GET | `/repos/{owner}/{repo}/topics` |

## Pull Requests
| Action | Method | Endpoint |
|--------|--------|----------|
| List PRs | GET | `/repos/{owner}/{repo}/pulls?state=open` |
| Create PR | POST | `/repos/{owner}/{repo}/pulls` |
| Merge PR | PUT | `/repos/{owner}/{repo}/pulls/{number}/merge` |
| List files | GET | `/repos/{owner}/{repo}/pulls/{number}/files` |
| Create review | POST | `/repos/{owner}/{repo}/pulls/{number}/reviews` |
| Inline comment | POST | `/repos/{owner}/{repo}/pulls/{number}/comments` |

## Issues
| Action | Method | Endpoint |
|--------|--------|----------|
| List issues | GET | `/repos/{owner}/{repo}/issues?state=open` |
| Create issue | POST | `/repos/{owner}/{repo}/issues` |
| Update issue | PATCH | `/repos/{owner}/{repo}/issues/{number}` |
| Add labels | POST | `/repos/{owner}/{repo}/issues/{number}/labels` |
| Remove label | DELETE | `/repos/{owner}/{repo}/issues/{number}/labels/{name}` |
| Add assignees | POST | `/repos/{owner}/{repo}/issues/{number}/assignees` |
| Search | GET | `/search/issues?q={query}+repo:{owner}/{repo}` |

## CI / Actions
| Action | Method | Endpoint |
|--------|--------|----------|
| List workflows | GET | `/repos/{owner}/{repo}/actions/workflows` |
| List runs | GET | `/repos/{owner}/{repo}/actions/runs` |
| Download logs | GET | `/repos/{owner}/{repo}/actions/runs/{id}/logs` |
| Re-run | POST | `/repos/{owner}/{repo}/actions/runs/{id}/rerun` |
| Commit status | GET | `/repos/{owner}/{repo}/commits/{sha}/status` |

## Releases
| Action | Method | Endpoint |
|--------|--------|----------|
| List releases | GET | `/repos/{owner}/{repo}/releases` |
| Create release | POST | `/repos/{owner}/{repo}/releases` |
| Upload asset | POST | `uploads.github.com/.../releases/{id}/assets` |

## Secrets
| Action | Method | Endpoint |
|--------|--------|----------|
| Get public key | GET | `/repos/{owner}/{repo}/actions/secrets/public-key` |
| Set secret | PUT | `/repos/{owner}/{repo}/actions/secrets/{name}` |
| Delete secret | DELETE | `/repos/{owner}/{repo}/actions/secrets/{name}` |

## Branch Protection
| Action | Method | Endpoint |
|--------|--------|----------|
| Get protection | GET | `/repos/{owner}/{repo}/branches/{branch}/protection` |
| Set protection | PUT | same path |

## Pagination
- `?per_page=100` (max), `?page=2`
- Check `Link` header for `rel="next"`

## Rate Limits
- Authenticated: 5,000 requests/hour
- Check: `curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/rate_limit`

## Common Patterns

```bash
# GET
curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/$GH_OWNER/$GH_REPO

# POST
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$GH_OWNER/$GH_REPO/issues -d '{"title":"..."}'

# PATCH
curl -s -X PATCH -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$GH_OWNER/$GH_REPO/issues/42 -d '{"state":"closed"}'

# DELETE
curl -s -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/repos/$GH_OWNER/$GH_REPO/issues/42/labels/bug

# Parse JSON
curl -s ... | python3 -c "import sys,json; print(json.load(sys.stdin)['field'])"
```

# GitHub Authentication Setup

Two paths: `gh` CLI (if installed) or `git` with HTTPS tokens / SSH keys.

## Detection Flow

```bash
git --version
gh --version 2>/dev/null || echo "gh not installed"
gh auth status 2>/dev/null || echo "gh not authenticated"
```

1. If `gh auth status` shows authenticated → use `gh`
2. If `gh` installed but not authenticated → token-based `gh auth login`
3. If `gh` not installed → HTTPS token or SSH key method

## Method 1: HTTPS with Personal Access Token (Recommended)

Create token at https://github.com/settings/tokens — scopes: `repo`, `workflow`, `read:org`

```bash
# Store credentials persistently
git config --global credential.helper store

# Set identity
git config --global user.name "Their Name"
git config --global user.email "their-email@example.com"

# Verify
git ls-remote https://github.com/<username>/<any-repo>.git
```

## Method 2: SSH Key

```bash
ssh-keygen -t ed25519 -C "email@example.com" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub  # Add to https://github.com/settings/keys

# Rewrite HTTPS URLs to SSH
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

## Method 3: gh CLI Authentication

```bash
gh auth login                    # Interactive browser login
echo "<TOKEN>" | gh auth login --with-token  # Headless

gh auth setup-git                # Configure git credentials through gh
gh auth status                   # Verify
```

## Using the API Without gh

```bash
export GITHUB_TOKEN=*** Extract from git credential store
grep "github.com" ~/.git-credentials | head -1 | sed 's|https://[^:]*:\([^@]*\}@.*|1|'
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `git push` asks for password | Use a PAT, not a password |
| `remote: Permission denied` | Token lacks `repo` scope |
| `ssh: port 22 refused` | Use `Port 443` + `ssh.github.com` in `~/.ssh/config` |
| `gh: command not found` | Use git-only Method 1 |
| Multiple GitHub accounts | SSH with different keys per host alias in `~/.ssh/config` |

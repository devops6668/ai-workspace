---
name: hermes-custom-providers
description: "Add and configure custom OpenAI-compatible API endpoints as providers in Hermes Agent."
version: 1.0.0
author: Hermes Agent
created_by: agent
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [hermes, configuration, providers, custom-endpoint, openai-compatible]
    homepage: https://hermes-agent.nousresearch.com/docs/integrations/providers
---

# Hermes Custom Providers

How to add custom OpenAI-compatible API endpoints (like Agnes AI, or any service offering an OpenAI-format `/v1` API) as providers in Hermes Agent.

## The Pattern

For any OpenAI-compatible endpoint, configure three things:

```bash
hermes config set model.base_url   "<api_base_url>"   # e.g. https://apihub.example.com/v1
hermes config set model.api_key    "<your_api_key>"    # stored in config.yaml (secrets are acceptable per docs)
hermes config set model.default    "<model_id>"        # exact model ID from the API
hermes config set model.provider   "openai"            # OpenAI-compatible format
```

### Why provider="openai"

Custom endpoints almost always implement the OpenAI chat completions format (`/v1/chat/completions`). Use `provider: openai` — Hermes uses the OpenAI client code path for these, which works with any API that mirrors the OpenAI schema.

## Steps

1. **Find the base URL.** It must end in `/v1` (e.g. `https://apihub.example.com/v1`). The `/v1` is the standard prefix for the OpenAI-compatible route namespace.

2. **Check the actual model list.** Always verify the exact model ID from the API before committing:

   ```bash
   curl -s "<base_url>/models" -H "Authorization: Bearer <key>" | jq .
   ```

   Model IDs are case-sensitive. The ID the user gives you may differ from what the API returns (e.g. user says `Agnes-2.0-Flash` but API returns `agnes-2.0-flash`). Use the API's exact spelling.

3. **Set the config values** using `hermes config set`. The API key is stored directly in `config.yaml` — this is the documented approach for custom endpoints (see `hermes-agent` skill, Providers table: "Custom endpoint" = `model.base_url` + `model.api_key` in config.yaml).

4. **Verify** by checking `hermes config` — the Model section should show `base_url`, `default`, `provider`, and `api_key`.

## Switching Back

To restore the previous provider:

```bash
hermes config set model.base_url   ""                  # clear custom base URL
hermes config set model.provider   "<original>"        # e.g. deepseek, anthropic, openrouter
hermes config set model.default    "<original_model>"  # e.g. deepseek-v4-flash
```

Note: `hermes config set model.api_key ""` clears the custom key from config.yaml.

## Pitfalls

- **Model IDs are case-sensitive.** Always use the exact ID from `curl <base_url>/models`. Capitalization, hyphens, and underscores must match exactly.
- **Base URL must end in `/v1`.** Omitting `/v1` causes 404 errors because the API routes are under that prefix.
- **Config file is security-hardened.** Tools like `patch` and `write_file` refuse to write to `config.yaml` directly. Always use `hermes config set` or `hermes config edit` (opens `$EDITOR`).
- **Changes take effect on next session.** The model config is read at startup. Use `/model` slash command to switch mid-session, or start a new `hermes` process.
- **Key appears redacted in output.** `hermes config` shows the key as `sk-LF3...XYZ` — this is intentional secret redaction, not data loss. The full key is stored.
- **`hermes config set model.api_key ""` empties the field.** It does not remove the key from yaml (it sets it to `''`). This is fine.

## See Also

- `hermes-agent` skill — general Hermes configuration reference
- `references/agnes-ai-custom-provider.md` — session-specific setup for Agnes AI API

# Agnes AI Custom Provider Setup

Configured on 2026-06-04 for user Paul Wong.

## Provider Details

| Field | Value |
|-------|-------|
| Provider name | `openai` (OpenAI-compatible format) |
| Base URL | `https://apihub.agnes-ai.com/v1` |
| Default model | `agnes-2.0-flash` |
| API key | Stored in `model.api_key` in `config.yaml` |

## Available Models (from `/v1/models`)

| Model ID | Type |
|----------|------|
| `agnes-1.5-flash` | Chat |
| `agnes-2.0-flash` | Chat (configured as default) |
| `agnes-image-2.0-flash` | Image generation |
| `agnes-image-2.1-flash` | Image generation |
| `agnes-video-v2.0` | Video |

All use `supported_endpoint_types: ["openai"]`.

## Key Discovery

The user specified the model as **Agnes-2.0-Flash** (title case), but the API returns **agnes-2.0-flash** (lowercase). This is a critical pitfall — model IDs are case-sensitive.

## Config Commands Used

```bash
hermes config set model.base_url "https://apihub.agnes-ai.com/v1"
hermes config set model.api_key "sk-LF3bHyTSsVA9oBTydC25Zh6z8Z482oaC9awflWu4gYVCUQUn"
hermes config set model.default "Agnes-2.0-Flash"    # Initially set with user's spelling
hermes config set model.default "agnes-2.0-flash"     # Corrected after API check
hermes config set model.provider "openai"
```

## Verification

```bash
curl -s https://apihub.agnes-ai.com/v1/models -H "Authorization: Bearer $KEY" | jq
```

## Switching Back to DeepSeek

```bash
hermes config set model.base_url ""
hermes config set model.provider deepseek
hermes config set model.default deepseek-v4-flash
```

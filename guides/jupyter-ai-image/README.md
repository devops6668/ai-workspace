# Jupyter AI Image

Docker image for JupyterHub singleuser pods with AI magic commands.

## What's Included

| Package | Version | Purpose |
|---------|---------|---------|
| jupyter-ai-magic-commands | 0.0.3 | %%ai cell magic, %ai line magic |
| jupyter-ai-litellm | 0.0.2 | LiteLLM model abstraction |
| litellm | <=1.82.6 | OpenAI-compatible proxy client |
| pandas | latest | Data analysis |
| numpy | latest | Numerical computing |
| matplotlib | latest | Plotting |
| scikit-learn | latest | Machine learning |

## Build

```bash
cd /home/paul/Documents/ai-workspace/demo-apps/jupyter-ai-image

docker build -t quay.io/paulwong6668/jupyter-ai:1.0 .
docker push quay.io/paulwong6668/jupyter-ai:1.0
```

## Test Locally

```bash
docker run --rm -p 8888:8888 \
  -e OPENAI_API_KEY="sk-your-litellm-master-key" \
  -e OPENAI_API_BASE="http://192.168.89.61:31275/v1" \
  quay.io/paulwong6668/jupyter-ai:1.0
```

Then open http://localhost:8888 and run:

```python
%load_ext jupyter_ai_magic_commands

import os
print("API Base:", os.environ.get("OPENAI_API_BASE"))

%ai list
```

## Use in JupyterHub

Add to Helm values:

```yaml
singleuser:
  image:
    name: quay.io/paulwong6668/jupyter-ai
    tag: "1.0"
  profileList:
    - display_name: "AI Coding"
      description: "Jupyter AI with LiteLLM magic commands"
      kubespawner_override:
        image: quay.io/paulwong6668/jupyter-ai:1.0
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| OPENAI_API_KEY | Yes | litellm master key |
| OPENAI_API_BASE | Yes | litellm endpoint URL |

## Notes

- `jupyter-ai-litellm` pins `litellm<=1.82.6` — your cluster runs v1.85.1
- If litellm API changes break compatibility, pin litellm in Dockerfile:
  ```
  RUN pip install litellm==1.82.6
  ```
- Base image: `quay.io/jupyter/minimal-notebook:python-3.11`

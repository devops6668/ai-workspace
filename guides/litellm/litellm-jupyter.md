# LiteLLM Example

## Load Jupyter ai magic command
```
%load_ext jupyter_ai_magic_commands
```

## Set AI api key and end point
```
import os
os.environ["OPENAI_API_KEY"] = "sk-vkwp4cHLY-2MUGz_Yo66bw"
os.environ["OPENAI_API_BASE"] = "http://192.168.89.61:31275/v1"
```

## Verify AI api key and end point
```
import os
print(os.environ.get("OPENAI_API_KEY", "NOT SET"))
print(os.environ.get("OPENAI_API_BASE", "NOT SET"))
```

## Register AI
```
%ai alias ornith custom_openai/ornith
or
%ai alias ornith custom_openai/ornith --api-base http://192.168.89.61:31275/v1
```

# Start Chat
```
Chat cmd
%%ai ornith
message
```



---
---

# Agnes Example

## Load Jupyter ai magic command
```
%load_ext jupyter_ai_magic_commands
```

## Set AI api key and end point
```
import os
os.environ["OPENAI_API_KEY"] = "sk-vkwp4cHLY-2MUGz_Yo66bw"
os.environ["OPENAI_API_BASE"] = "https://apihub.agnes-ai.com/v1"
```

## Verify AI api key and end point
```
import os
print(os.environ.get("OPENAI_API_KEY", "NOT SET"))
print(os.environ.get("OPENAI_API_BASE", "NOT SET"))
```

# Register AI
```
%ai alias fast-agnes openai/agnes-2.0-flash 

or

%ai alias fast-agnes openai/agnes-2.0-flash --api-base https://apihub.agnes-ai.com/v1

```

# Start Chat
```
Chat cmd
%%ai fast-agnes
message
```

# Other 
```
%ai providers
%ai list
```

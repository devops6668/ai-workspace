def _jupyter_server_proxy_servers():
    return {
        "vscode": {
            "command": [
                "code-server",
                "--bind-addr=127.0.0.1:{port}",
                "--auth=none",
                "--disable-update-check",
                "--disable-file-uploads",
                "--disable-file-downloads",
                "/home/jovyan",
            ],
            "timeout": 30,
            "new_browser_window": True,
            "launcher_entry": {
                "enabled": True,
                "title": "VS Code",
                "path_info": "vscode",
            },
        }
    }

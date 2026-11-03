#!/usr/bin/env python3
"""为界面截图准备一份有代表性的隔离数据。"""
import json
import pathlib
import sys
import uuid

home = pathlib.Path(sys.argv[1])
support = home / "AppData" / "Roaming" / "ModelBar"
support.mkdir(parents=True, exist_ok=True)
for directory in (".codex", ".config/opencode", ".local/bin"):
    (home / directory).mkdir(parents=True, exist_ok=True)
for binary in ("claude.exe", "codex.exe", "pi.exe", "grok.exe"):
    (home / ".local" / "bin" / binary).write_text("")
first, second = str(uuid.uuid4()), str(uuid.uuid4())
probe = {"models": "Ok", "chat": "Ok", "responses": "Failed", "messages": "Failed", "latencyMs": 86, "testedAt": "2026-11-03T00:00:00+00:00"}
state = {
    "endpoints": [
        {"id": first, "name": "qoder", "baseUrl": "https://api.example.com/v1", "effort": "High", "hasKey": True, "selectedModel": "lite",
         "probe": probe,
         "models": [{"id": "lite", "contextLength": 128000, "supportsReasoning": True},
                    {"id": "ultimate-large", "contextLength": 1000000, "supportsReasoning": True},
                    {"id": "efficient", "contextLength": 64000}]},
        {"id": second, "name": "DeepSeek", "baseUrl": "https://api.deepseek.com/v1", "effort": "Automatic", "hasKey": True, "selectedModel": "deepseek-chat",
         "models": [{"id": "deepseek-chat", "contextLength": 64000}]},
    ],
    "activeEndpointId": first,
    "enabledTools": ["OpenCode", "Codex"],
    "originals": {},
    "bridgeEnabled": False,
}
(support / "state.json").write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")

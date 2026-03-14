#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path


def main():
    plugin_id = sys.argv[1] if len(sys.argv) > 1 else ""
    config_path = Path(os.environ.get("OPENCLAW_CONFIG", os.path.expanduser("~/.openclaw/openclaw.json")))
    try:
        with config_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return

    plugins = payload.get("plugins") if isinstance(payload, dict) else {}
    entries = plugins.get("entries") if isinstance(plugins, dict) else {}
    entry = entries.get(plugin_id) if isinstance(entries, dict) else {}
    config = entry.get("config") if isinstance(entry, dict) else {}
    configured = any(bool(str(value or "").strip()) for value in (config or {}).values())
    print(json.dumps({
        "ok": True,
        "plugin": plugin_id,
        "enabled": bool(entry.get("enabled")) if isinstance(entry, dict) else False,
        "configured": configured,
        "config_keys": sorted(list((config or {}).keys())),
    }))


if __name__ == "__main__":
    main()

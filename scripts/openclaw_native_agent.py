#!/usr/bin/env python3
"""Register or update a native OpenClaw multi-agent entry in the root config.

This script is the first implementation step away from the current
"one OpenClaw home per agent" spawn model. It mutates a single root
`openclaw.json` so a non-main agent can live under the same OpenClaw
installation as `main`.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return data if isinstance(data, dict) else {}


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def unique_mention_patterns(agent_id: str, display_name: str, extras: list[str]) -> list[str]:
    patterns: list[str] = []
    for value in [display_name, agent_id, *extras]:
        text = (value or "").strip().lower()
        if text and text not in patterns:
            patterns.append(text)
    return patterns


def ensure_agent_entry(agents_cfg: dict, args: argparse.Namespace) -> None:
    entries = agents_cfg.get("list")
    if not isinstance(entries, list):
        entries = []

    workspace = str(args.workspace)
    agent_dir = str(args.agent_dir)
    display_name = args.display_name or args.agent_id

    entry = None
    for item in entries:
        if isinstance(item, dict) and item.get("id") == args.agent_id:
            entry = item
            break

    if entry is None:
        entry = {"id": args.agent_id}
        entries.append(entry)

    entry["name"] = display_name
    entry["workspace"] = workspace
    entry["agentDir"] = agent_dir

    identity = entry.get("identity")
    if not isinstance(identity, dict):
        identity = {}
    identity["name"] = display_name
    entry["identity"] = identity

    group_chat = entry.get("groupChat")
    if not isinstance(group_chat, dict):
        group_chat = {}
    group_chat["mentionPatterns"] = unique_mention_patterns(
        args.agent_id,
        display_name,
        args.mention_pattern,
    )
    entry["groupChat"] = group_chat

    tools = entry.get("tools")
    if not isinstance(tools, dict):
        tools = {}
    if args.tool_profile:
        tools["profile"] = args.tool_profile
    entry["tools"] = tools

    agents_cfg["list"] = entries


def ensure_discord_account(channels_cfg: dict, args: argparse.Namespace) -> None:
    discord = channels_cfg.get("discord")
    if not isinstance(discord, dict):
        discord = {}

    accounts = discord.get("accounts")
    if not isinstance(accounts, dict):
        accounts = {}

    account = accounts.get(args.account_id)
    if not isinstance(account, dict):
        account = {}

    account["name"] = args.display_name or args.agent_id
    account["token"] = args.discord_token
    # Agents need to receive instructions from Syntella's Discord bot in their inbox channels.
    account["allowBots"] = True
    account["groupPolicy"] = "allowlist"
    account["guilds"] = {
        args.guild_id: {
            "requireMention": False,
            "channels": {
                args.channel_id: {
                    "allow": True,
                    "requireMention": False,
                }
            },
        }
    }
    account["intents"] = {
        "presence": False,
        "guildMembers": False,
    }

    accounts[args.account_id] = account
    discord["accounts"] = accounts
    channels_cfg["discord"] = discord


def ensure_binding(config: dict, args: argparse.Namespace) -> None:
    bindings = config.get("bindings")
    if not isinstance(bindings, list):
        bindings = []

    existing = None
    for item in bindings:
        if isinstance(item, dict) and item.get("agentId") == args.agent_id:
            existing = item
            break

    binding = {
        "agentId": args.agent_id,
        "match": {
            "channel": "discord",
            "accountId": args.account_id,
        },
    }
    if existing is None:
        bindings.append(binding)
    else:
        existing.clear()
        existing.update(binding)

    config["bindings"] = bindings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=os.path.expanduser("~/.openclaw/openclaw.json"))
    parser.add_argument("--agent-id", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--agent-dir", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--discord-token", required=True)
    parser.add_argument("--guild-id", required=True)
    parser.add_argument("--channel-id", required=True)
    parser.add_argument("--tool-profile", default="")
    parser.add_argument("--mention-pattern", action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser()
    args.workspace = Path(args.workspace).expanduser()
    args.agent_dir = Path(args.agent_dir).expanduser()

    config = load_json(config_path)

    agents_cfg = config.get("agents")
    if not isinstance(agents_cfg, dict):
        agents_cfg = {}
    ensure_agent_entry(agents_cfg, args)
    config["agents"] = agents_cfg

    channels_cfg = config.get("channels")
    if not isinstance(channels_cfg, dict):
        channels_cfg = {}
    ensure_discord_account(channels_cfg, args)
    config["channels"] = channels_cfg

    ensure_binding(config, args)

    ensure_dir(args.workspace)
    ensure_dir(args.agent_dir)
    save_json(config_path, config)

    print(
        json.dumps(
            {
                "ok": True,
                "config": str(config_path),
                "agent_id": args.agent_id,
                "workspace": str(args.workspace),
                "agent_dir": str(args.agent_dir),
                "account_id": args.account_id,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

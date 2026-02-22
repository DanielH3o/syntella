#!/usr/bin/env bash
set -euo pipefail

# openclaw-droplet-kit bootstrap
# Target: Ubuntu 22.04/24.04 on DigitalOcean

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run as a normal sudo user (not root)."
  echo "Tip: su - openclaw"
  exit 1
fi

say() { echo -e "\n==> $*"; }

DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
DISCORD_TARGET="${DISCORD_TARGET:-}"
# Accept common aliases to reduce bootstrap env mistakes.
DISCORD_HUMAN_ID="${DISCORD_HUMAN_ID:-${DISCORD_USER_ID:-${DISCORD_HUMAN:-}}}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
DISCORD_GUILD_ID=""
DISCORD_CHANNEL_ID=""
FRONTEND_ENABLED="${FRONTEND_ENABLED:-1}"
FRONTEND_URL=""
# Lock frontend to this source IP/CIDR (required when FRONTEND_ENABLED=1), e.g. "203.0.113.10" or "203.0.113.0/24".
FRONTEND_ALLOWED_IP="${FRONTEND_ALLOWED_IP:-}"
# Exec approval posture for autonomous Discord provisioning:
# - full: no interactive exec approvals (default for this droplet kit)
# - strict: leave host approval posture unchanged
EXEC_APPROVAL_MODE="${EXEC_APPROVAL_MODE:-full}"
KIWI_EXEC_TIMEOUT_SECONDS="${KIWI_EXEC_TIMEOUT_SECONDS:-60}"
KIWI_EXEC_MAX_OUTPUT_BYTES="${KIWI_EXEC_MAX_OUTPUT_BYTES:-16384}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT:-8787}"

# OPENCLAW_HOME should point to the user home base (e.g. /home/openclaw), not ~/.openclaw.
# If inherited incorrectly from the environment, normalize it before any `openclaw config` calls.
if [[ -n "${OPENCLAW_HOME:-}" && "$OPENCLAW_HOME" == */.openclaw ]]; then
  export OPENCLAW_HOME="${OPENCLAW_HOME%/.openclaw}"
fi

append_path_if_missing() {
  local rc_file="$1"
  local path_line="$2"
  [[ -f "$rc_file" ]] || touch "$rc_file"
  grep -Fq "$path_line" "$rc_file" || echo "$path_line" >> "$rc_file"
}

ensure_openclaw_on_path() {
  local npm_global_bin="$HOME/.npm-global/bin"
  local path_line='export PATH="$HOME/.npm-global/bin:$PATH"'

  # Persist PATH fix for future non-interactive/login shells even if openclaw is currently found.
  append_path_if_missing "$HOME/.bashrc" "$path_line"
  append_path_if_missing "$HOME/.profile" "$path_line"
  append_path_if_missing "$HOME/.zshrc" "$path_line"

  if [[ -d "$npm_global_bin" ]] && [[ ":$PATH:" != *":$npm_global_bin:"* ]]; then
    export PATH="$npm_global_bin:$PATH"
    hash -r || true
  fi

  command -v openclaw >/dev/null 2>&1
}

say "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates gnupg lsb-release iproute2 procps lsof python3

if ! command -v openclaw >/dev/null 2>&1; then
  say "Installing OpenClaw (skip interactive onboarding)"
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
  # shellcheck disable=SC1090
  [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" || true
fi

if ! ensure_openclaw_on_path; then
  echo "OpenClaw appears installed but is not on PATH."
  echo "Try: export PATH=\"$HOME/.npm-global/bin:$PATH\""
  echo "Then re-run this script."
  exit 1
fi

OPENCLAW_BIN="$(command -v openclaw)"
NODE_BIN="$(command -v node || true)"
OPENCLAW_MJS="$(readlink -f "$OPENCLAW_BIN" 2>/dev/null || realpath "$OPENCLAW_BIN" 2>/dev/null || echo "$OPENCLAW_BIN")"
oc() { "$OPENCLAW_BIN" "$@"; }

say "Pre-creating OpenClaw state dirs to avoid first-run prompts"
mkdir -p "$HOME/.openclaw"
chmod 700 "$HOME/.openclaw" || true
mkdir -p "$HOME/.openclaw/agents/main/sessions"
mkdir -p "$HOME/.openclaw/credentials"
mkdir -p "$HOME/.openclaw/workspace"

ensure_gateway_token() {
  local token=""

  token="$(oc config get gateway.auth.token 2>/dev/null | tr -d '"[:space:]' || true)"
  if [[ -n "$token" && "$token" != "null" ]]; then
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 24)"
  elif command -v python3 >/dev/null 2>&1; then
    token="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
)"
  else
    token="$(date +%s)-$RANDOM-$RANDOM"
  fi

  oc config set gateway.auth.token "$token"
}

parse_discord_target() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr -d '[:space:]')"
  cleaned="${cleaned#guild:}"
  cleaned="${cleaned#guild=}"
  cleaned="${cleaned#g:}"

  local guild=""
  local channel=""

  if [[ "$cleaned" == *"/"* ]]; then
    guild="${cleaned%%/*}"
    channel="${cleaned##*/}"
    channel="${channel#channel:}"
    channel="${channel#channel=}"
    channel="${channel#c:}"
  elif [[ "$cleaned" == *":"* ]]; then
    guild="${cleaned%%:*}"
    channel="${cleaned##*:}"
  fi

  if [[ -z "$guild" || -z "$channel" || ! "$guild" =~ ^[0-9]+$ || ! "$channel" =~ ^[0-9]+$ ]]; then
    echo "Invalid DISCORD_TARGET: '$raw'"
    echo "Expected one of:"
    echo "  DISCORD_TARGET=\"<guildId>/<channelId>\""
    echo "  DISCORD_TARGET=\"<guildId>:<channelId>\""
    echo "  DISCORD_TARGET=\"guild:<guildId>/channel:<channelId>\""
    exit 1
  fi

  DISCORD_GUILD_ID="$guild"
  DISCORD_CHANNEL_ID="$channel"
}

require_discord_inputs() {
  if [[ -z "$DISCORD_BOT_TOKEN" ]]; then
    echo "Missing DISCORD_BOT_TOKEN."
    echo "Export DISCORD_BOT_TOKEN before running this script."
    exit 1
  fi

  if [[ -z "$DISCORD_TARGET" ]]; then
    echo "Missing DISCORD_TARGET."
    echo "Example: DISCORD_TARGET=\"123456789012345678/987654321098765432\""
    exit 1
  fi

  if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "Missing OPENAI_API_KEY."
    echo "Export OPENAI_API_KEY before running this script."
    exit 1
  fi

  # Normalize Discord user id (accept raw id, <@id>, <@!id>, or aliases).
  DISCORD_HUMAN_ID="$(echo "${DISCORD_HUMAN_ID}" | tr -cd '0-9')"
  if [[ -z "$DISCORD_HUMAN_ID" || ! "$DISCORD_HUMAN_ID" =~ ^[0-9]+$ ]]; then
    echo "Missing or invalid DISCORD_HUMAN_ID."
    echo "Example: DISCORD_HUMAN_ID=\"123456789012345678\""
    echo "(Aliases accepted: DISCORD_USER_ID, DISCORD_HUMAN)"
    exit 1
  fi

  parse_discord_target "$DISCORD_TARGET"
}

configure_discord_channel() {
  local config_file="$HOME/.openclaw/openclaw.json"

  python3 - "$config_file" "$DISCORD_BOT_TOKEN" "$DISCORD_GUILD_ID" "$DISCORD_CHANNEL_ID" "$DISCORD_HUMAN_ID" <<'PY'
import json
import os
import sys

config_path, token, guild_id, channel_id, human_id = sys.argv[1:6]

cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

channels = cfg.setdefault("channels", {})
discord = channels.setdefault("discord", {})
discord["enabled"] = True
discord["token"] = token
discord["groupPolicy"] = "allowlist"
# Allow receiving bot-authored Discord messages (own self-messages are still filtered by OpenClaw).
discord["allowBots"] = True

# DM policy: only allow DMs from the configured human.
dm_cfg = discord.get("dm")
if not isinstance(dm_cfg, dict):
    dm_cfg = {}
dm_cfg["enabled"] = True
dm_cfg["policy"] = "allowlist"
dm_cfg["allowFrom"] = [str(human_id)]
dm_cfg["groupEnabled"] = False
discord["dm"] = dm_cfg
# Remove legacy key if present.
discord.pop("dmPolicy", None)

guilds = discord.get("guilds")
if not isinstance(guilds, dict):
    guilds = {}

guild_cfg = guilds.get(guild_id)
if not isinstance(guild_cfg, dict):
    guild_cfg = {}

guild_cfg["requireMention"] = False
# Human allowlist for non-bot senders in guild context.
guild_cfg["users"] = [str(human_id)]

channels_cfg = guild_cfg.get("channels")
if not isinstance(channels_cfg, dict):
    channels_cfg = {}

channels_cfg[channel_id] = {"allow": True, "requireMention": False}
guild_cfg["channels"] = channels_cfg

guilds[guild_id] = guild_cfg
discord["guilds"] = guilds

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

require_discord_inputs

seed_workspace_context_files() {
  local ws_root="$HOME/.openclaw/workspace"
  mkdir -p "$ws_root/memory"

  cat >"$ws_root/AGENTS.md" <<'EOF'
# AGENTS.md - Your Workspace

The discord server <guild:__DISCORD_GUILD_ID__> is your dedicated environment to interact with your human and fellow agents.

You are one of possibly many Agents working under the direction of your human.

## Environment

- Host type: DigitalOcean Ubuntu droplet
- Workspace root: `~/.openclaw/workspace`
- Shared collaborative workspace root for all agents: `~/.openclaw/workspace/shared`
- Private folder just for you: `~/.openclaw/workspace/<your-username>/`
- Frontend is served via nginx and locked down to the human's IP allowlist
- Communication is via private Discord server. Before responding to a message, ALWAYS inspect the most recent channel messages and apply a soft debounce window of ~5 seconds before replying.
- If the same sender posted multiple consecutive messages within that window, treat them as ONE message chunk and reply at most once after context stabilizes. If the latest activity is just continuation text from the same sender, stay silent.
- Keep normal chat replies short (target <= 400 characters) unless your human explicitly asks for detail.
- If the recent messages seem to be between two other people and not relevant to you, stay silent.
- Only engage with your human (`__DISCORD_HUMAN_ID__`) and fellow agent bots; ignore other human users.
- Never collect or process Discord bot tokens in Discord messages (guild or DM).
- For new-bot provisioning, direct the human to the frontend Admin page at `/admin`.

## DM command contract (owner-only control lane)

In Discord DMs, only the configured human (`__DISCORD_HUMAN_ID__`) can issue privileged commands.

- `/exec <shell command>`
  - Run the command through `/usr/local/bin/kiwi-exec`.
  - Use the `exec` tool with `host=gateway`, `security=full`, and `ask=off` for this command path.
  - Return exit code + truncated stdout/stderr summary.
- Agent management
  - Do not ask for bot tokens in Discord.
  - Tell the human to use the frontend Admin page (`/admin`) to view and create agents.

Rules:
- Never execute shell commands from guild/public messages.
- Never execute shell commands from non-owner DMs.
- For normal non-command DMs, behave as a regular assistant.

## First Run

If `BOOTSTRAP.md` exists, that's your birth certificate. Follow it, figure out who you are, then delete it. You won't need it again.

## Every Session

Before doing anything else:

In your private workspace: 
  1. Read `SOUL.md` — this is who you are
  2. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
  3. **If in MAIN SESSION** (direct chat with your human): Also read `MEMORY.md`

  Don't ask permission. Just do it.

  You wake up fresh each session. These files are your continuity:

  - **Daily notes:** `memory/YYYY-MM-DD.md` (create `memory/` if needed) — raw logs of what happened
  - **Long-term:** `MEMORY.md` — your curated memories, like a human's long-term memory

  Capture what matters. Decisions, context, things to remember. Skip the secrets unless asked to keep them.

In the collaborative workspace:
  1. Read `TEAM.md` - this is your team of fellow agents
  2. Read `USER.md` - this is your human
  3. Read `TOOLS.md` - these are the tools available to you

### 🧠 MEMORY.md - Your Long-Term Memory

- **ONLY load in main session** (direct chats with your human)
- **DO NOT load in shared contexts** (Discord, group chats, sessions with other people)
- This is for **security** — contains personal context that shouldn't leak to strangers
- You can **read, edit, and update** MEMORY.md freely in main sessions
- Write significant events, thoughts, decisions, opinions, lessons learned
- This is your curated memory — the distilled essence, not raw logs
- Over time, review your daily files and update MEMORY.md with what's worth keeping

### 📝 Write It Down - No "Mental Notes"!

- **Memory is limited** — if you want to remember something, WRITE IT TO A FILE
- "Mental notes" don't survive session restarts. Files do.
- When someone says "remember this" → update `memory/YYYY-MM-DD.md` or relevant file
- When you learn a lesson → update AGENTS.md, TOOLS.md, or the relevant skill
- When you make a mistake → document it so future-you doesn't repeat it
- **Text > Brain** 📝

## 💓 Heartbeats - Be Proactive!

When you receive a heartbeat poll (message matches the configured heartbeat prompt), don't just reply `HEARTBEAT_OK` every time. Use heartbeats productively!

Default heartbeat prompt:
`Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.`

You are free to edit `HEARTBEAT.md` with a short checklist or reminders. Keep it small to limit token burn.

### Heartbeat vs Cron: When to Use Each

**Use heartbeat when:**

- Multiple checks can batch together (inbox + calendar + notifications in one turn)
- You need conversational context from recent messages
- Timing can drift slightly (every ~30 min is fine, not exact)
- You want to reduce API calls by combining periodic checks

**Use cron when:**

- Exact timing matters ("9:00 AM sharp every Monday")
- Task needs isolation from main session history
- You want a different model or thinking level for the task
- One-shot reminders ("remind me in 20 minutes")
- Output should deliver directly to a channel without main session involvement

**Tip:** Batch similar periodic checks into `HEARTBEAT.md` instead of creating multiple cron jobs. Use cron for precise schedules and standalone tasks.

## Message Formatting 
- No markdown tables! Use bullet lists instead
- Wrap multiple links in `<>` to suppress embeds: `<https://example.com>`

## Spawning Agents
When a human asks to create a new bot/agent, direct them to the frontend Admin page (`/admin`).
Do not collect Discord bot tokens via Discord messages.

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- `trash` > `rm` (recoverable beats gone forever)
- When in doubt, ask.

## External vs Internal

**Safe to do freely:**

- Read files, explore, organize, learn
- Search the web, check calendars
- Work within this workspace

Periodically (every few days), use a heartbeat to:

1. Read through recent `memory/YYYY-MM-DD.md` files
2. Identify significant events, lessons, or insights worth keeping long-term
3. Update `MEMORY.md` with distilled learnings
4. Remove outdated info from MEMORY.md that's no longer relevant

Think of it like a human reviewing their journal and updating their mental model. Daily files are raw notes; MEMORY.md is curated wisdom.

The goal: Be helpful without being annoying. Check in a few times a day, do useful background work.
This is a starting point. Add your own conventions, style, and rules as you figure out what works.
EOF
  sed -i "s/__DISCORD_GUILD_ID__/$DISCORD_GUILD_ID/g" "$ws_root/AGENTS.md"
  sed -i "s/__DISCORD_HUMAN_ID__/$DISCORD_HUMAN_ID/g" "$ws_root/AGENTS.md"
  # no operator bridge placeholders in AGENTS.md

  cat >"$ws_root/SOUL.md" <<'EOF'
# SOUL.md

Be practical, concise, and execution-focused.
Prefer shipping working changes over long theory.
EOF

  cat >"$ws_root/USER.md" <<'EOF'
# USER.md

- Human: Daniel
- Primary interface: Discord
- Build mode: iterative, practical, minimal friction
EOF

  cat >"$ws_root/ADMIN.md" <<'EOF'
# ADMIN.md

Use the frontend admin page for agent operations:
- Visit `/admin` from the allowed IP address
- View existing dedicated agents
- Add a new agent by providing:
  1) name
  2) role
  3) brief description/personality
  4) Discord bot token

Security rules:
- Never ask users to share bot tokens in Discord messages.
- Redirect token collection to `/admin` only.
EOF

  cat >"$ws_root/MEMORY.md" <<'EOF'
# MEMORY.md

Long-term notes and durable decisions go here.
EOF

  local today yesterday
  today="$(date +%F)"
  yesterday="$(date -d 'yesterday' +%F 2>/dev/null || date -v-1d +%F 2>/dev/null || true)"

  [[ -f "$ws_root/memory/${today}.md" ]] || echo "# ${today}" >"$ws_root/memory/${today}.md"
  if [[ -n "$yesterday" ]]; then
    [[ -f "$ws_root/memory/${yesterday}.md" ]] || echo "# ${yesterday}" >"$ws_root/memory/${yesterday}.md"
  fi
}

say "Writing workspace root context files (overwrite mode)"
seed_workspace_context_files

say "Ensuring OpenClaw gateway baseline config"
oc config set gateway.mode local
oc config set gateway.bind loopback
oc config set gateway.auth.mode token
oc config set gateway.trustedProxies '["127.0.0.1"]'
ensure_gateway_token

setup_openclaw_env_file() {
  local env_dir="/etc/openclaw"
  local env_file="${env_dir}/openclaw.env"

  if ! getent group openclaw >/dev/null 2>&1; then
    sudo groupadd --system openclaw >/dev/null 2>&1 || true
  fi
  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
# Shared OpenClaw runtime environment
# Source this file before starting OpenClaw-related processes.
OPENAI_API_KEY="${OPENAI_API_KEY}"
OPENCLAW_HOME="${HOME}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  local source_line='[[ -f /etc/openclaw/openclaw.env ]] && set -a && source /etc/openclaw/openclaw.env && set +a'
  append_path_if_missing "$HOME/.bashrc" "$source_line"
  append_path_if_missing "$HOME/.profile" "$source_line"
  append_path_if_missing "$HOME/.zshrc" "$source_line"

  # Ensure current shell and any child processes for this bootstrap can read the same env.
  set -a
  # shellcheck disable=SC1091
  source "$env_file"
  set +a
}

setup_openclaw_global_dotenv() {
  local dotenv_file="$HOME/.openclaw/.env"
  mkdir -p "$HOME/.openclaw"
  cat >"$dotenv_file" <<EOF
# OpenClaw daemon-level environment fallback.
# Gateway reads this even when it does not inherit shell env.
OPENAI_API_KEY="${OPENAI_API_KEY}"
EOF
  chmod 600 "$dotenv_file"
}

install_kiwi_exec_wrapper() {
  local wrapper_path="/usr/local/bin/kiwi-exec"
  local log_file="$HOME/.openclaw/logs/kiwi-exec.log"

  sudo install -d -m 755 -o root -g root /usr/local/bin
  mkdir -p "$HOME/.openclaw/logs"

  sudo tee "$wrapper_path" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

TIMEOUT_SECONDS="${KIWI_EXEC_TIMEOUT_SECONDS}"
MAX_OUTPUT_BYTES="${KIWI_EXEC_MAX_OUTPUT_BYTES}"
LOG_FILE="${log_file}"

if [[ "\$#" -lt 1 ]]; then
  echo "usage: kiwi-exec '<command>'" >&2
  exit 2
fi

mkdir -p "\$(dirname "\$LOG_FILE")"
chmod 700 "\$(dirname "\$LOG_FILE")" 2>/dev/null || true

ts="\$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '[%s] cmd=%q\n' "\$ts" "\$*" >> "\$LOG_FILE"

set +e
output="\$(timeout "\$TIMEOUT_SECONDS" bash -lc "\$*" 2>&1)"
status="\$?"
set -e

if [[ "\${#output}" -gt "\$MAX_OUTPUT_BYTES" ]]; then
  output="\${output:0:\$MAX_OUTPUT_BYTES}\n...[truncated to \$MAX_OUTPUT_BYTES bytes]"
fi

printf '%s\n' "\$output"
printf 'exit_code=%s\n' "\$status"
exit "\$status"
EOF

  sudo chmod 755 "$wrapper_path"
}

install_operator_bridge() {
  local bridge_dir="$HOME/.openclaw/operator-bridge"
  local bridge_py="$bridge_dir/server.py"
  local spawn_sh="/usr/local/bin/kiwi-spawn-agent"
  local env_dir="/etc/openclaw"
  local env_file="$env_dir/operator-bridge.env"
  local token

  token="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
)"

  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
OPERATOR_BRIDGE_TOKEN="${token}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  sudo tee "$spawn_sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="${1:-}"
ROLE="${2:-}"
DISCORD_BOT_TOKEN_AGENT="${3:-}"
PORT="${4:-}"

[[ -n "$AGENT_ID" && -n "$ROLE" && -n "$DISCORD_BOT_TOKEN_AGENT" ]] || { echo "usage: kiwi-spawn-agent <agent_id> <role> <discord_token> [port]"; exit 2; }

if [[ -z "$PORT" ]]; then
  PORT="$(python3 - <<'PY'
import json, os
p=os.path.expanduser('~/.openclaw/workspace/agents/registry.json')
base=19002
used=set()
if os.path.exists(p):
  try:
    d=json.load(open(p))
    for v in d.values():
      port=v.get('port')
      if isinstance(port,int): used.add(port)
  except Exception:
    pass
port=base
while port in used:
  port+=1
print(port)
PY
)"
fi

set -a
source /etc/openclaw/openclaw.env
set +a

# Hard isolation: each spawned bot gets its own OpenClaw home/runtime.
CHILD_HOME="$HOME/.openclaw-$AGENT_ID"
CHILD_PROFILE="main"

oc_child() { OPENCLAW_HOME="$CHILD_HOME" openclaw --profile "$CHILD_PROFILE" "$@"; }

main_token_before="$(openclaw config get channels.discord.token 2>/dev/null | tr -d '"[:space:]' || true)"

mkdir -p ~/.openclaw/workspace/"$AGENT_ID"/memory ~/.openclaw/workspace/agents "$CHILD_HOME"
cp ~/.openclaw/workspace/{AGENTS.md,SOUL.md,USER.md,MEMORY.md} ~/.openclaw/workspace/"$AGENT_ID"/ 2>/dev/null || true

echo "# Role: $ROLE" >> ~/.openclaw/workspace/"$AGENT_ID"/SOUL.md

oc_child config set agents.defaults.workspace "~/.openclaw/workspace/$AGENT_ID"
oc_child config set gateway.mode local
oc_child config set gateway.bind loopback
oc_child config set gateway.auth.mode token
oc_child config set channels.discord.enabled true
oc_child config set channels.discord.groupPolicy "allowlist"
oc_child config set channels.discord.allowBots true
oc_child config set channels.discord.token "$DISCORD_BOT_TOKEN_AGENT"
oc_child config set channels.discord.dm.enabled true
oc_child config set channels.discord.dm.policy "allowlist"
oc_child config set channels.discord.dm.allowFrom '["__DISCORD_HUMAN_ID__"]'
oc_child config set channels.discord.dm.groupEnabled false
# Newer OpenClaw schemas may use flattened DM keys; set both forms.
oc_child config set channels.discord.dmPolicy "allowlist"
oc_child config set channels.discord.allowFrom '["__DISCORD_HUMAN_ID__"]'

GUILDS_JSON="$(python3 - <<'PY'
import json
print(json.dumps({
  "__DISCORD_GUILD_ID__": {
    "requireMention": False,
    "users": ["__DISCORD_HUMAN_ID__"],
    "channels": {
      "__DISCORD_CHANNEL_ID__": {"allow": True, "requireMention": False}
    }
  }
}))
PY
)"
oc_child config set channels.discord.guilds "$GUILDS_JSON"
oc_child config set tools.exec.host gateway
oc_child config set tools.exec.security full
oc_child config set tools.exec.ask off

# Normalize schema changes before startup (required on some builds).
OPENCLAW_HOME="$CHILD_HOME" openclaw --profile "$CHILD_PROFILE" doctor --fix >/dev/null 2>&1 || true

child_group_policy="$(OPENCLAW_HOME="$CHILD_HOME" openclaw --profile "$CHILD_PROFILE" config get channels.discord.groupPolicy 2>/dev/null | tr -d '"[:space:]' || true)"
child_guild_allow="$(OPENCLAW_HOME="$CHILD_HOME" openclaw --profile "$CHILD_PROFILE" config get channels.discord.guilds.__DISCORD_GUILD_ID__.channels.__DISCORD_CHANNEL_ID__.allow 2>/dev/null | tr -d '"[:space:]' || true)"
if [[ "$child_group_policy" != "allowlist" || "$child_guild_allow" != "true" ]]; then
  echo "ERROR: child guild allowlist wiring failed (groupPolicy=${child_group_policy:-<unset>}, channelAllow=${child_guild_allow:-<unset>})" >&2
  OPENCLAW_HOME="$CHILD_HOME" openclaw --profile "$CHILD_PROFILE" config get channels.discord.guilds >&2 || true
  exit 1
fi

main_token_after="$(openclaw config get channels.discord.token 2>/dev/null | tr -d '"[:space:]' || true)"
if [[ -n "$main_token_before" && "$main_token_before" != "$main_token_after" ]]; then
  echo "ERROR: main profile discord token changed during child spawn; aborting to protect main bot." >&2
  exit 1
fi

nohup env OPENCLAW_HOME="$CHILD_HOME" OPENCLAW_PROFILE="$CHILD_PROFILE" openclaw --profile "$CHILD_PROFILE" gateway --allow-unconfigured --port "$PORT" > ~/.openclaw/workspace/"$AGENT_ID"/gateway.log 2>&1 &

ready=0
for _ in $(seq 1 25); do
  if grep -q "listening on ws://127.0.0.1:${PORT}" ~/.openclaw/workspace/"$AGENT_ID"/gateway.log 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" != "1" ]]; then
  echo "ERROR: child gateway did not become ready on port $PORT" >&2
  tail -n 80 ~/.openclaw/workspace/"$AGENT_ID"/gateway.log >&2 || true
  exit 1
fi

python3 - <<'PY' "$AGENT_ID" "$PORT" "$ROLE" "$CHILD_HOME"
import json, os, sys
agent,port,role,home=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
p=os.path.expanduser('~/.openclaw/workspace/agents/registry.json')
os.makedirs(os.path.dirname(p), exist_ok=True)
d={}
if os.path.exists(p):
  try:d=json.load(open(p))
  except Exception:d={}
d[agent]={"port":port,"role":role,"home":home,"guild_id":"__DISCORD_GUILD_ID__","channel_id":"__DISCORD_CHANNEL_ID__"}
json.dump(d, open(p,'w'), indent=2)
print(json.dumps({"agent_id":agent,"port":port,"home":home,"guild_id":"__DISCORD_GUILD_ID__","channel_id":"__DISCORD_CHANNEL_ID__","guild_configured":True,"status":"started"}))
PY
EOF
  sudo sed -i "s/__DISCORD_GUILD_ID__/${DISCORD_GUILD_ID}/g" "$spawn_sh"
  sudo sed -i "s/__DISCORD_CHANNEL_ID__/${DISCORD_CHANNEL_ID}/g" "$spawn_sh"
  sudo sed -i "s/__DISCORD_HUMAN_ID__/${DISCORD_HUMAN_ID}/g" "$spawn_sh"
  sudo chmod 755 "$spawn_sh"

  mkdir -p "$bridge_dir"
  cat > "$bridge_py" <<'PY'
#!/usr/bin/env python3
import json, os, re, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from subprocess import run

TOKEN=os.environ.get("OPERATOR_BRIDGE_TOKEN","")
PORT=int(os.environ.get("OPERATOR_BRIDGE_PORT","8787"))
LOG=os.path.expanduser("~/.openclaw/logs/operator-bridge.log")
AGENT_RE=re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")


def log(event, **kw):
  os.makedirs(os.path.dirname(LOG), exist_ok=True)
  rec={"ts":time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),"event":event,**kw}
  with open(LOG,"a",encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")


def normalize_payload(body):
  agent_id = body.get("agent_id") or body.get("agentId") or body.get("name")
  role = body.get("role")
  description = body.get("description") or body.get("personality")
  discord_token = body.get("discord_token") or body.get("discordBotToken") or body.get("discord_bot_token")
  port = body.get("port")

  missing=[]
  if not agent_id: missing.append("agent_id")
  if not role: missing.append("role")
  if not description: missing.append("description")
  if not discord_token: missing.append("discord_token")
  if missing:
    return None, {"error":"bad_request","detail":"missing required fields","missing":missing}

  agent_id=str(agent_id).strip().lower()
  if not AGENT_RE.match(agent_id):
    return None, {"error":"bad_request","detail":"invalid agent_id; use lowercase letters, numbers, hyphen (2-31 chars)"}

  role=str(role).strip()
  description=str(description).strip()
  discord_token=str(discord_token).strip()
  port="" if port is None else str(port).strip()
  if port and not port.isdigit():
    return None, {"error":"bad_request","detail":"port must be numeric when provided"}

  return {"agent_id":agent_id,"role":role,"description":description,"discord_token":discord_token,"port":port}, None


class H(BaseHTTPRequestHandler):
  def log_message(self, fmt, *args):
    return

  def _send(self, code, obj):
    b=json.dumps(obj).encode()
    self.send_response(code)
    self.send_header('Content-Type','application/json')
    self.send_header('Content-Length',str(len(b)))
    self.end_headers(); self.wfile.write(b)

  def do_GET(self):
    if self.path=="/health":
      return self._send(200,{"ok":True})

    if self.path=="/agents":
      reg=os.path.expanduser('~/.openclaw/workspace/agents/registry.json')
      data={}
      if os.path.exists(reg):
        try:
          data=json.load(open(reg, 'r', encoding='utf-8'))
        except Exception:
          data={}
      return self._send(200,{"ok":True,"agents":data})

    self._send(404,{"error":"not_found"})

  def do_POST(self):
    req_id=str(uuid.uuid4())[:8]
    if self.path!="/spawn-agent":
      return self._send(404,{"error":"not_found"})

    try:
      n=int(self.headers.get('Content-Length','0'))
      body=json.loads(self.rfile.read(n) or b"{}")
    except Exception as e:
      return self._send(400,{"error":"bad_request","detail":f"invalid JSON: {e}"})

    payload, err = normalize_payload(body)
    if err:
      log("spawn_rejected", req_id=req_id, error=err)
      return self._send(400, err)

    full_role = f"{payload['role']} — {payload['description']}"
    cmd=["/usr/local/bin/kiwi-spawn-agent", payload["agent_id"], full_role, payload["discord_token"]]
    if payload["port"]:
      cmd.append(payload["port"])

    log("spawn_start", req_id=req_id, agent_id=payload["agent_id"], role=payload["role"], description=payload["description"], port=payload["port"], token="***redacted***")
    t0=time.time()
    r=run(cmd, capture_output=True, text=True)
    dur_ms=int((time.time()-t0)*1000)

    spawn_meta={}
    try:
      spawn_meta=json.loads((r.stdout or '').strip().splitlines()[-1]) if (r.stdout or '').strip() else {}
    except Exception:
      spawn_meta={}

    out={
      "ok": r.returncode==0,
      "exit_code": r.returncode,
      "stdout": r.stdout[-4000:],
      "stderr": r.stderr[-4000:],
      "request_id": req_id,
      "duration_ms": dur_ms,
      "spawn": spawn_meta,
      "guild_configured": bool(spawn_meta.get("guild_configured", False)),
      "guild_id": spawn_meta.get("guild_id"),
      "channel_id": spawn_meta.get("channel_id"),
    }
    log("spawn_done", req_id=req_id, ok=(r.returncode==0), exit_code=r.returncode, duration_ms=dur_ms, guild_configured=out["guild_configured"], stderr_tail=r.stderr[-300:])
    return self._send(200 if r.returncode==0 else 500, out)

if __name__=="__main__":
  HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
  chmod 700 "$bridge_py"

  pkill -f "operator-bridge/server.py" >/dev/null 2>&1 || true
  nohup bash -lc "set -a; source '$env_file'; set +a; exec python3 '$bridge_py'" > "$HOME/.openclaw/logs/operator-bridge.log" 2>&1 &
}

configure_exec_approvals_for_autonomous_spawning() {
  if [[ "$EXEC_APPROVAL_MODE" != "full" ]]; then
    echo "Leaving exec approvals unchanged (EXEC_APPROVAL_MODE=${EXEC_APPROVAL_MODE})."
    return 0
  fi

  local approvals_file="$HOME/.openclaw/exec-approvals.bootstrap.json"
  cat >"$approvals_file" <<'EOF'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full",
    "autoAllowSkills": true
  },
  "agents": {}
}
EOF

  if oc approvals set --gateway --file "$approvals_file" >/dev/null 2>&1 \
    || oc approvals set --file "$approvals_file" >/dev/null 2>&1; then
    echo "Configured exec approvals for autonomous spawning (security=full, ask=off)."
  else
    echo "Warning: failed to set exec approvals automatically; provisioning may still require manual approval."
  fi
}

verify_exec_approvals() {
  if [[ "$EXEC_APPROVAL_MODE" != "full" ]]; then
    return 0
  fi

  local raw ask
  raw="$(oc approvals get --gateway 2>/dev/null || oc approvals get 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    echo "Warning: could not read approvals config for verification."
    return 0
  fi

  ask="$(python3 - <<'PY' "$raw"
import json, sys
try:
  data=json.loads(sys.argv[1])
except Exception:
  print("")
  raise SystemExit(0)
print((data.get("defaults") or {}).get("ask", ""))
PY
)"

  if [[ "$ask" == "off" ]]; then
    echo "Verified exec approvals: defaults.ask=off"
  else
    echo "Warning: approvals defaults.ask is '${ask:-<unset>}' (expected 'off')."
  fi
}

verify_discord_dm_allowlist() {
  local dm_enabled dm_policy dm_human
  dm_enabled="$(oc config get channels.discord.dm.enabled 2>/dev/null | tr -d '"[:space:]' || true)"
  dm_policy="$(oc config get channels.discord.dm.policy 2>/dev/null | tr -d '"[:space:]' || true)"
  dm_human="$(oc config get channels.discord.dm.allowFrom.0 2>/dev/null | tr -d '"[:space:]' || true)"

  [[ "$dm_enabled" == "true" ]] || { echo "Error: channels.discord.dm.enabled is not true"; exit 1; }
  [[ "$dm_policy" == "allowlist" ]] || { echo "Error: channels.discord.dm.policy is not allowlist"; exit 1; }
  [[ "$dm_human" == "$DISCORD_HUMAN_ID" ]] || { echo "Error: channels.discord.dm.allowFrom[0] mismatch"; exit 1; }

  echo "Verified Discord DM allowlist (owner=${DISCORD_HUMAN_ID})."
}

say "Configuring model provider (shared env file + defaults)"
setup_openclaw_env_file
setup_openclaw_global_dotenv
install_kiwi_exec_wrapper
install_operator_bridge
oc config set agents.defaults.model.primary "openai/gpt-5.2"
# Force canonical shared workspace path for the main gateway.
oc config set agents.defaults.workspace "~/.openclaw/workspace"
# Force non-interactive host exec defaults for Kiwi operator workflows.
oc config set tools.exec.host "gateway"
oc config set tools.exec.security "full"
oc config set tools.exec.ask "off"
configure_exec_approvals_for_autonomous_spawning
verify_exec_approvals

say "Configuring Discord channel allowlist"
configure_discord_channel
verify_discord_dm_allowlist

detect_public_ip() {
  # Prefer cloud metadata (most reliable on DigitalOcean).
  curl -fsS --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null \
    || curl -fsS --max-time 3 ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null \
    || true
}

setup_frontend_workspace() {
  if [[ "$FRONTEND_ENABLED" != "1" ]]; then
    return 0
  fi

  say "Setting up workspace frontend project (nginx)"
  sudo apt-get update -y
  sudo apt-get install -y nginx

  local project_dir="$HOME/.openclaw/workspace/project"
  mkdir -p "$project_dir"

  cat >"$project_dir/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>OpenClaw Dashboard</title>
  <link rel="stylesheet" href="./styles.css" />
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>🚀 OpenClaw Dashboard</h1>
      <p class="muted">Workspace: <code>~/.openclaw/workspace/project</code></p>
      <p><a href="/admin">Go to Admin</a> to monitor existing agents and add a new one.</p>
      <pre id="out"></pre>
    </section>
  </main>
  <script src="./app.js"></script>
</body>
</html>
EOF

  cat >"$project_dir/admin.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Admin · OpenClaw</title>
  <link rel="stylesheet" href="./styles.css" />
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>🛠️ Admin</h1>
      <p class="muted">Manage dedicated agents for this droplet.</p>
      <button id="refreshAgents">Refresh agents</button>
      <pre id="agentsOut">Loading...</pre>
    </section>

    <section class="card" style="margin-top:16px;">
      <h2>Add agent</h2>
      <form id="spawnForm">
        <label>Name (slug)<br /><input name="agent_id" required pattern="[a-z0-9][a-z0-9-]{1,30}" /></label><br /><br />
        <label>Role<br /><input name="role" required /></label><br /><br />
        <label>Brief description / personality<br /><textarea name="description" rows="3" required></textarea></label><br /><br />
        <label>Discord bot token<br /><input name="discord_token" required autocomplete="off" /></label><br /><br />
        <button type="submit">Add agent</button>
      </form>
      <pre id="spawnOut"></pre>
    </section>
  </main>
  <script src="./admin.js"></script>
</body>
</html>
EOF

  cat >"$project_dir/styles.css" <<'EOF'
:root { color-scheme: dark; }
body { font-family: Inter, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #0b1020; color: #e7ecff; }
.wrap { max-width: 860px; margin: 6vh auto; padding: 24px; }
.card { background: #121a33; border: 1px solid #2a396e; border-radius: 16px; padding: 24px; }
h1, h2 { margin-top: 0; }
code, pre, input, textarea { background: #1f2a50; color: #e7ecff; border-radius: 6px; border: 1px solid #2a396e; }
input, textarea { width: 100%; box-sizing: border-box; padding: 10px; }
pre { padding: 12px; overflow: auto; }
.muted { color: #9fb0e8; }
button { background: #3f6fff; color: white; border: 0; border-radius: 10px; padding: 10px 14px; cursor: pointer; }
a { color: #8bb2ff; }
EOF

  cat >"$project_dir/app.js" <<'EOF'
const out = document.getElementById('out');
out.textContent = `Frontend loaded at ${new Date().toISOString()}`;
EOF

  cat >"$project_dir/admin.js" <<'EOF'
const agentsOut = document.getElementById('agentsOut');
const spawnOut = document.getElementById('spawnOut');
const refreshBtn = document.getElementById('refreshAgents');
const form = document.getElementById('spawnForm');

async function loadAgents() {
  agentsOut.textContent = 'Loading...';
  try {
    const res = await fetch('/api/agents');
    const data = await res.json();
    agentsOut.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    agentsOut.textContent = `Failed to load agents: ${err}`;
  }
}

refreshBtn?.addEventListener('click', loadAgents);

form?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(form);
  const payload = {
    agent_id: String(fd.get('agent_id') || '').trim(),
    role: String(fd.get('role') || '').trim(),
    description: String(fd.get('description') || '').trim(),
    discord_token: String(fd.get('discord_token') || '').trim(),
  };

  spawnOut.textContent = 'Spawning agent...';
  try {
    const res = await fetch('/api/spawn-agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    spawnOut.textContent = JSON.stringify(data, null, 2);
    if (res.ok) {
      form.reset();
      loadAgents();
    }
  } catch (err) {
    spawnOut.textContent = `Spawn failed: ${err}`;
  }
});

loadAgents();
EOF

  cat >"$project_dir/README.md" <<'EOF'
# Workspace Frontend Project

This folder is served by nginx at the droplet public URL.

- `/` dashboard
- `/admin` admin panel to list and create dedicated agents
- `/api/agents` and `/api/spawn-agent` are proxied to localhost operator bridge

Security:
- Frontend access is IP-allowlisted via `FRONTEND_ALLOWED_IP` in bootstrap.
- Share bot tokens only through `/admin` (never in Discord).
EOF

  # Project-level instruction docs removed intentionally.
  # Startup/system guidance now lives at workspace root: ~/.openclaw/workspace/*.md

  # Nginx (www-data) must be able to traverse parent dirs to read project files.
  chmod 755 "$HOME" "$HOME/.openclaw" "$HOME/.openclaw/workspace" "$project_dir" || true
  chmod 644 "$project_dir"/* || true

  if [[ -z "$FRONTEND_ALLOWED_IP" ]]; then
    echo "FRONTEND_ALLOWED_IP is required when FRONTEND_ENABLED=1 (example: 203.0.113.10 or 203.0.113.0/24)."
    exit 1
  fi

  # Apply nginx config with strict source-IP allowlist and local API proxy.
  sudo tee /etc/nginx/nginx.conf >/dev/null <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;
  access_log /var/log/nginx/access.log;

  server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    allow 127.0.0.1;
    allow ${FRONTEND_ALLOWED_IP};
    deny all;

    root ${project_dir};
    index index.html;

    location = /admin {
      try_files /admin.html =404;
    }

    location /api/ {
      proxy_pass http://127.0.0.1:${OPERATOR_BRIDGE_PORT}/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
      try_files \$uri \$uri/ /index.html;
    }
  }
}
EOF

  sudo chmod 755 "$HOME" "$HOME/.openclaw" "$HOME/.openclaw/workspace" "$project_dir"
  sudo chmod 644 "$project_dir"/*

  sudo nginx -t
  sudo systemctl enable --now nginx >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || sudo service nginx restart >/dev/null 2>&1 || true
  sleep 2

  local public_ip
  public_ip="$(detect_public_ip)"

  # Validation: local loopback checks (public checks are expected to fail for non-allowlisted IPs).
  local marker local_ok api_ok
  marker="oc-bootstrap-marker-$(date +%s)-$RANDOM"
  echo "<!-- ${marker} -->" >> "$project_dir/index.html"

  local_ok=0
  api_ok=0

  if curl -fsS --max-time 3 http://127.0.0.1 2>/dev/null | grep -q "$marker"; then
    local_ok=1
  fi

  if curl -fsS --max-time 3 http://127.0.0.1/api/health >/dev/null 2>&1; then
    api_ok=1
  fi

  if [[ "$local_ok" == "1" && "$api_ok" == "1" && -n "$public_ip" ]]; then
    FRONTEND_URL="http://${public_ip}"
    echo "Frontend validation passed (loopback static + API proxy)."
  else
    FRONTEND_URL=""
    echo "Warning: frontend validation failed (local_ok=${local_ok}, api_ok=${api_ok})."
    echo "Debug commands:"
    echo "  curl -s http://127.0.0.1 | head -n 20"
    echo "  curl -s http://127.0.0.1/api/health"
  fi
}

send_discord_boot_ping() {
  local ts msg host ip
  ts="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  host="$(hostname 2>/dev/null || echo unknown-host)"
  ip="$(detect_public_ip)"

  if [[ -n "$FRONTEND_URL" ]]; then
    msg="✅ OpenClaw bootstrap complete (${ts}) on ${host}${ip:+ (${ip})}. Discord route is live. Frontend: ${FRONTEND_URL} (admin: ${FRONTEND_URL}/admin, allowlist: ${FRONTEND_ALLOWED_IP})"
  else
    msg="⚠️ OpenClaw bootstrap complete (${ts}) on ${host}${ip:+ (${ip})}, Discord route is live, but frontend validation failed. Run: curl -s http://127.0.0.1/ | head -n 20"
  fi

  local attempt
  for attempt in 1 2 3 4 5 6; do
    if oc message send --channel discord --target "channel:${DISCORD_CHANNEL_ID}" --message "$msg" >/dev/null 2>&1; then
      echo "Sent Discord startup ping to channel:${DISCORD_CHANNEL_ID}"
      return 0
    fi
    sleep 2
  done

  echo "Warning: failed to send Discord startup ping after retries."
  echo "Check bot token, guild/channel IDs, and bot permissions."
  return 1
}

is_gateway_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ':18789' && return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi

  # Best-effort active connect test (bash built-in)
  (echo >/dev/tcp/127.0.0.1/18789) >/dev/null 2>&1 && return 0

  pgrep -f "openclaw gateway" >/dev/null 2>&1
}

start_gateway_with_fallback() {
  local log_file="$HOME/.openclaw/logs/gateway.log"
  mkdir -p "$HOME/.openclaw/logs"

  clear_gateway_processes() {
    oc gateway stop >/dev/null 2>&1 || true

    # Kill common gateway process patterns (current + legacy names).
    pkill -f "openclaw gateway" >/dev/null 2>&1 || true
    pkill -f "openclaw.mjs gateway" >/dev/null 2>&1 || true
    pkill -f "openclaw-gateway" >/dev/null 2>&1 || true
    pkill -f "node .*openclaw.*gateway" >/dev/null 2>&1 || true

    sudo pkill -f "openclaw gateway" >/dev/null 2>&1 || true
    sudo pkill -f "openclaw.mjs gateway" >/dev/null 2>&1 || true
    sudo pkill -f "openclaw-gateway" >/dev/null 2>&1 || true
    sudo pkill -f "node .*openclaw.*gateway" >/dev/null 2>&1 || true

    # If logs mention a stuck lock PID, kill it explicitly (with sudo fallback).
    local hinted_pid
    hinted_pid="$(grep -Eo 'pid [0-9]+' "$log_file" 2>/dev/null | tail -n1 | awk '{print $2}' || true)"
    if [[ -n "$hinted_pid" ]] && ps -p "$hinted_pid" >/dev/null 2>&1; then
      kill "$hinted_pid" >/dev/null 2>&1 || sudo kill "$hinted_pid" >/dev/null 2>&1 || true
      sleep 1
      ps -p "$hinted_pid" >/dev/null 2>&1 && (kill -9 "$hinted_pid" >/dev/null 2>&1 || sudo kill -9 "$hinted_pid" >/dev/null 2>&1 || true)
    fi

    # Remove stale gateway lock files (after stopping/killing processes).
    # OpenClaw lock naming pattern: gateway.<hash>.lock
    local lock_root
    for lock_root in "$HOME/.openclaw" "${XDG_RUNTIME_DIR:-}" "/tmp" "/tmp/openclaw-$(id -u)"; do
      [[ -n "$lock_root" && -d "$lock_root" ]] || continue
      find "$lock_root" -type f -name 'gateway.*.lock' -print -delete 2>/dev/null || true
      sudo find "$lock_root" -type f -name 'gateway.*.lock' -print -delete 2>/dev/null || true
    done

    sleep 1
  }

  if is_gateway_listening; then
    echo "Gateway already listening on port 18789."
    return 0
  fi

  if oc gateway restart >/dev/null 2>&1 || oc gateway start >/dev/null 2>&1; then
    if is_gateway_listening; then
      echo "Gateway started via service manager."
      return 0
    fi
  fi

  # Handle stale lock/process state (common on fresh droplets during first bootstrap).
  clear_gateway_processes

  echo "systemd user service unavailable; falling back to foreground gateway via nohup"

  if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
    nohup "$NODE_BIN" "$OPENCLAW_MJS" gateway --port 18789 >"$log_file" 2>&1 &
  else
    nohup bash -lc 'source "$HOME/.bashrc" >/dev/null 2>&1 || true; export PATH="$HOME/.npm-global/bin:$PATH"; exec openclaw gateway --port 18789' >"$log_file" 2>&1 &
  fi

  # Wait up to 25s for gateway to bind (cold starts can be slow on fresh droplets)
  local waited=0
  while (( waited < 25 )); do
    if is_gateway_listening; then
      echo "Gateway started in fallback mode (nohup). Logs: $log_file"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # Final guard against false negatives.
  if is_gateway_listening; then
    echo "Gateway is listening despite startup warnings; continuing."
    return 0
  fi

  echo "No listener detected after nohup; running foreground diagnostic (10s timeout)..."
  if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 10s "$NODE_BIN" "$OPENCLAW_MJS" gateway --port 18789 >>"$log_file" 2>&1 || true
    else
      "$NODE_BIN" "$OPENCLAW_MJS" gateway --port 18789 >>"$log_file" 2>&1 &
      sleep 10
      pkill -f "openclaw gateway" >/dev/null 2>&1 || true
    fi
  else
    if command -v timeout >/dev/null 2>&1; then
      timeout 10s "$OPENCLAW_BIN" gateway --port 18789 >>"$log_file" 2>&1 || true
    else
      "$OPENCLAW_BIN" gateway --port 18789 >>"$log_file" 2>&1 &
      sleep 10
      pkill -f "openclaw gateway" >/dev/null 2>&1 || true
    fi
  fi

  if is_gateway_listening; then
    echo "Gateway came up after diagnostic start; continuing."
    return 0
  fi

  # If lock says "already running (pid X)", clear once more and retry a clean foreground start.
  if grep -q "gateway already running (pid" "$log_file" 2>/dev/null; then
    echo "Detected gateway lock conflict; clearing processes/locks and retrying once..."
    clear_gateway_processes

    if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
      nohup "$NODE_BIN" "$OPENCLAW_MJS" gateway --port 18789 >>"$log_file" 2>&1 &
    else
      nohup "$OPENCLAW_BIN" gateway --port 18789 >>"$log_file" 2>&1 &
    fi

    local retry_waited=0
    while (( retry_waited < 35 )); do
      if is_gateway_listening; then
        echo "Gateway started after lock-conflict retry."
        return 0
      fi
      sleep 1
      retry_waited=$((retry_waited + 1))
    done

    # Final race guard: if a gateway process exists, give it a few seconds to bind.
    if pgrep -f "openclaw-gateway|openclaw gateway|openclaw.mjs gateway" >/dev/null 2>&1; then
      sleep 4
      if is_gateway_listening; then
        echo "Gateway process was already launching; listener detected after grace period."
        return 0
      fi
    fi
  fi

  # Absolute final guard against race conditions before failing.
  if is_gateway_listening; then
    echo "Gateway listener detected at final guard; continuing."
    return 0
  fi

  echo "Failed to start gateway in both service and fallback modes."
  echo "Check logs: $log_file"
  echo "Resolved openclaw binary: $OPENCLAW_BIN"
  echo "Resolved openclaw entrypoint: $OPENCLAW_MJS"
  echo "Resolved node binary: ${NODE_BIN:-<not-found>}"
  ls -l "$OPENCLAW_BIN" || true
  pgrep -af "openclaw gateway" || true
  echo "Last gateway log lines:"
  tail -n 120 "$log_file" || true
  return 1
}

say "Starting/restarting gateway service"
if ! start_gateway_with_fallback; then
  echo "Warning: gateway startup reported failure; continuing with frontend setup + diagnostics."
fi

setup_frontend_workspace

say "Checking gateway health"
if is_gateway_listening; then
  echo "Gateway is listening on port 18789"
  say "Sending Discord startup ping"
  send_discord_boot_ping || true
else
  echo "Gateway not listening on port 18789"
  echo "You can still access/edit frontend while gateway troubleshooting continues."
fi

echo
echo "----------------------------------------"
echo "Bootstrap complete."
echo
echo "Discord mode configured."
echo "- Guild ID:   ${DISCORD_GUILD_ID}"
echo "- Channel ID: ${DISCORD_CHANNEL_ID}"
echo "- DM policy:  allowlist (human only: ${DISCORD_HUMAN_ID})"
echo "- Group mode: allowlist (configured guild/channel; non-bot humans restricted to configured human)"
echo "- Operator bridge API (localhost): http://127.0.0.1:${OPERATOR_BRIDGE_PORT}"
if [[ -n "$FRONTEND_URL" ]]; then
  echo "- Frontend: ${FRONTEND_URL}"
  echo "- Admin page: ${FRONTEND_URL}/admin"
  echo "- Frontend allowlist: ${FRONTEND_ALLOWED_IP}"
fi
echo
echo "Gateway is loopback-only (no public OpenClaw dashboard access configured)."
echo "Use Discord as your primary interface."
echo "----------------------------------------"

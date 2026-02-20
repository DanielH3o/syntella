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
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
DISCORD_GUILD_ID=""
DISCORD_CHANNEL_ID=""
FRONTEND_ENABLED="${FRONTEND_ENABLED:-1}"
FRONTEND_URL=""

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

  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    echo "Missing ANTHROPIC_API_KEY."
    echo "Export ANTHROPIC_API_KEY before running this script."
    exit 1
  fi

  parse_discord_target "$DISCORD_TARGET"
}

configure_discord_channel() {
  local config_file="$HOME/.openclaw/openclaw.json"

  python3 - "$config_file" "$DISCORD_BOT_TOKEN" "$DISCORD_GUILD_ID" "$DISCORD_CHANNEL_ID" <<'PY'
import json
import os
import sys

config_path, token, guild_id, channel_id = sys.argv[1:5]

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

# Current schema uses channels.discord.dmPolicy (doctor migrates old dm.policy).
discord["dmPolicy"] = "disabled"
# Remove legacy nested dm block if present.
if isinstance(discord.get("dm"), dict):
    discord.pop("dm", None)

guilds = discord.get("guilds")
if not isinstance(guilds, dict):
    guilds = {}

guild_cfg = guilds.get(guild_id)
if not isinstance(guild_cfg, dict):
    guild_cfg = {}

guild_cfg["requireMention"] = False

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
- Frontend is served publicly via nginx

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

## Discord Behaviour
- Always inspect the most recent channel messages and apply a soft debounce window of ~5 seconds before replying.
- If the same sender posted multiple consecutive messages, treat them as ONE message chunk and reply at most once after context stabilizes.
- If the latest activity is just continuation text from the same sender, stay silent.
- Keep normal chat replies short (target <= 400 characters) unless your human explicitly asks for detail.
- If the recent messages seem to be between two other people and not relevant to you, stay silent.

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
For instructions on spawning agents, read `AGENT-SPAWN.md`.

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

  cat >"$ws_root/AGENT-SPAWN.md" <<'EOF'
# AGENT-SPAWN.md

Use one shared OpenClaw home and one shared env file for API auth.
Avoid creating extra homes like `~/.openclaw-agent2` unless you explicitly want isolation.

```bash
# 1) Ensure shared env is present
sudo test -f /etc/openclaw/openclaw.env

# 2) Source shared env before any OpenClaw process
set -a
source /etc/openclaw/openclaw.env
set +a

# 3) Create profile workspace inside the canonical home
mkdir -p ~/.openclaw/workspace/<profile>/
cp ~/.openclaw/templates/{AGENTS.md,SOUL.md,USER.md,TOOLS.md,IDENTITY.md,HEARTBEAT.md,MEMORY.md} \
   ~/.openclaw/workspace/<profile>/

# 4) Start an additional gateway/profile (example port 19002)
nohup openclaw --profile <profile> gateway --port 19002 \
  > ~/.openclaw/workspace/<profile>/gateway.log 2>&1 &

# 5) Verify
sleep 8
pgrep -af "openclaw.*gateway.*<profile>"
tail -20 ~/.openclaw/workspace/<profile>/gateway.log
```

### Key Gotchas
- **Auth source of truth:** `/etc/openclaw/openclaw.env`
- **Homes:** Prefer one `OPENCLAW_HOME` (`~/.openclaw`) to avoid auth drift
- **Ports:** Each extra gateway needs a unique port
- **Discord:** Each concurrently-running Discord bot still needs its own bot token

### After Spawn
- Ask the new agent to read BOOTSTRAP.md and self-initialize
- Monitor logs for auth/connection issues
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

  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
# Shared OpenClaw runtime environment
# Source this file before starting OpenClaw-related processes.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
OPENCLAW_HOME="${HOME}/.openclaw"
OPENCLAW_PROFILE="main"
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

say "Configuring model provider (shared env file + default model)"
setup_openclaw_env_file
oc config set agents.defaults.model.primary "anthropic/claude-sonnet-4-5"

say "Configuring Discord channel allowlist"
configure_discord_channel

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

  cat >"$project_dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Your Dashboard</title>
  <link rel="stylesheet" href="./styles.css" />
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>🚀 This is your dashboard</h1>
      <p class="muted">This frontend lives in <code>~/.openclaw/workspace/project</code>.</p>
      <p>Edit files there (or ask your agent to), then refresh this page.</p>
      <button id="btn">Click me</button>
      <pre id="out"></pre>
    </section>
  </main>
  <script src="./app.js"></script>
</body>
</html>
EOF

  cat >"$project_dir/styles.css" <<'EOF'
:root { color-scheme: dark; }
body { font-family: Inter, system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #0b1020; color: #e7ecff; }
.wrap { max-width: 760px; margin: 8vh auto; padding: 24px; }
.card { background: #121a33; border: 1px solid #2a396e; border-radius: 16px; padding: 24px; }
h1 { margin-top: 0; }
code, pre { background: #1f2a50; padding: 2px 6px; border-radius: 6px; }
pre { padding: 12px; }
.muted { color: #9fb0e8; }
button { background: #3f6fff; color: white; border: 0; border-radius: 10px; padding: 10px 14px; cursor: pointer; }
EOF

  cat >"$project_dir/app.js" <<'EOF'
const out = document.getElementById('out');
const btn = document.getElementById('btn');
out.textContent = `Frontend loaded at ${new Date().toISOString()}`;
btn?.addEventListener('click', () => {
  out.textContent = `Button clicked at ${new Date().toISOString()}`;
});
EOF

  cat >"$project_dir/README.md" <<'EOF'
# Workspace Frontend Project

This folder is served by nginx at the droplet public URL.

- Edit `index.html`, `styles.css`, `app.js`
- Refresh browser to see updates
- Ask the OpenClaw agent to edit files in this folder directly
EOF

  # Project-level instruction docs removed intentionally.
  # Startup/system guidance now lives at workspace root: ~/.openclaw/workspace/*.md

  # Nginx (www-data) must be able to traverse parent dirs to read project files.
  chmod 755 "$HOME" "$HOME/.openclaw" "$HOME/.openclaw/workspace" "$project_dir" || true
  chmod 644 "$project_dir"/* || true

  # Apply the exact known-good nginx fix block (validated manually).
  sudo tee /etc/nginx/nginx.conf >/dev/null <<'EOF'
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
    root /home/openclaw/.openclaw/workspace/project;
    index index.html;
    location / {
      try_files $uri $uri/ /index.html;
    }
  }
}
EOF

  sudo chmod 755 /home/openclaw /home/openclaw/.openclaw /home/openclaw/.openclaw/workspace /home/openclaw/.openclaw/workspace/project
  sudo chmod 644 /home/openclaw/.openclaw/workspace/project/*

  sudo nginx -t
  sudo systemctl enable --now nginx >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || sudo service nginx restart >/dev/null 2>&1 || true
  sleep 2

  local public_ip
  public_ip="$(detect_public_ip)"

  # Validation: stamp marker, validate local and public responses.
  local marker local_ok public_ok
  marker="oc-bootstrap-marker-$(date +%s)-$RANDOM"
  echo "<!-- ${marker} -->" >> "$project_dir/index.html"

  local_ok=0
  public_ok=0

  if curl -fsS --max-time 3 http://127.0.0.1 2>/dev/null | grep -q "$marker"; then
    local_ok=1
  fi

  if [[ -n "$public_ip" ]]; then
    if curl -fsS --max-time 5 "http://${public_ip}" 2>/dev/null | grep -q "$marker"; then
      public_ok=1
    fi
  fi

  if [[ "$local_ok" == "1" && "$public_ok" == "1" ]]; then
    FRONTEND_URL="http://${public_ip}"
    echo "Frontend validation passed (local + public)."
  else
    FRONTEND_URL=""
    echo "Warning: frontend validation failed (local_ok=${local_ok}, public_ok=${public_ok})."
    echo "Debug commands:"
    echo "  curl -s http://127.0.0.1 | head -n 20"
    echo "  IP=\$(curl -fsS ifconfig.me); echo \$IP; curl -s http://\$IP | head -n 20"
  fi
}

send_discord_boot_ping() {
  local ts msg host ip
  ts="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  host="$(hostname 2>/dev/null || echo unknown-host)"
  ip="$(detect_public_ip)"

  if [[ -n "$FRONTEND_URL" ]]; then
    msg="✅ OpenClaw bootstrap complete (${ts}) on ${host}${ip:+ (${ip})}. Discord route is live. Frontend: ${FRONTEND_URL}"
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
echo "- DM policy:  disabled"
echo "- Group mode: allowlist (only configured guild/channel)"
if [[ -n "$FRONTEND_URL" ]]; then
  echo "- Placeholder frontend: ${FRONTEND_URL}"
fi
echo
echo "Gateway is loopback-only (no public OpenClaw dashboard access configured)."
echo "Use Discord as your primary interface."
echo "----------------------------------------"

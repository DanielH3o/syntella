#!/usr/bin/env bash
set -euo pipefail

# openclaw-droplet-kit bootstrap
# Target: Ubuntu 22.04/24.04 on DigitalOcean

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run as a normal sudo user (not root)."
  echo "Tip: su - openclaw"
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

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

say "Ensuring OpenClaw gateway baseline config"
oc config set gateway.mode local
oc config set gateway.bind loopback
oc config set gateway.auth.mode token
oc config set gateway.trustedProxies '["127.0.0.1"]'
ensure_gateway_token

persist_anthropic_env() {
  local line="export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\""
  append_path_if_missing "$HOME/.bashrc" "$line"
  append_path_if_missing "$HOME/.profile" "$line"
  append_path_if_missing "$HOME/.zshrc" "$line"
  export ANTHROPIC_API_KEY
}

say "Configuring model provider (Anthropic env + default model)"
persist_anthropic_env
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

setup_placeholder_frontend() {
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

  cat >"$project_dir/AGENTS.md" <<'EOF'
# AGENTS.md - Project Context

You are operating on a **DigitalOcean Ubuntu droplet**.

## Environment

- Host type: remote VPS (DigitalOcean droplet)
- OS: Ubuntu
- OpenClaw workspace root: `~/.openclaw/workspace`
- Frontend project root: `~/.openclaw/workspace/project`

## Frontend Serving

- Public frontend URL: `http://<droplet-ip>`
- Served by: `nginx`
- Nginx root: `~/.openclaw/workspace/project`

## Editing Workflow

1. Make frontend edits in `~/.openclaw/workspace/project`
2. Save files
3. User refreshes browser to see changes

No dashboard-specific changes are needed for this workflow.
EOF

  cat >"$project_dir/PROJECT_CONTEXT.md" <<'EOF'
# PROJECT_CONTEXT.md

This project is intentionally bootstrapped as a minimal editable web app.

## Canonical Paths

- Project directory: `~/.openclaw/workspace/project`
- Main HTML: `~/.openclaw/workspace/project/index.html`
- Styles: `~/.openclaw/workspace/project/styles.css`
- JS: `~/.openclaw/workspace/project/app.js`

## Runtime Assumptions

- Deployment target is this same droplet
- Static assets are served directly by nginx
- Browser refresh is the deployment/update mechanism during early development

## Priority

When asked to work on the frontend, operate directly in this project directory first.
EOF

  cat >"$project_dir/TASK.md" <<'EOF'
# TASK.md - Working Brief

## Current Goal

Describe what you are trying to build right now.

## Success Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Constraints

- Keep edits inside `~/.openclaw/workspace/project`
- Frontend is static and served by nginx
- User validates by refreshing browser

## Current State

What is already implemented?

## Next Actions

1. First concrete step
2. Second concrete step
3. Third concrete step

## Notes for Next Agent Session

Any useful handoff notes, decisions, or caveats.
EOF

  # Nginx (www-data) must be able to traverse parent dirs to read project files.
  chmod 755 "$HOME" "$HOME/.openclaw" "$HOME/.openclaw/workspace" "$project_dir" || true
  chmod 644 "$project_dir"/* || true

  # Deterministic nginx config: avoid distro default-site precedence issues.
  sudo tee /etc/nginx/nginx.conf >/dev/null <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
  worker_connections 768;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  sendfile on;
  access_log /var/log/nginx/access.log;

  server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root $project_dir;
    index index.html;

    location / {
      try_files \$uri \$uri/ /index.html;
    }
  }
}
EOF

  sudo nginx -t
  sudo systemctl enable --now nginx >/dev/null 2>&1 || sudo service nginx restart >/dev/null 2>&1 || true

  local public_ip
  public_ip="$(detect_public_ip)"

  # Deterministic validation: stamp marker, validate local and public responses.
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
    echo "Warning: frontend validation failed (local_ok=${local_ok}, public_ok=${public_ok})."
    echo "Applying compatibility fallback: serve project from /var/www/html."

    sudo rm -rf /var/www/html
    sudo ln -s "$project_dir" /var/www/html
    sudo nginx -t
    sudo systemctl restart nginx >/dev/null 2>&1 || sudo service nginx restart >/dev/null 2>&1 || true

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
      echo "Frontend validation passed after /var/www/html fallback."
    else
      FRONTEND_URL=""
      echo "Warning: frontend validation still failed after fallback (local_ok=${local_ok}, public_ok=${public_ok})."
      echo "Debug commands:"
      echo "  curl -s http://127.0.0.1 | head -n 20"
      echo "  IP=\$(curl -fsS ifconfig.me); echo \$IP; curl -s http://\$IP | head -n 20"
    fi
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

setup_placeholder_frontend

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

#!/usr/bin/env bash
set -euo pipefail

# syntella bootstrap
# Target: Ubuntu 22.04/24.04 on DigitalOcean

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run as a normal sudo user (not root)."
  echo "Tip: su - openclaw"
  exit 1
fi

say() { echo -e "\n==> $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Auto-source local .env file if present (for curl|bash runs where exports don't carry over)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
DISCORD_TARGET="${DISCORD_TARGET:-}"
# Accept common aliases to reduce bootstrap env mistakes.
DISCORD_HUMAN_ID="${DISCORD_HUMAN_ID:-${DISCORD_USER_ID:-${DISCORD_HUMAN:-}}}"
MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-}"
DISCORD_GUILD_ID=""
DISCORD_CHANNEL_ID=""
FRONTEND_ENABLED="${FRONTEND_ENABLED:-1}"
FRONTEND_URL=""
# Lock frontend to this source IP/CIDR (required when FRONTEND_ENABLED=1), e.g. "203.0.113.10" or "203.0.113.0/24".
FRONTEND_ALLOWED_IP="${FRONTEND_ALLOWED_IP:-}"
# Exec approval posture for runtime command execution:
# - full: no interactive exec approvals (default for this droplet kit)
# - strict: leave host approval posture unchanged
EXEC_APPROVAL_MODE="${EXEC_APPROVAL_MODE:-full}"
SYNTELLA_EXEC_TIMEOUT_SECONDS="${SYNTELLA_EXEC_TIMEOUT_SECONDS:-60}"
SYNTELLA_EXEC_MAX_OUTPUT_BYTES="${SYNTELLA_EXEC_MAX_OUTPUT_BYTES:-16384}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT:-8787}"
OPERATOR_BRIDGE_TOKEN=""

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

resolve_openclaw_bin() {
  local candidate=""

  candidate="$(command -v openclaw 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in "$HOME/.npm-global/bin/openclaw" "$HOME/.local/bin/openclaw" "/usr/local/bin/openclaw"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v npm >/dev/null 2>&1; then
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    candidate="${npm_prefix%/}/bin/openclaw"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

render_template() {
  local src="$1"
  local dst="$2"
  sed \
    -e "s|__DISCORD_GUILD_ID__|${DISCORD_GUILD_ID}|g" \
    -e "s|__DISCORD_CHANNEL_ID__|${DISCORD_CHANNEL_ID}|g" \
    -e "s|__DISCORD_HUMAN_ID__|${DISCORD_HUMAN_ID}|g" \
    -e "s|__OPERATOR_BRIDGE_PORT__|${OPERATOR_BRIDGE_PORT}|g" \
    -e "s|__OPERATOR_BRIDGE_TOKEN__|${OPERATOR_BRIDGE_TOKEN}|g" \
    "$src" > "$dst"
}

assert_templates_exist() {
  local required=(  
    "$TEMPLATE_DIR/workspace/AGENTS.SYNTELLA.md.tmpl"
    "$TEMPLATE_DIR/workspace/AGENTS.SPAWNED.md.tmpl"
    "$TEMPLATE_DIR/workspace/SOUL.md"
    "$TEMPLATE_DIR/workspace/USER.md"
    "$TEMPLATE_DIR/workspace/MEMORY.md"
    "$TEMPLATE_DIR/workspace/TEAM.md"
    "$TEMPLATE_DIR/frontend/index.html"
    "$TEMPLATE_DIR/frontend/admin.html"
    "$TEMPLATE_DIR/frontend/styles.css"
    "$TEMPLATE_DIR/frontend/app.js"
    "$TEMPLATE_DIR/frontend/admin.js"
    "$TEMPLATE_DIR/frontend/README.md"
    "$TEMPLATE_DIR/operator-bridge/syntella-spawn-agent.sh.tmpl"
    "$TEMPLATE_DIR/operator-bridge/server.py"
  )
  local f
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || { echo "Missing template file: $f"; exit 1; }
  done
}

ensure_node_and_npm() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi

  say "Installing Node.js 22 + npm"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y nodejs
}

install_openclaw_cli() {
  if command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  say "Installing OpenClaw CLI via npm (without optional native deps)"
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global"

  # Skip optional deps (e.g. @discordjs/opus) to avoid native build failures on fresh droplets.
  npm install -g --omit=optional openclaw@latest

  ensure_openclaw_on_path || true
}

say "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates gnupg lsb-release iproute2 procps lsof python3 make g++ build-essential pkg-config
ensure_node_and_npm
install_openclaw_cli

if ! ensure_openclaw_on_path; then
  echo "OpenClaw appears installed but is not on PATH; attempting direct binary resolution..."
fi

OPENCLAW_BIN="$(resolve_openclaw_bin || true)"
if [[ -z "$OPENCLAW_BIN" ]]; then
  echo "OpenClaw installed but executable could not be resolved."
  echo "Checked: command -v openclaw, ~/.npm-global/bin/openclaw, ~/.local/bin/openclaw, /usr/local/bin/openclaw"
  echo "Try: export PATH=\"$HOME/.npm-global/bin:$PATH\""
  echo "Then re-run this script."
  exit 1
fi
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

  if [[ -z "$MOONSHOT_API_KEY" ]]; then
    echo "Missing MOONSHOT_API_KEY."
    echo "Export MOONSHOT_API_KEY before running this script."
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

seed_workspace_context_files() {
  local ws_root="$HOME/.openclaw/workspace"
  local ws_tmpl="$TEMPLATE_DIR/workspace"
  local syntella_ws="$ws_root/syntella"
  local shared_ws="$ws_root/shared"
  mkdir -p "$syntella_ws" "$syntella_ws/memory" "$shared_ws"

  render_template "$ws_tmpl/AGENTS.SYNTELLA.md.tmpl" "$syntella_ws/AGENTS.md"
  render_template "$ws_tmpl/AGENTS.SPAWNED.md.tmpl" "$ws_root/AGENTS.SPAWNED.md"
  render_template "$ws_tmpl/HEARTBEAT.MAIN.md.tmpl" "$syntella_ws/HEARTBEAT.md"
  cp "$ws_tmpl/SOUL.md" "$syntella_ws/SOUL.md"
  cp "$ws_tmpl/USER.md" "$shared_ws/USER.md"                                                 
  cp "$ws_tmpl/MEMORY.md" "$syntella_ws/MEMORY.md"
  cp "$ws_tmpl/TEAM.md" "$shared_ws/TEAM.md"
  cp "$ws_tmpl/TASKS.md" "$shared_ws/TASKS.md"

  local today yesterday
  today="$(date +%F)"
  yesterday="$(date -d 'yesterday' +%F 2>/dev/null || date -v-1d +%F 2>/dev/null || true)"

  [[ -f "$syntella_ws/memory/${today}.md" ]] || echo "# ${today}" >"$syntella_ws/memory/${today}.md"
  if [[ -n "$yesterday" ]]; then
    [[ -f "$syntella_ws/memory/${yesterday}.md" ]] || echo "# ${yesterday}" >"$syntella_ws/memory/${yesterday}.md"
  fi
}
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
MOONSHOT_API_KEY="${MOONSHOT_API_KEY}"
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
MOONSHOT_API_KEY="${MOONSHOT_API_KEY}"
EOF
  chmod 600 "$dotenv_file"
}

install_syntella_exec_wrapper() {
  local wrapper_path="/usr/local/bin/syntella-exec"
  local log_file="$HOME/.openclaw/logs/syntella-exec.log"

  sudo install -d -m 755 -o root -g root /usr/local/bin
  mkdir -p "$HOME/.openclaw/logs"

  sudo tee "$wrapper_path" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

TIMEOUT_SECONDS="${SYNTELLA_EXEC_TIMEOUT_SECONDS}"
MAX_OUTPUT_BYTES="${SYNTELLA_EXEC_MAX_OUTPUT_BYTES}"
LOG_FILE="${log_file}"

if [[ "\$#" -lt 1 ]]; then
  echo "usage: syntella-exec '<command>'" >&2
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
  local spawn_sh="/usr/local/bin/syntella-spawn-agent"
  local env_dir="/etc/openclaw"
  local env_file="$env_dir/operator-bridge.env"

  OPERATOR_BRIDGE_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
)"

  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
OPERATOR_BRIDGE_TOKEN="${OPERATOR_BRIDGE_TOKEN}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  render_template "$TEMPLATE_DIR/operator-bridge/syntella-spawn-agent.sh.tmpl" "$HOME/.openclaw/syntella-spawn-agent.sh"
  sudo install -m 755 "$HOME/.openclaw/syntella-spawn-agent.sh" "$spawn_sh"

  mkdir -p "$bridge_dir"
  mkdir -p "$bridge_dir"
  render_template "$TEMPLATE_DIR/operator-bridge/server.py" "$bridge_py"
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

configure_openclaw_runtime() {
  say "Writing workspace root context files (overwrite mode)"
  seed_workspace_context_files

  say "Ensuring OpenClaw gateway baseline config"
  oc config set gateway.mode local
  oc config set gateway.bind loopback
  oc config set gateway.auth.mode token
  oc config set gateway.trustedProxies '["127.0.0.1"]'
  ensure_gateway_token

  say "Configuring model provider (shared env file + defaults)"
  setup_openclaw_env_file
  setup_openclaw_global_dotenv
  install_syntella_exec_wrapper
  install_operator_bridge

  oc config set agents.defaults.model.primary "moonshot/kimi-k2.5"
  oc config set agents.defaults.workspace "~/.openclaw/workspace/syntella"
  oc config set agents.defaults.heartbeat.every "15m"
  oc config set agents.defaults.heartbeat.target "discord"
  # Ensure channel ID is stored as string (not number) in JSON
  python3 - "$HOME/.openclaw/openclaw.json" "$DISCORD_CHANNEL_ID" <<'PY'
import json, os, sys
config_path, channel_id = sys.argv[1:3]
cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, 'r') as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
agents = cfg.setdefault('agents', {})
defs = agents.setdefault('defaults', {})
hb = defs.setdefault('heartbeat', {})
hb['to'] = channel_id  # Explicitly set as string
with open(config_path, 'w') as f:
    json.dump(cfg, f, indent=2)
PY
  oc config set tools.exec.host "gateway"
  oc config set tools.exec.security "full"
  oc config set tools.exec.ask "off"

  configure_exec_approvals_for_autonomous_spawning
  verify_exec_approvals

  say "Configuring Discord channel allowlist"
  configure_discord_channel
  verify_discord_dm_allowlist
}

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

  cp "$TEMPLATE_DIR/frontend/index.html" "$project_dir/index.html"
  cp "$TEMPLATE_DIR/frontend/admin.html" "$project_dir/admin.html"
  cp "$TEMPLATE_DIR/frontend/styles.css" "$project_dir/styles.css"
  cp "$TEMPLATE_DIR/frontend/app.js" "$project_dir/app.js"
  cp "$TEMPLATE_DIR/frontend/admin.js" "$project_dir/admin.js"
  cp "$TEMPLATE_DIR/frontend/README.md" "$project_dir/README.md"

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
      proxy_set_header Authorization "Bearer ${OPERATOR_BRIDGE_TOKEN}";
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_connect_timeout 10s;
      proxy_send_timeout 300s;
      proxy_read_timeout 300s;
      send_timeout 300s;
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

print_summary() {
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
}

main() {
  assert_templates_exist
  require_discord_inputs
  configure_openclaw_runtime

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

  print_summary
}

main "$@"

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
DISCORD_GUILD_ID=""
DISCORD_CHANNEL_ID=""

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

dm = discord.get("dm")
if not isinstance(dm, dict):
    dm = {}
dm["policy"] = "disabled"
discord["dm"] = dm

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

say "Configuring Discord channel allowlist"
configure_discord_channel

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
    pkill -f "openclaw gateway" >/dev/null 2>&1 || true
    pkill -f "openclaw.mjs gateway" >/dev/null 2>&1 || true

    # If logs mention a stuck lock PID, kill it explicitly.
    local hinted_pid
    hinted_pid="$(grep -Eo 'pid [0-9]+' "$log_file" 2>/dev/null | tail -n1 | awk '{print $2}' || true)"
    if [[ -n "$hinted_pid" ]] && ps -p "$hinted_pid" >/dev/null 2>&1; then
      kill "$hinted_pid" >/dev/null 2>&1 || true
      sleep 1
      ps -p "$hinted_pid" >/dev/null 2>&1 && kill -9 "$hinted_pid" >/dev/null 2>&1 || true
    fi

    # Remove stale gateway lock files (after stopping/killing processes).
    # OpenClaw lock naming pattern: gateway.<hash>.lock
    local lock_root
    for lock_root in "$HOME/.openclaw" "${XDG_RUNTIME_DIR:-}" "/tmp"; do
      [[ -n "$lock_root" && -d "$lock_root" ]] || continue
      find "$lock_root" -type f -name 'gateway.*.lock' -print -delete 2>/dev/null || true
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
start_gateway_with_fallback

say "Checking gateway health"
if is_gateway_listening; then
  echo "Gateway is listening on port 18789"
else
  echo "Gateway not listening on port 18789"
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
echo
echo "Gateway is loopback-only (no public dashboard access configured)."
echo "Use Discord as your primary interface."
echo "----------------------------------------"

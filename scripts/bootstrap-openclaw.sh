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

append_path_if_missing() {
  local rc_file="$1"
  local path_line="$2"
  [[ -f "$rc_file" ]] || touch "$rc_file"
  grep -Fq "$path_line" "$rc_file" || echo "$path_line" >> "$rc_file"
}

ensure_openclaw_on_path() {
  if command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  local npm_global_bin="$HOME/.npm-global/bin"
  local path_line='export PATH="$HOME/.npm-global/bin:$PATH"'

  if [[ -x "$npm_global_bin/openclaw" ]]; then
    export PATH="$npm_global_bin:$PATH"
    append_path_if_missing "$HOME/.bashrc" "$path_line"
    append_path_if_missing "$HOME/.profile" "$path_line"
    append_path_if_missing "$HOME/.zshrc" "$path_line"
  fi

  command -v openclaw >/dev/null 2>&1
}

say "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates gnupg lsb-release

if ! command -v tailscale >/dev/null 2>&1; then
  say "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

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

say "Pre-creating OpenClaw state dirs to avoid first-run prompts"
mkdir -p "$HOME/.openclaw"
chmod 700 "$HOME/.openclaw" || true
mkdir -p "$HOME/.openclaw/agents/main/sessions"
mkdir -p "$HOME/.openclaw/credentials"
mkdir -p "$HOME/.openclaw/workspace"

require_cmd tailscale

say "Ensuring OpenClaw gateway baseline config"
openclaw config set gateway.mode local
openclaw config set gateway.bind loopback
openclaw config set gateway.auth.mode token
openclaw config set gateway.tailscale.mode serve
openclaw config set gateway.trustedProxies '["127.0.0.1"]'

say "Generating gateway token (if needed)"
openclaw doctor --generate-gateway-token || true

is_gateway_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE '127\.0\.0\.1:18789|\[::1\]:18789|:18789'
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  pgrep -f "openclaw gateway" >/dev/null 2>&1
}

start_gateway_with_fallback() {
  local log_file="$HOME/.openclaw/logs/gateway.log"
  mkdir -p "$HOME/.openclaw/logs"

  if openclaw gateway restart >/dev/null 2>&1 || openclaw gateway start >/dev/null 2>&1; then
    echo "Gateway started via service manager."
    return 0
  fi

  echo "systemd user service unavailable; falling back to foreground gateway via nohup"
  pkill -f "openclaw gateway" >/dev/null 2>&1 || true
  nohup openclaw gateway --port 18789 >"$log_file" 2>&1 &
  sleep 3

  if is_gateway_listening; then
    echo "Gateway started in fallback mode (nohup). Logs: $log_file"
    return 0
  fi

  echo "Failed to start gateway in both service and fallback modes."
  echo "Check logs: $log_file"
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

say "Tailscale setup"
if tailscale status >/dev/null 2>&1; then
  echo "Tailscale already authenticated."
else
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "Using provided TAILSCALE_AUTHKEY for non-interactive login..."
    sudo tailscale up --ssh --hostname=openclaw --authkey "$TAILSCALE_AUTHKEY" || true
  fi

  if tailscale status >/dev/null 2>&1; then
    echo "Tailscale authenticated."
  else
    echo "Tailscale not authenticated yet."
    echo "Optional one-time command to enable private HTTPS UI:"
    echo "  sudo tailscale up --ssh --hostname=openclaw"
  fi
fi

echo
echo "----------------------------------------"
echo "Bootstrap complete."
echo
echo "If Tailscale Serve is active, dashboard/chat is at:"
echo "  https://<your-tailnet-host>.ts.net/"
echo
echo "Fallback local access over SSH tunnel:"
echo "  ssh -L 18789:127.0.0.1:18789 <user>@<droplet>"
echo "  then open http://localhost:18789"
echo
echo "Gateway token is stored under ~/.openclaw (mode token)."
echo "----------------------------------------"

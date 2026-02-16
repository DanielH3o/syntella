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
mkdir -p "$HOME/.openclaw/agents/main/sessions"
mkdir -p "$HOME/.openclaw/credentials"

require_cmd tailscale

say "Initializing OpenClaw config non-interactively"
openclaw setup --non-interactive --workspace "$HOME/.openclaw/workspace" || true

say "Ensuring OpenClaw gateway baseline config"
openclaw config set gateway.bind loopback
openclaw config set gateway.auth.mode token
openclaw config set gateway.tailscale.mode serve
openclaw config set gateway.trustedProxies '["127.0.0.1"]'

say "Generating gateway token (if needed)"
openclaw doctor --generate-gateway-token || true

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
  sleep 2

  if curl -fsS http://127.0.0.1:18789 >/dev/null 2>&1; then
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
curl -fsS http://127.0.0.1:18789 >/dev/null && echo "Gateway is responding on 127.0.0.1:18789"

say "Tailscale setup"
if ! tailscale status >/dev/null 2>&1; then
  echo "Run this to complete Tailscale auth:"
  echo "  sudo tailscale up --ssh --hostname=openclaw"
else
  echo "Tailscale already authenticated."
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

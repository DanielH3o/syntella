#!/usr/bin/env bash
set -euo pipefail

# Smoke test for openclaw-droplet bootstrap output.
# Run as openclaw user on the droplet after bootstrap.

say() { echo -e "\n==> $*"; }
pass() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
  warn "Running as root. Prefer: sudo -u openclaw -H bash scripts/smoke-test.sh"
fi

say "Checking openclaw binary"
command -v openclaw >/dev/null 2>&1 || fail "openclaw not found on PATH"
pass "openclaw is on PATH: $(command -v openclaw)"

say "Checking gateway listener"
if ss -ltn 2>/dev/null | grep -q ':18789'; then
  pass "Gateway port 18789 is listening"
else
  warn "Port 18789 not listening yet"
fi

say "Checking discord configuration"
TOKEN="$(openclaw config get channels.discord.token 2>/dev/null | tr -d '"[:space:]' || true)"
TARGET_GUILDS="$(openclaw config get channels.discord.guilds 2>/dev/null || true)"
if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
  pass "Discord token configured"
else
  fail "Discord token missing"
fi
if [[ -n "$TARGET_GUILDS" && "$TARGET_GUILDS" != "null" ]]; then
  pass "Discord guild allowlist configured"
else
  warn "Discord guild allowlist not detected"
fi

say "Checking frontend files"
PROJECT_DIR="$HOME/.openclaw/workspace/project"
[[ -f "$PROJECT_DIR/index.html" ]] || fail "Missing $PROJECT_DIR/index.html"
[[ -f "$PROJECT_DIR/styles.css" ]] || fail "Missing $PROJECT_DIR/styles.css"
[[ -f "$PROJECT_DIR/app.js" ]] || fail "Missing $PROJECT_DIR/app.js"
pass "Project files exist"

say "Checking nginx content locally"
LOCAL_HTML="$(curl -fsS --max-time 5 http://127.0.0.1 2>/dev/null || true)"
if echo "$LOCAL_HTML" | grep -q "This is your dashboard"; then
  pass "Nginx serves project dashboard locally"
else
  warn "Nginx local response does not match dashboard marker"
fi

say "Checking public IP and frontend URL"
PUBLIC_IP="$(curl -fsS --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || curl -fsS --max-time 3 ifconfig.me 2>/dev/null || true)"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "Public IP: $PUBLIC_IP"
  PUBLIC_HTML="$(curl -fsS --max-time 8 "http://${PUBLIC_IP}" 2>/dev/null || true)"
  if echo "$PUBLIC_HTML" | grep -q "This is your dashboard"; then
    pass "Public frontend returns dashboard"
  else
    warn "Public frontend did not return dashboard (could be firewall/proxy/cache)"
  fi
else
  warn "Could not detect public IP"
fi

say "Done"
echo "If Discord is online and frontend loads, smoke test is good."

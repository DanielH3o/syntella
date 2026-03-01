#!/usr/bin/env bash
set -euo pipefail

# Smoke test for syntella bootstrap output.
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

say "Checking shared runtime env"
if [[ -f /etc/openclaw/openclaw.env ]]; then
  pass "Found /etc/openclaw/openclaw.env"
else
  warn "Missing /etc/openclaw/openclaw.env (spawned agents may not inherit API auth)"
fi

say "Checking gateway listener"
if ss -ltn 2>/dev/null | grep -q ':18789'; then
  pass "Gateway port 18789 is listening"
else
  warn "Port 18789 not listening yet"
fi

say "Checking discord configuration"
TOKEN="$(openclaw config get channels.discord.token 2>/dev/null | tr -d '"[:space:]' || true)"
TARGET_GUILDS="$(openclaw config get channels.discord.guilds 2>/dev/null || true)"
DM_ENABLED="$(openclaw config get channels.discord.dm.enabled 2>/dev/null | tr -d '"[:space:]' || true)"
DM_POLICY="$(openclaw config get channels.discord.dm.policy 2>/dev/null | tr -d '"[:space:]' || true)"
DM_OWNER="$(openclaw config get channels.discord.dm.allowFrom.0 2>/dev/null | tr -d '"[:space:]' || true)"
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
if [[ "$DM_ENABLED" == "true" && "$DM_POLICY" == "allowlist" && -n "$DM_OWNER" && "$DM_OWNER" != "null" ]]; then
  pass "Discord DM owner allowlist configured (${DM_OWNER})"
else
  fail "Discord DM allowlist misconfigured (enabled=${DM_ENABLED}, policy=${DM_POLICY}, owner=${DM_OWNER})"
fi

say "Checking Syntella exec wrapper"
if [[ -x "/usr/local/bin/syntella-exec" ]]; then
  pass "syntella-exec installed"
else
  fail "Missing /usr/local/bin/syntella-exec"
fi

if /usr/local/bin/syntella-exec "echo syntella-smoke" | grep -q "syntella-smoke"; then
  pass "syntella-exec runs commands"
else
  fail "syntella-exec command execution check failed"
fi

say "Checking exec runtime defaults"
EXEC_HOST="$(openclaw config get tools.exec.host 2>/dev/null | tr -d '"[:space:]' || true)"
EXEC_SECURITY="$(openclaw config get tools.exec.security 2>/dev/null | tr -d '"[:space:]' || true)"
EXEC_ASK="$(openclaw config get tools.exec.ask 2>/dev/null | tr -d '"[:space:]' || true)"
[[ "$EXEC_HOST" == "gateway" ]] && pass "tools.exec.host=gateway" || warn "tools.exec.host=${EXEC_HOST:-<unset>}"
[[ "$EXEC_SECURITY" == "full" ]] && pass "tools.exec.security=full" || warn "tools.exec.security=${EXEC_SECURITY:-<unset>}"
[[ "$EXEC_ASK" == "off" ]] && pass "tools.exec.ask=off" || warn "tools.exec.ask=${EXEC_ASK:-<unset>}"

APPROVALS_RAW="$(openclaw approvals get --gateway 2>/dev/null || openclaw approvals get 2>/dev/null || true)"
APPROVALS_ASK="$(python3 - <<'PY' "$APPROVALS_RAW"
import json, sys
raw=sys.argv[1]
try:
  data=json.loads(raw)
  print((data.get('defaults') or {}).get('ask',''))
except Exception:
  print('')
PY
)"
if [[ "$APPROVALS_ASK" == "off" ]]; then
  pass "Exec approvals are non-interactive (defaults.ask=off)"
else
  warn "Exec approvals may be interactive (defaults.ask=${APPROVALS_ASK:-<unset>})"
fi

say "Checking operator bridge"
if [[ -f /etc/openclaw/operator-bridge.env ]]; then
  # shellcheck disable=SC1091
  source /etc/openclaw/operator-bridge.env
  BRIDGE_HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${OPERATOR_BRIDGE_PORT:-8787}/health 2>/dev/null || true)"
  if echo "$BRIDGE_HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok')==True" 2>/dev/null; then
    BRIDGE_UPTIME="$(echo "$BRIDGE_HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uptime_seconds','?'))" 2>/dev/null || echo '?')"
    pass "Operator bridge healthy on 127.0.0.1:${OPERATOR_BRIDGE_PORT:-8787} (uptime: ${BRIDGE_UPTIME}s)"
  else
    warn "Operator bridge health check failed"
  fi
else
  warn "Missing /etc/openclaw/operator-bridge.env"
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

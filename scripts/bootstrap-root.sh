#!/usr/bin/env bash
set -euo pipefail

# Root-level non-interactive bootstrap for fresh Ubuntu droplets.
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
# Required env vars:
#   export DISCORD_BOT_TOKEN="..."
#   export DISCORD_TARGET="<guildId>/<channelId>"
#   export DISCORD_HUMAN_ID="<your-discord-user-id>"   # also accepts DISCORD_USER_ID or DISCORD_HUMAN
#   export OPENAI_API_KEY="..."
# Optional:
#   export FRONTEND_ENABLED=0   # skip nginx placeholder frontend
#   export EXEC_APPROVAL_MODE=strict   # keep interactive exec approvals (default is full)
# Optional explicit key injection:
#   OPENCLAW_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
#   curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
REPO_URL="${REPO_URL:-https://github.com/DanielH3o/openclaw-droplet.git}"
REPO_DIR="${REPO_DIR:-/home/${OPENCLAW_USER}/openclaw-droplet}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

say() { echo -e "\n==> $*"; }

collect_authorized_keys() {
  # Priority 1: explicit env var(s) (recommended for deterministic provisioning)
  # - OPENCLAW_AUTHORIZED_KEY  : single key
  # - OPENCLAW_AUTHORIZED_KEYS : one or many keys separated by newlines
  if [[ -n "${OPENCLAW_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$OPENCLAW_AUTHORIZED_KEYS"
  fi

  if [[ -n "${OPENCLAW_AUTHORIZED_KEY:-}" ]]; then
    printf '%s\n' "$OPENCLAW_AUTHORIZED_KEY"
  fi

  # Priority 2: existing local users' authorized_keys
  local key_file
  for key_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "$key_file" ]] || continue
    cat "$key_file"
    printf '\n'
  done

  # Priority 3 (DigitalOcean): metadata service public keys
  if command -v curl >/dev/null 2>&1; then
    local md_url="http://169.254.169.254/metadata/v1/public-keys/"
    local key_ids
    key_ids="$(curl -fsS --max-time 2 "$md_url" 2>/dev/null || true)"
    if [[ -n "$key_ids" ]]; then
      local id
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        curl -fsS --max-time 2 "${md_url}${id}" 2>/dev/null || true
        printf '\n'
      done <<< "$key_ids"
    fi
  fi
}

install_authorized_keys_for_user() {
  local user="$1"
  local home_dir="/home/${user}"
  local ssh_dir="${home_dir}/.ssh"
  local auth_file="${ssh_dir}/authorized_keys"

  install -d -m 700 -o "$user" -g "$user" "$ssh_dir"

  local tmp_keys
  tmp_keys="$(mktemp)"
  collect_authorized_keys \
    | sed 's/\r$//' \
    | awk 'NF {print}' \
    | sort -u > "$tmp_keys"

  if [[ -s "$tmp_keys" ]]; then
    install -m 600 -o "$user" -g "$user" "$tmp_keys" "$auth_file"
    say "Installed $(wc -l < "$tmp_keys" | tr -d '[:space:]') SSH key(s) for $user"
  else
    say "No SSH public keys found automatically"
    echo "Set OPENCLAW_AUTHORIZED_KEY or OPENCLAW_AUTHORIZED_KEYS when running bootstrap to ensure login works."
  fi

  rm -f "$tmp_keys"
}

say "Installing base packages"
apt-get update -y
apt-get install -y sudo git curl ca-certificates

if ! id -u "$OPENCLAW_USER" >/dev/null 2>&1; then
  say "Creating user '$OPENCLAW_USER' non-interactively"
  useradd -m -s /bin/bash -G sudo "$OPENCLAW_USER"
  passwd -l "$OPENCLAW_USER" >/dev/null 2>&1 || true
else
  say "User '$OPENCLAW_USER' already exists"
  usermod -aG sudo "$OPENCLAW_USER" || true
fi

say "Granting passwordless sudo for bootstrap user"
echo "$OPENCLAW_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-openclaw-bootstrap
chmod 440 /etc/sudoers.d/90-openclaw-bootstrap

say "Configuring SSH authorized_keys for '$OPENCLAW_USER'"
install_authorized_keys_for_user "$OPENCLAW_USER"

say "Cloning/updating openclaw-droplet repo"
sudo -u "$OPENCLAW_USER" -H bash -lc "git config --global --add safe.directory '$REPO_DIR'"
if [[ -d "$REPO_DIR/.git" ]]; then
  sudo -u "$OPENCLAW_USER" -H bash -lc "cd '$REPO_DIR' && git pull --ff-only"
else
  sudo -u "$OPENCLAW_USER" -H bash -lc "git clone '$REPO_URL' '$REPO_DIR'"
fi

say "Running user bootstrap script"
sudo --preserve-env=DISCORD_BOT_TOKEN,DISCORD_TARGET,DISCORD_HUMAN_ID,DISCORD_USER_ID,DISCORD_HUMAN,OPENAI_API_KEY,ANTHROPIC_API_KEY,FRONTEND_ENABLED,FRONTEND_ALLOWED_IP,EXEC_APPROVAL_MODE,OPERATOR_BRIDGE_PORT,KIWI_EXEC_TIMEOUT_SECONDS,KIWI_EXEC_MAX_OUTPUT_BYTES -u "$OPENCLAW_USER" -H bash -lc "cd '$REPO_DIR' && bash scripts/bootstrap-openclaw.sh"

say "Installing global shim: /usr/local/bin/openclaw (runs as $OPENCLAW_USER)"
TARGET_BIN="$(sudo -u "$OPENCLAW_USER" -H bash -lc 'export PATH="$HOME/.npm-global/bin:$PATH"; command -v openclaw || test -x "$HOME/.npm-global/bin/openclaw" && echo "$HOME/.npm-global/bin/openclaw"' 2>/dev/null || true)"
cat >/usr/local/bin/openclaw <<EOF
#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="${OPENCLAW_USER}"
TARGET_BIN="${TARGET_BIN}"
ENV_FILE="/etc/openclaw/openclaw.env"
if [[ -z "\$TARGET_BIN" ]]; then
  echo "openclaw not found for user ${OPENCLAW_USER}"
  exit 127
fi
if [[ -f "\$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "\$ENV_FILE"
  set +a
fi
exec sudo -u "\$TARGET_USER" -H "\$TARGET_BIN" "\$@"
EOF
chmod 755 /usr/local/bin/openclaw

echo
echo "Done. You can now run 'openclaw' from root or any sudo user (it uses '$OPENCLAW_USER' context)."
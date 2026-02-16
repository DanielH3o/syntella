#!/usr/bin/env bash
set -euo pipefail

# Root-level non-interactive bootstrap for fresh Ubuntu droplets.
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
REPO_URL="${REPO_URL:-https://github.com/DanielH3o/openclaw-droplet.git}"
REPO_DIR="${REPO_DIR:-/home/${OPENCLAW_USER}/openclaw-droplet}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

say() { echo -e "\n==> $*"; }

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

# Ensure SSH key login works for the new user by copying root authorized_keys.
if [[ -f /root/.ssh/authorized_keys ]]; then
  say "Copying root authorized_keys to $OPENCLAW_USER"
  install -d -m 700 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" "/home/${OPENCLAW_USER}/.ssh"
  install -m 600 -o "$OPENCLAW_USER" -g "$OPENCLAW_USER" /root/.ssh/authorized_keys "/home/${OPENCLAW_USER}/.ssh/authorized_keys"
fi

say "Cloning/updating openclaw-droplet repo"
if [[ -d "$REPO_DIR/.git" ]]; then
  sudo -u "$OPENCLAW_USER" -H bash -lc "cd '$REPO_DIR' && git pull --ff-only"
else
  sudo -u "$OPENCLAW_USER" -H bash -lc "git clone '$REPO_URL' '$REPO_DIR'"
fi

say "Running user bootstrap script"
sudo -u "$OPENCLAW_USER" -H bash -lc "cd '$REPO_DIR' && bash scripts/bootstrap-openclaw.sh"

echo
echo "Done. You can now SSH directly as '$OPENCLAW_USER'."

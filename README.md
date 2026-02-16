# openclaw-droplet-kit

Opinionated starter kit to bootstrap an **OpenClaw Gateway** on a fresh DigitalOcean Ubuntu droplet in minutes.

## Goals

- Fast first deploy (copy/paste + one script)
- Safe defaults (Gateway bound to loopback, token auth)
- Easy access to chat/dashboard from your own devices (SSH tunnel, no extra accounts)
- Idempotent setup (safe to re-run)

## Quick Start (fewest inputs)

```bash
# 1) SSH into new Ubuntu droplet as root
ssh root@YOUR_DROPLET_IP

# 2) One command: create user non-interactively + run full bootstrap
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

This avoids interactive `adduser` prompts entirely.

It also installs a global `/usr/local/bin/openclaw` shim so you can run `openclaw ...` from root/sudo users without switching accounts (commands run in the `openclaw` user context).

If you want deterministic SSH key install for the `openclaw` user, run with your public key explicitly:

```bash
export OPENCLAW_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)"
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

## Quick Start (manual SSH path)

```bash
# 1) SSH into new Ubuntu droplet
ssh root@YOUR_DROPLET_IP

# 2) Create non-root user (interactive)
adduser openclaw
usermod -aG sudo openclaw
su - openclaw

# 3) Get this repo + run installer
git clone https://github.com/DanielH3o/openclaw-droplet.git
cd openclaw-droplet
bash scripts/bootstrap-openclaw.sh
```

When done, the script prints:
- SSH tunnel command for dashboard/chat
- Local URL (`http://localhost:18789`)
- Gateway token location

## Security Model (default)

- `gateway.bind = loopback`
- `gateway.auth.mode = token`
- Remote access via **SSH tunnel**
- No need to publicly expose port `18789`

## Family Mode (no tunnel, no domain)

If you want direct access from browser via droplet IP, use public UI mode with an IP allowlist.

```bash
# On droplet as root
export PUBLIC_UI=1
export ALLOW_CIDRS="YOUR_IP/32,DADS_IP/32"
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

What this does:
- Sets `gateway.bind = lan`
- Keeps `gateway.auth.mode = token`
- Configures UFW to allow port `18789/tcp` **only** from `ALLOW_CIDRS`
- Keeps SSH (`22/tcp`) open

Then open:
- `http://<droplet-ip>:18789` (from an allowed IP)

## Files

- `scripts/bootstrap-openclaw.sh` — main installer
- `scripts/bootstrap-root.sh` — root one-shot bootstrap (non-interactive user creation)
- `cloud-init/user-data.yaml` — optional unattended first boot path
- `docs/rollout-plan.md` — roadmap from MVP to reusable product

## What this does *not* do yet

- Create droplets for you (Terraform/API integration planned)
- Auto-DNS to a public domain
- Team SSO or multi-tenant setup

## Troubleshooting

### `Permission denied (publickey)` when tunneling as `openclaw`

From your local machine, test auth with verbose logs and explicit key:

```bash
ssh -i ~/.ssh/id_ed25519 -v openclaw@YOUR_DROPLET_IP
```

On the droplet (as root), verify key file + perms:

```bash
ls -ld /home/openclaw/.ssh
ls -l /home/openclaw/.ssh/authorized_keys
sudo -u openclaw -H bash -lc 'wc -l ~/.ssh/authorized_keys && head -n 1 ~/.ssh/authorized_keys'
```

If needed, re-run root bootstrap with explicit key injection:

```bash
export OPENCLAW_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)"
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

### `Disconnected from gateway (1008): unauthorized: device token mismatch`

This is usually stale browser device auth for `localhost:18789`.

1. Ensure SSH tunnel is active.
2. Open in a private/incognito window.
3. If that works, clear local storage for `http://localhost:18789` (or remove keys `openclaw-device-identity-v1` and `openclaw.device.auth.v1`) and reload.

## Next steps

1. Replace placeholders in `cloud-init/user-data.yaml`
2. Add Terraform for one-command droplet provisioning
3. Add CI to test script on Ubuntu LTS versions
4. Publish as template repo and/or GitHub Action

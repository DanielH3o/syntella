# openclaw-droplet-kit

Opinionated starter kit to bootstrap an **OpenClaw Gateway** on a fresh DigitalOcean Ubuntu droplet in minutes.

## Goals

- Fast first deploy (copy/paste + one script)
- Safe defaults (Gateway bound to loopback, token auth)
- Easy access to chat/dashboard from your own devices (Tailscale Serve)
- Idempotent setup (safe to re-run)

## Quick Start (fewest inputs)

```bash
# 1) SSH into new Ubuntu droplet as root
ssh root@YOUR_DROPLET_IP

# 2) One command: create user non-interactively + run full bootstrap
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

This avoids interactive `adduser` prompts entirely.

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
- Tailscale HTTPS URL for dashboard/chat
- Local fallback URL + SSH tunnel command
- Gateway token location

## Security Model (default)

- `gateway.bind = loopback`
- `gateway.auth.mode = token`
- Remote access via **Tailscale Serve** (HTTPS + identity)
- No need to publicly expose port `18789`

## Files

- `scripts/bootstrap-openclaw.sh` — main installer
- `cloud-init/user-data.yaml` — optional unattended first boot path
- `docs/rollout-plan.md` — roadmap from MVP to reusable product

## What this does *not* do yet

- Create droplets for you (Terraform/API integration planned)
- Auto-DNS to a public domain
- Team SSO or multi-tenant setup

## Next steps

1. Replace placeholders in `cloud-init/user-data.yaml`
2. Add Terraform for one-command droplet provisioning
3. Add CI to test script on Ubuntu LTS versions
4. Publish as template repo and/or GitHub Action

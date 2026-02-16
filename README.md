# openclaw-droplet-kit

Opinionated bootstrap for running OpenClaw on a DigitalOcean Ubuntu droplet with **Discord as the primary interface**.

## What this setup does

- Installs OpenClaw non-interactively
- Keeps gateway private (`gateway.bind=loopback`, token auth)
- Configures Discord bot token
- Restricts Discord ingress to a single guild/channel allowlist
- Disables Discord DMs by default
- Sets up a public workspace frontend (`nginx`, default `http://<droplet-ip>`)
- Sends a startup ping message to the configured Discord channel after bootstrap (includes frontend URL)
- Installs a global `/usr/local/bin/openclaw` shim (so root/sudo users can run `openclaw ...` without switching users)

## Required inputs

- `DISCORD_BOT_TOKEN`
- `DISCORD_TARGET` in one of these formats:
  - `<guildId>/<channelId>`
  - `<guildId>:<channelId>`
  - `guild:<guildId>/channel:<channelId>`

## Quick Start (fewest inputs)

```bash
# 1) SSH into new droplet as root
ssh root@YOUR_DROPLET_IP

# 2) Set Discord values
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
# Optional: disable placeholder frontend
# export FRONTEND_ENABLED=0

# 3) Run bootstrap
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

## Optional: deterministic SSH key install for `openclaw` user

```bash
export OPENCLAW_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)"
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
curl -fsSL https://raw.githubusercontent.com/DanielH3o/openclaw-droplet/main/scripts/bootstrap-root.sh | bash
```

After bootstrap, frontend files are in:

- `~/.openclaw/workspace/project`

Edit those files (or ask your agent to edit them), then refresh browser.

## Manual path

```bash
ssh root@YOUR_DROPLET_IP
adduser openclaw
usermod -aG sudo openclaw
su - openclaw

git clone https://github.com/DanielH3o/openclaw-droplet.git
cd openclaw-droplet
export DISCORD_BOT_TOKEN="YOUR_DISCORD_BOT_TOKEN"
export DISCORD_TARGET="YOUR_GUILD_ID/YOUR_CHANNEL_ID"
bash scripts/bootstrap-openclaw.sh
```

## Troubleshooting

### `Permission denied (publickey)` for `openclaw`

```bash
ssh -i ~/.ssh/id_ed25519 -v openclaw@YOUR_DROPLET_IP
ls -ld /home/openclaw/.ssh
ls -l /home/openclaw/.ssh/authorized_keys
```

If needed, re-run root bootstrap with explicit key injection (`OPENCLAW_AUTHORIZED_KEY=...`).

### Discord messages not reaching agent

- Verify bot is invited to the target guild/channel
- Verify token is correct
- Verify target IDs are correct
- Verify bot can post in the configured channel
- If bootstrap did not send the startup ping, test manually:

```bash
openclaw message send --channel discord --target "channel:YOUR_CHANNEL_ID" --message "test"
```

- On droplet:

```bash
openclaw status
openclaw gateway status || true
tail -n 120 ~/.openclaw/logs/gateway.log
```

## Files

- `scripts/bootstrap-openclaw.sh` — main installer (Discord-first)
- `scripts/bootstrap-root.sh` — non-interactive root bootstrap
- `cloud-init/user-data.yaml` — optional unattended first boot
- `docs/rollout-plan.md` — roadmap

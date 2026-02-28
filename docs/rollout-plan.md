# Rollout Plan

## Phase 1 (now): SSH bootstrap kit

- [x] Bootstrap script for Ubuntu droplet
- [x] Cloud-init example for unattended setup
- [x] Documentation for secure access path (Tailscale)

## Phase 2: One-command infra provisioning

- [ ] Terraform module for DigitalOcean droplet + firewall + tags
- [ ] Optional cloud-init injection from Terraform
- [ ] Outputs: droplet IP, tailscale hostname, setup logs link

## Phase 3: Productized onboarding

- [ ] Setup wizard (`./bin/new-syntella`)
- [ ] Prompt for do token, ssh key, hostname, region
- [ ] Create droplet + wait for health checks
- [ ] Print dashboard URL + initial login/token instructions

## Phase 4: Hardening and operability

- [ ] `openclaw security audit` post-check in script
- [ ] Daily apt upgrades + unattended-upgrades config
- [ ] Automated smoke tests for new OpenClaw releases
- [ ] GitHub Actions matrix for Ubuntu 22/24

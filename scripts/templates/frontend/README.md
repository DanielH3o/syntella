# Workspace Frontend Project

This folder is served by nginx at the droplet public URL.

- `/` dashboard
- `/admin` admin panel to list and create dedicated agents
- `/api/agents` and `/api/spawn-agent` are proxied to localhost operator bridge

Security:
- Frontend access is IP-allowlisted via `FRONTEND_ALLOWED_IP` in bootstrap.
- Share bot tokens only through `/admin` (never in Discord).

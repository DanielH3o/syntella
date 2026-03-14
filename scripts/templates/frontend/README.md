# Syntella Admin Frontend

This frontend is served from the Syntella-managed `admin/` directory on the droplet.

- `/admin` admin panel to list and create dedicated agents
- `/admin` now loads split assets instead of one monolithic file:
  - `admin.css`
  - `admin-core.js`
  - `admin-work.js`
  - `admin-models.js`
  - `admin-integrations.js`
  - `admin-budget.js`
  - `admin-team.js`
- `/api/*` is proxied to the Syntella API, which then proxies bridge-specific calls when needed

The customer-owned website/project surface is separate and should live under:

- `~/.openclaw/workspace/project`

Security:
- Frontend access is IP-allowlisted via `FRONTEND_ALLOWED_IP` in bootstrap.
- Share bot tokens only through `/admin` (never in Discord).

# TASKS.md (Legacy)

This file is no longer the operational source of truth for Syntella tasks.

Use the real task system instead:

- DB: `~/.openclaw/workspace/tasks.db`
- Admin UI: `http://127.0.0.1:3000/admin#tasks`
- API: `http://127.0.0.1:3000/api/tasks`

Canonical statuses:

- `backlog`
- `in_progress`
- `review`
- `done`

Notes:

- Starting work should move a task to `in_progress`.
- Finishing implementation should usually move it to `review`.
- Accepted work should move to `done`.
- Task runs and estimated cost attribution are driven off these status transitions.

Keep this file only for compatibility with older workspace setups. Do not maintain a parallel manual ledger here.

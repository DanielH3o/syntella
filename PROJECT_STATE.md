# Syntella Project State

This file is the working memory for the Syntella product and local dev environment.
Use it to track what exists, what is in progress, what decisions were made, and what should happen next.

## Product Direction

Syntella is evolving into a local-first control plane for a multi-agent OpenClaw setup.

Primary goals:

- manage agents/departments visually
- create and track tasks locally
- measure model usage and cost by agent
- eventually connect spend to delivered outcomes, not just token volume
- make iteration fast locally without needing droplet rebuilds for every change

## Current Architecture

Frontend:

- static admin UI in [scripts/templates/frontend/admin.html](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin.html)
- served locally by the Python dev server

Local server:

- [scripts/local-dev-server.py](/Users/daniel/.openclaw/workspace/syntella/scripts/local-dev-server.py)
- started via [scripts/dev-server.sh](/Users/daniel/.openclaw/workspace/syntella/scripts/dev-server.sh)
- serves frontend and local JSON APIs

Local data sources:

- task data in `~/.openclaw/workspace/tasks.db`
- agent registry in `~/.openclaw/workspace/agents/registry.json`
- usage telemetry from `~/.openclaw/agents/*/sessions/*.jsonl`

## Decisions Made

### Platform

- Stay on OpenClaw for now.
- Do not switch to NanoClaw at this stage.
- Reason: OpenClaw already stores usable local usage telemetry per message/session/agent, so the main missing layer is attribution, not token accounting.

### Local development

- Local-first workflow is required.
- The droplet/bootstrap path is too slow for iterative UI and product work.
- The local server is now the main dev loop for dashboard/admin work.

### Budget tracking

- Real usage and cost should be ingested from OpenClaw session logs.
- Budget UI should be live-backed from local usage data.
- Cost per task will be estimated in v1 using `agent_id + time window`.
- This must be labeled as estimated, not exact.

## What Is Done

### Local server

- Single local dev server serves frontend and local APIs.
- No longer depends on preview-only hardcoded registry setup.
- APIs currently available:
  - `/api/tasks`
  - `/api/departments`
  - `/api/agents`
  - `/api/usage`
  - `/api/usage/summary`
  - `/api/usage/sync`

### Departments page

- Reworked into an interactive org chart.
- Root agent now comes from actual local OpenClaw state, preferring `main`.
- Discovered local agents render beneath the root.
- Details panel updates on click.
- Org chart now hydrates from actual discovered OpenClaw agents, not just the stale workspace registry.

### Tasks page

- Moved off dummy cards onto the local API.
- Loads live tasks from SQLite.
- New task form works locally.
- Drag-and-drop status updates persist via API.
- Task cards now show estimated cost and run status.
- Task detail panel now shows estimated tokens/cost and run history.

### Task attribution

- `task_runs` table added to local DB.
- A run auto-opens when a task moves into `in_progress`.
- A run auto-closes when a task leaves active execution.
- Estimated task cost is now computed from `usage_events` for that agent during the run window.
- This is intentionally approximate for v1.

### Budget page

- Added a dedicated Budget page to the admin UI.
- Initially demo-backed, now converted to live usage data.
- Pulls real usage/cost telemetry from ingested OpenClaw sessions.
- Includes top cost tasks based on estimated task-run attribution.
- Shows:
  - projected monthly spend
  - actual spend
  - token totals
  - cost by agent
  - cost by model
  - top cost tasks
  - recent usage events
  - budget alerts

### Usage ingestion

- `usage_events` table added to local DB.
- OpenClaw session files are scanned and normalized into SQLite.
- Real fields captured:
  - `agent_id`
  - `session_id`
  - `message_id`
  - `timestamp`
  - `provider`
  - `model`
  - `input_tokens`
  - `output_tokens`
  - `cache_read_tokens`
  - `cache_write_tokens`
  - `total_tokens`
  - `cost_input`
  - `cost_output`
  - `cost_cache_read`
  - `cost_cache_write`
  - `total_cost`

## Known Limitations

### Cost attribution is approximate

The system now estimates task cost by:

- opening a run when a task enters `in_progress`
- closing it when the task leaves active execution
- summing `usage_events` for the assigned agent during that run window

This means overlap can occur if the same agent does unrelated work during that period.
The estimate is useful for v1 but is not exact billing attribution.

### Some model prices are zero in OpenClaw data

Example:

- `gemini-3.1-pro-preview` currently reports token usage but `cost.total = 0` in local OpenClaw records
- this appears to come from OpenClaw model metadata, not from the Syntella UI

### Token totals can be confusing

OpenClaw `total_tokens` includes:

- input tokens
- output tokens
- cache read tokens
- cache write tokens

This means total accounted tokens can be much larger than just input + output.

## Immediate Next Step

Improve attribution accuracy beyond pure time-window matching.

Immediate direction:

1. Attach exact `session_id` to task runs when possible.
2. Add richer task-level budget reporting and filtering.
3. Decide how task assignment should map to real local agent IDs when old placeholder task data exists.

## Planned Next Work

### V1.1 Task runs

- refine task run lifecycle rules
- decide exact terminal statuses
- support reopened tasks cleanly
- improve task detail/run presentation

### V1.2 Task-level budget visibility

- cost per task
- cost per agent per task
- recent expensive tasks
- compare task cost vs task outcome/status

### V1.3 Attribution improvements

- attach exact `session_id` to task runs when possible
- move from pure time-window attribution to session-aware attribution
- eventually attach explicit `run_id` / `task_id` to execution context

## Future Versions

### V2

- budget alerts based on configurable limits
- pricing overrides for models with missing/zero OpenClaw costs
- cost per shipped task/outcome
- usage trends over time
- filters by department, model family, task status

### V3

- budget recommendations
- model routing policy engine
- detect wasteful task loops/retries
- compare cost vs success rate by model
- team/department performance economics dashboard

## Open Questions

- What should count as terminal for a task run: `review`, `done`, `cancelled`, all of them?
- Should one task support multiple runs by default?
- Should reopening a task create a new run automatically?
- Where should exact run/session mapping live once we improve attribution?
- Do we want editable budget caps in the UI or config-first for now?

## Practical Commands

Start local dev server:

```bash
bash scripts/dev-server.sh
```

Useful local URLs:

- `http://127.0.0.1:3000/`
- `http://127.0.0.1:3000/admin`
- `http://127.0.0.1:3000/admin#tasks`
- `http://127.0.0.1:3000/admin#budget`
- `http://127.0.0.1:3000/admin#agents`

Useful API URLs:

- `http://127.0.0.1:3000/api/tasks`
- `http://127.0.0.1:3000/api/departments`
- `http://127.0.0.1:3000/api/usage`
- `http://127.0.0.1:3000/api/usage/summary?days=30`

## Update Rule

Whenever a meaningful product or architecture decision is made, update this file.
Whenever a feature moves from idea to implementation, update this file.
Whenever priorities change, update the "Immediate Next Step" and "Planned Next Work" sections first.

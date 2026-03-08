# Syntella Project State

This file is the working memory for the Syntella product and local dev environment.
Use it to track what exists, what is in progress, what decisions were made, and what should happen next.

## Product Direction

Syntella is evolving into a local-first control plane for a multi-agent OpenClaw setup.

Primary goals:

- manage agents visually
- create new agents locally from the admin UI
- configure which models are available to agents
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
- agent discovery from `~/.openclaw/agents/*`
- global model config from `~/.openclaw/openclaw.json`
- usage telemetry from `~/.openclaw/agents/*/sessions/*.jsonl`

## Decisions Made

### Platform

- Stay on OpenClaw for now.
- Do not switch to NanoClaw at this stage.
- Reason: OpenClaw already stores usable local usage telemetry per message/session/agent, so the main missing layer is attribution, not token accounting.
- Syntella/main should own the primary heartbeat-based control loop.
- Worker agents should remain event-driven by default and only get their own heartbeat for narrow, explicit reasons.

### Local development

- Local-first workflow is required.
- The droplet/bootstrap path is too slow for iterative UI and product work.
- The local server is now the main dev loop for dashboard/admin work.

### Agent and model management

- Agent creation should be available from the Team page.
- Model availability and pricing should have a dedicated Models page.
- External service credentials and tool configuration should have a dedicated Integrations page.
- Model pricing should default from OpenClaw/local model metadata when available.
- Missing or zero-cost model pricing should be overridable locally by the user.
- `~/.openclaw/openclaw.json` is the canonical base catalog for models in this environment.
- Agent workspace instructions should treat `~/.openclaw/workspace/tasks.db` and `/api/tasks` as the canonical task system.
- `~/.openclaw/workspace/shared/TASKS.md` is now legacy compatibility context, not the source of truth.
- Task workflow is moving out of prompt text and into a real OpenClaw plugin tool plus companion skill.
- Agent communication is shifting away from one shared Discord room to one inbox channel per agent.
- `HEARTBEAT.MAIN.md` should reflect a main-only orchestration loop that uses the `tasks` tool as the operational source of truth.

### Client SEO agent

- The Wonderful Payments / Asima SEO agent should be built as:
  - one primary SEO operating skill
  - focused data/publishing tools
  - routines driving the ongoing workflow
- Publishing should remain approval-gated in v1.
- Paid placements and paid acquisition automation are out of scope for this client implementation.
- SEO capability should be scoped only to explicitly designated SEO agents, not seeded into every agent workspace by default.

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
  - `/api/models`
  - `/api/models/overrides`
  - `/api/spawn-agent`
  - `/api/operator-bridge/health`
  - `/api/usage`
  - `/api/usage/summary`
  - `/api/usage/sync`
  - `/api/costs/by-task`
- Droplet bootstrap now needs to run a dedicated Syntella API process in addition to nginx and the operator bridge.
- Public `/api/*` traffic on droplet should terminate at the Syntella API, which then proxies bridge-specific calls internally.

### Team page

- Reworked into an interactive Team view.
- Root agent now comes from actual local OpenClaw state, preferring `main`.
- Main now renders as a highlighted lead card at the top.
- Discovered local agents render beneath it as peer cards instead of a formal org-chart hierarchy.
- Details drawer updates on click.
- Team page now hydrates from actual discovered OpenClaw agents, not the stale workspace registry.
- Team page starts with no selected agent and the details drawer closed.
- Selected agent details now open in a screen-edge sidenav overlay.
- Added a Team-side New Agent drawer wired to the shared Models catalog.
- Team agent creation now submits through the local dev server to the operator bridge.
- New-agent creation now requires an inbox `channel_id`.
- Team metadata now surfaces each agent's inbox channel.
- Team page now lets the user set an optional `monthly_budget` during agent creation.
- Selected-agent drawer now lets the user edit an agent's monthly budget in place.

### Models page

- Added a dedicated Models page to the admin UI.
- Models are derived from `~/.openclaw/openclaw.json` plus observed usage history.
- Provider credentials are not exposed through the Syntella model API.
- Added a Syntella-managed `model_overrides` table for:
  - enabled/disabled availability
  - pricing overrides
  - custom display metadata
  - custom models not present in local OpenClaw metadata
- Saving a model now patches the global OpenClaw catalog in `~/.openclaw/openclaw.json`.
- Model creation/editing now uses a right-side drawer instead of an always-visible inline editor.
- The model drawer now supports provider connection fields including base URL, adapter, and API key entry.
- Clearing an override removes only the Syntella override layer, not the base OpenClaw model entry.
- Models page supports:
  - catalog listing
  - provider/status/search filters
  - editing pricing overrides
  - creating custom models
  - clearing overrides back to the base metadata

### Integrations page

- Added a dedicated Integrations page to the admin UI.
- Added a new `integrations` table to the local control-plane DB.
- Integrations currently supported as first-class config objects:
  - Ghost CMS
  - Google Search Console
  - Google Analytics
- Integration secrets are write-only in the UI.
- Integration config now supports:
  - enabled/disabled status
  - specialty scoping (`seo` or unrestricted)
  - config fields
  - credential fields
  - notes
- Added APIs for:
  - `/api/integrations`
- This page is intended to be the control layer for future `ghost`, `search-console`, and `analytics` tools.

### Tasks page

- Moved off dummy cards onto the local API.
- Loads live tasks from SQLite.
- New task form works locally.
- Drag-and-drop status updates persist via API.
- Task cards now show estimated cost and run status.
- Task detail panel now shows estimated tokens/cost and run history.
- Workspace templates now instruct agents to interact with tasks through the real task system instead of maintaining a parallel ledger in `shared/TASKS.md`.
- Added a matching `reports` plugin/tool so agents can create durable routine outputs and longer findings instead of only posting summaries in chat.
- Simplified both seeded `AGENTS.md` communication sections to match the inbox-channel model and removed the old shared-channel reply/debounce rules.

### Routines and Reports

- Added first-pass `routines`, `routine_runs`, and `reports` tables to the local control-plane DB.
- Added APIs for:
  - `/api/routines`
  - `/api/routines/:id`
  - `/api/routines/:id/run`
  - `/api/reports`
  - `/api/reports/:id`
- Added top-level `Routines` and `Reports` admin pages.
- Routines currently support:
  - create/edit
  - enable/disable
  - structured schedule input in the admin UI
  - one-shot `Date` mode for testing/single scheduled runs
  - compiled cron expressions
  - assigned agent
  - output mode
  - manual `Run Now`
- Routine create/edit/detail now uses a right-side drawer instead of a permanent inline card, matching the Team and Models interaction pattern.
- Routine scheduling UI is now mode-specific:
  - daily / weekdays: time only
  - weekly: day + time
  - hourly: interval only
  - date: date + time
  - custom: raw cron only
- Routine schedules now use the browser/machine timezone automatically instead of a freeform timezone field in the UI.
- Routine save now attempts to sync a real OpenClaw cron job, storing `cron_job_id` and `cron_expression` on the routine.
- `Run Now` now attempts to execute the synced OpenClaw cron job instead of creating a placeholder report directly in the backend.
- Full runtime verification of the exact OpenClaw cron CLI flags is still pending on a real running environment.
- Agents are now being updated to use a `reports` tool for durable output, but full routine execution still needs to call that path automatically.

### Frontend refactor

- Frontend refactor is underway to move the admin surface away from one giant HTML file.
- `admin.html` now loads dedicated assets:
  - [admin.css](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin.css)
  - [admin-core.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin-core.js)
  - [admin-work.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin-work.js)
  - [admin-models.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin-models.js)
  - [admin-budget.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin-budget.js)
  - [admin-team.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin-team.js)
- [admin.js](/Users/daniel/.openclaw/workspace/syntella/scripts/templates/frontend/admin.js) is now just a deprecated stub kept only to avoid confusion during the transition.
- Bootstrap now copies the split admin assets to the droplet project directory.
- Admin section data now refreshes again when the user switches tabs/sections instead of only fetching once on initial page load.

### Tasks plugin

- Added a seeded workspace plugin `syntella-tasks` under the workspace extension templates.
- Added a companion `tasks-tool` skill that tells agents to use the tool instead of manual curl/API walkthroughs.
- Plugin registration now uses the OpenClaw optional-tool pattern and includes an explicit manifest `configSchema`.
- Bootstrap and spawned-agent config now explicitly enable the plugin under `plugins.allow` and `plugins.entries.syntella-tasks.enabled`.
- The tool currently supports:
  - `list`
  - `list_mine`
  - `get`
  - `create`
  - `update_status`
  - `update_description`
- The helper updates `task_runs` when status transitions happen so task-cost attribution still works.

### Reports plugin

- Added a seeded workspace plugin `syntella-reports` under the workspace extension templates.
- Added a companion `reports-tool` skill for durable report creation guidance.
- Bootstrap and spawned-agent config now explicitly enable the plugin under `tools.allow`, `plugins.allow`, and `plugins.entries.syntella-reports.enabled`.
- The tool currently supports:
  - `list_recent`
  - `list_mine`
  - `get`
  - `create`
- Agent templates now instruct agents to use the `reports` tool for routine outputs and longer durable findings instead of relying on chat alone.

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
- Agent budget caps now come from Team/registry metadata instead of hardcoded frontend values.
- Added a top-level Budget Envelope meter showing actual spend and projected spend against the total configured team budget.
- Budget scope is now calendar month based, so actual month-to-date spend and projected month-end spend are compared against monthly caps on the same timeframe.
- Shows:
  - projected monthly spend
  - actual spend
  - token totals
  - cost by agent
  - cost by model
  - top cost tasks
  - recent usage events
- budget alerts

### Client SEO implementation plan

- Added a concrete SEO implementation plan in [SEO_AGENT_IMPLEMENTATION_PLAN.md](/Users/daniel/.openclaw/workspace/syntella/SEO_AGENT_IMPLEMENTATION_PLAN.md).
- Planned architecture:
  - `seo-authority-operator` skill
  - `search-console` tool
  - `analytics` tool
  - `ghost` tool
  - `signals` tool
  - reuse existing `tasks` and `reports` tools
- Planned routine set:
  - Daily SEO Review
  - Daily Industry Monitor
  - Weekly Editorial Planner
  - Draft Production Run
  - Performance Refresh Review
- Seeded the first `seo-authority-operator` skill scaffold into workspace templates under the SEO extension path.
- Bootstrap now keeps the SEO extension only as a shared template; spawned agents inherit it only when created with SEO specialty.
- Agent templates now tell Syntella/spawned agents to use the SEO skill when assigned editorial authority or search-optimisation work.

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
- the Models page now provides the override layer needed to fix this locally without mutating OpenClaw files
- the Budget pipeline now falls back to override/catalog pricing on a per-event basis when OpenClaw logged zero cost

### Token totals can be confusing

OpenClaw `total_tokens` includes:

- input tokens
- output tokens
- cache read tokens
- cache write tokens

This means total accounted tokens can be much larger than just input + output.

## Immediate Next Step

Deploy to a fresh droplet and verify the new routine/reporting/runtime path end to end.

Immediate direction:

1. Verify the seeded `syntella-tasks` and `syntella-reports` plugins both load correctly in real OpenClaw workspaces.
2. Verify routine save creates/updates real OpenClaw cron jobs, including one-shot `Date` routines.
3. Verify `Run Now` triggers the intended agent turn through OpenClaw cron.
4. Verify successful routine runs create durable DB-backed reports through the `reports` tool on a real droplet.
5. Then harden Team-page agent creation and operator-bridge failure visibility further.
6. After that, improve attribution accuracy by attaching exact `session_id` to task runs when possible.

## Planned Next Work

### V1.1 Routine execution hardening

- verify exact OpenClaw cron CLI behavior in droplet runtime
- handle cron create/edit/enable/disable/run failures more gracefully
- show cron job state, next run, and sync failures in the Routines UI
- remove any remaining placeholder-only routine/report behavior

### V1.2 Agent creation

- create new local agents from the Team page
- done: name/role/description/model/channel selection and optional monthly budget
- done: refresh Team and Task assignee lists immediately after creation
- remaining: improve bridge failure visibility and reduce the Discord-token dependency if possible

### V1.3 Models page follow-up

- define default model choices for future agents
- show stronger pricing provenance and warning states
- decide whether disabled models should be hidden from all other UI surfaces by default

### V1.4 Reports integration

- make routine executions reliably create DB-backed reports through the `reports` tool
- decide whether file-based markdown reports should remain optional, secondary output
- surface report provenance more clearly in the Reports UI

### V1.5 Task runs

- refine task run lifecycle rules
- decide exact terminal statuses
- support reopened tasks cleanly
- improve task detail/run presentation

### V1.6 Task-level budget visibility

- cost per task
- cost per agent per task
- recent expensive tasks
- compare task cost vs task outcome/status
- make task and budget views cross-link cleanly

### V1.7 Attribution improvements

- attach exact `session_id` to task runs when possible
- move from pure time-window attribution to session-aware attribution
- eventually attach explicit `run_id` / `task_id` to execution context

## Future Versions

### V2

- budget alerts based on configurable limits
- pricing overrides for models with missing/zero OpenClaw costs
- cost per shipped task/outcome
- usage trends over time
- filters by team member, model family, task status
- agent templates / presets

### V3

- budget recommendations
- model routing policy engine
- detect wasteful task loops/retries
- compare cost vs success rate by model
- team/department performance economics dashboard

## Open Questions

- Which model metadata source should be canonical: OpenClaw model config, ingested usage data, or a Syntella-managed catalog layered on top?
- What should count as terminal for a task run: `review`, `done`, `cancelled`, all of them?
- Should one task support multiple runs by default?
- Should reopening a task create a new run automatically?
- Where should exact run/session mapping live once we improve attribution?

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
- `http://127.0.0.1:3000/admin#models`
- `http://127.0.0.1:3000/admin#routines`
- `http://127.0.0.1:3000/admin#reports`
- `http://127.0.0.1:3000/admin#team`

Useful API URLs:

- `http://127.0.0.1:3000/api/tasks`
- `http://127.0.0.1:3000/api/departments`
- `http://127.0.0.1:3000/api/models`
- `http://127.0.0.1:3000/api/routines`
- `http://127.0.0.1:3000/api/reports`
- `http://127.0.0.1:3000/api/usage`
- `http://127.0.0.1:3000/api/usage/summary?days=30`

## Update Rule

Whenever a meaningful product or architecture decision is made, update this file.
Whenever a feature moves from idea to implementation, update this file.
Whenever priorities change, update the "Immediate Next Step" and "Planned Next Work" sections first.

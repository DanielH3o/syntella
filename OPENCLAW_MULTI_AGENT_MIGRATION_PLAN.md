# OpenClaw Multi-Agent Migration Plan

This file defines the migration from Syntella's current "one OpenClaw home per spawned agent" approach to a native single-root OpenClaw multi-agent architecture.

## Why change

The current spawn model creates a separate OpenClaw home per agent:

- `~/.openclaw`
- `~/.openclaw-seo`
- `~/.openclaw-webdev`
- etc.

That approach has worked as a prototype, but it is fighting OpenClaw's intended multi-agent design.

Recent bugs all came from this mismatch:

- child agents inheriting the root workspace
- child agents inheriting the root Discord token
- child agents identifying themselves as `main`
- plugin discovery/load path drift
- Syntella needing custom discovery logic for agents outside `~/.openclaw/agents/*`

OpenClaw's native model is one root state directory with multiple configured agents under it.

## Target architecture

Use a single OpenClaw root:

- `~/.openclaw/openclaw.json`
- `~/.openclaw/agents/main`
- `~/.openclaw/agents/webdev`
- `~/.openclaw/agents/seo`

Each agent should have:

- its own `agentDir`
- its own sessions
- its own workspace
- its own bindings
- optionally its own Discord account binding

Syntella should remain the control plane on top of that one OpenClaw installation.

## Desired properties

After migration:

- all agents appear under `~/.openclaw/agents/<agent_id>`
- agent discovery no longer needs to merge separate homes
- agent identity is native, not simulated through env only
- plugin loading works from one shared OpenClaw root
- agent creation modifies one canonical OpenClaw config
- Discord routing is managed through native OpenClaw multi-agent bindings

## What should stay the same

- per-agent workspace folders in `~/.openclaw/workspace/<agent_id>`
- Syntella frontend pages:
  - Team
  - Tasks
  - Budget
  - Models
  - Integrations
  - Routines
  - Reports
- task/report tools
- SEO specialty concept
- inbox-channel communication model

## Migration phases

## Phase 1: configuration model redesign

Stop treating "spawn agent" as "create a new OpenClaw installation".

Instead, make spawn:

1. allocate a new `agent_id`
2. create/update that agent in the root OpenClaw config
3. create:
   - workspace path
   - agentDir path
   - channel/account bindings
4. reload/restart the single Gateway

Required config concepts:

- `agents.list` or equivalent multi-agent declaration
- per-agent workspace
- per-agent model defaults
- per-agent specialty metadata
- per-agent Discord binding

## Phase 2: directory layout unification

Move runtime state so child agents live under the root home:

- sessions: `~/.openclaw/agents/<agent_id>/sessions`
- agent config/runtime dir: `~/.openclaw/agents/<agent_id>/agent`
- no more top-level `~/.openclaw-<agent_id>` homes

Syntella should stop creating:

- `~/.openclaw-seo`
- `~/.openclaw-webdev`
- etc.

## Phase 3: plugin/tool loading simplification

Move task/report/SEO extensions to a single shared load path for the root OpenClaw install.

Then:

- enable plugins per agent where needed
- allow tools per agent where needed
- do not copy plugin code into multiple isolated homes

This should remove the recent:

- plugin path mismatch bugs
- plugin discovery bugs
- per-home plugin duplication

## Phase 4: Discord routing redesign

Use OpenClaw's native multi-agent Discord account/binding model where possible.

Target pattern:

- Syntella/main has the control channel
- each specialist agent has its own inbox channel
- Discord accounts are bound to the correct `agentId`
- replies intended for Syntella go to Syntella's control channel

Syntella should manage:

- inbox channel id
- control channel id
- Discord token/account mapping

But the runtime should be native multi-agent, not separate homes with separate gateways.

## Phase 5: admin/backend cleanup

After migration, simplify the codebase:

- remove separate-home discovery logic
- remove separate-home spawn assumptions
- stop storing `home = ~/.openclaw-<agent>` for new agents
- simplify Team discovery to read the root OpenClaw agent list
- simplify usage ingestion because all sessions will live under one root

## Data model changes

Registry should continue to exist for Syntella metadata, but it should not be the runtime source of truth.

Registry should contain:

- `agent_id`
- `role`
- `description`
- `specialty`
- `monthly_budget`
- `channel_id`
- optional `control_channel_id`
- optional frontend-only metadata

Registry should no longer need to own:

- separate OpenClaw home path per child
- child gateway PID per child in the same way as today

## Deployment impact

Bootstrap will need to change substantially:

- one root OpenClaw runtime
- one gateway process
- one operator bridge that edits the root config
- a safe reload/restart path after agent creation

The old spawn script should be replaced by:

- config mutation
- workspace seeding
- service reload

not by launching a separate child gateway.

## Risks

Main risks:

- breaking existing spawned agents during migration
- Discord account binding complexity
- needing a safe Gateway reload story
- ensuring plugin loading stays stable during config changes

## Rollout approach

Recommended rollout:

1. Keep current system working for now.
2. Add a parallel "native multi-agent" spawn path behind a flag.
3. Test it on fresh droplets only.
4. Verify:
   - agents appear under `~/.openclaw/agents/<agent_id>`
   - correct workspace is loaded
   - correct Discord account binds
   - tasks/reports tools work
5. Once stable, retire the separate-home spawn path.

## First concrete implementation step

The next implementation step should be:

1. inspect the exact OpenClaw root config shape needed for native multi-agent registration
2. prototype one non-main agent under the root home
3. verify:
   - workspace path
   - agentDir path
   - sessions path
   - Discord binding
   - tasks tool access

Only after that should Syntella's Team "New Agent" be rewritten to use the new path.

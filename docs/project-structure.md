~/.openclaw/
├── openclaw.json
├── credentials/                 # managed by OpenClaw
├── agents/                      # sessions/state managed by OpenClaw
├── workspace/
│  ├── shared/                   # collaborative area across agents
│  │  ├── project/
│  │  ├── reports/
│  │  ├── docs/
│  │  ├── scratch/
│  │  ├── TEAM.md
│  │  ├── AGENTS.md
│  │  ├── USER.md
│  │  ├── TASKS.md
│  │  └── TOOLS.md
│  ├── syntella/                     # syntella main agent private workspace
│  │  ├── IDENTITY.md
│  │  ├── MEMORY.md
│  │  ├── HEARTBEAT.md
│  │  └── memory/
│  ├── templates/                     # main agent private workspace
│  │  ├── IDENTITY.md
│  │  ├── MEMORY.md
│  │  ├── HEARTBEAT.md
│  │  └── memory/
│  └── spawned_agent_name/                   # workspace for spawned agents, copies template files
│     ├── IDENTITY.md
│     ├── MEMORY.md
│     ├── HEARTBEAT.md
│     └── memory/
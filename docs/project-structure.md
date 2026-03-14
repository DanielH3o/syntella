~/.openclaw/
├── openclaw.json
├── credentials/                 # managed by OpenClaw
├── agents/                      # sessions/state managed by OpenClaw
├── workspace/
│  ├── admin/                    # Syntella-managed admin frontend, safe to overwrite on updates
│  │  ├── admin.html
│  │  ├── admin.css
│  │  ├── admin-core.js
│  │  └── ...
│  ├── project/                  # customer-owned website/assets/reports, preserved on updates
│  │  ├── index.html
│  │  └── ...
│  ├── shared/                   # collaborative area across agents
│  │  ├── reports/
│  │  ├── docs/
│  │  ├── scratch/
│  │  ├── TEAM.md
│  │  ├── USER.md
│  │  ├── TASKS.md
│  │  └── ...
│  ├── syntella/                     # syntella main agent private workspace
│  │  ├── AGENTS.md
│  │  ├── MEMORY.md
│  │  ├── HEARTBEAT.md
│  │  ├── SOUL.md
│  │  └── memory/
│  ├── templates/                # shared templates/extensions for future agents
│  │  └── extensions/
│  └── spawned_agent_name/       # workspace for a spawned native agent
│     ├── AGENTS.md
│     ├── SOUL.md
│     └── memory/

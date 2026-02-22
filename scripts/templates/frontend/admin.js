const agentsOut = document.getElementById('agentsOut');
const spawnOut = document.getElementById('spawnOut');
const refreshBtn = document.getElementById('refreshAgents');
const form = document.getElementById('spawnForm');

async function loadAgents() {
  agentsOut.textContent = 'Loading...';
  try {
    const res = await fetch('/api/agents');
    const data = await res.json();
    agentsOut.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    agentsOut.textContent = `Failed to load agents: ${err}`;
  }
}

refreshBtn?.addEventListener('click', loadAgents);

form?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(form);
  const payload = {
    agent_id: String(fd.get('agent_id') || '').trim(),
    role: String(fd.get('role') || '').trim(),
    description: String(fd.get('description') || '').trim(),
    discord_token: String(fd.get('discord_token') || '').trim(),
  };

  spawnOut.textContent = 'Spawning agent...';
  try {
    const res = await fetch('/api/spawn-agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    spawnOut.textContent = JSON.stringify(data, null, 2);
    if (res.ok) {
      form.reset();
      loadAgents();
    }
  } catch (err) {
    spawnOut.textContent = `Spawn failed: ${err}`;
  }
});

loadAgents();

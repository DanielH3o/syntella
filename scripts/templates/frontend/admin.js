const agentsOut = document.getElementById('agentsOut');
const spawnOut = document.getElementById('spawnOut');
const refreshBtn = document.getElementById('refreshAgents');
const form = document.getElementById('spawnForm');

async function readResponse(res) {
  const text = await res.text();
  try {
    return { ok: true, data: JSON.parse(text), raw: text };
  } catch {
    return { ok: false, raw: text };
  }
}

async function loadAgents() {
  agentsOut.textContent = 'Loading...';
  try {
    const res = await fetch('/api/agents');
    const parsed = await readResponse(res);
    if (!res.ok) {
      agentsOut.textContent = `Request failed (${res.status})\n${parsed.raw.slice(0, 2000)}`;
      return;
    }
    if (!parsed.ok) {
      agentsOut.textContent = `Non-JSON response (${res.status})\n${parsed.raw.slice(0, 2000)}`;
      return;
    }
    agentsOut.textContent = JSON.stringify(parsed.data, null, 2);
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
    const parsed = await readResponse(res);

    if (!res.ok) {
      spawnOut.textContent = `Spawn failed (${res.status})\n${parsed.raw.slice(0, 3000)}`;
      return;
    }

    if (!parsed.ok) {
      spawnOut.textContent = `Spawn failed: upstream returned non-JSON (${res.status})\n${parsed.raw.slice(0, 3000)}`;
      return;
    }

    spawnOut.textContent = JSON.stringify(parsed.data, null, 2);
    form.reset();
    loadAgents();
  } catch (err) {
    spawnOut.textContent = `Spawn failed: ${err}`;
  }
});

loadAgents();

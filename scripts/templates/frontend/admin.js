const agentsOut = document.getElementById('agentsOut');
const spawnOut = document.getElementById('spawnOut');
const refreshBtn = document.getElementById('refreshAgents');
const form = document.getElementById('spawnForm');
const submitBtn = form?.querySelector('button[type="submit"]');

// Spawn can take up to 4 minutes; allow 5 minutes total.
const SPAWN_TIMEOUT_MS = 300_000;
const POLL_INTERVAL_MS = 5_000;

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
    const res = await fetch('/api/agents', { signal: AbortSignal.timeout(10_000) });
    const parsed = await readResponse(res);
    if (!res.ok) {
      agentsOut.textContent = `Request failed (${res.status})\n${parsed.raw.slice(0, 2000)}`;
      return;
    }
    if (!parsed.ok) {
      agentsOut.textContent = `Non-JSON response (${res.status})\n${parsed.raw.slice(0, 2000)}`;
      return;
    }
    const agents = parsed.data.agents || {};
    const count = Object.keys(agents).length;
    if (count === 0) {
      agentsOut.textContent = 'No agents registered yet.';
    } else {
      agentsOut.textContent = JSON.stringify(agents, null, 2);
    }
  } catch (err) {
    if (err.name === 'TimeoutError') {
      agentsOut.textContent = 'Agent list request timed out. Is the operator bridge running?';
    } else {
      agentsOut.textContent = `Failed to load agents: ${err.message || err}`;
    }
  }
}

function setSpawnState(isSpawning) {
  if (submitBtn) {
    submitBtn.disabled = isSpawning;
    submitBtn.textContent = isSpawning ? 'Spawning...' : 'Add agent';
  }
  // Disable form inputs during spawn.
  form?.querySelectorAll('input, textarea').forEach(el => {
    el.disabled = isSpawning;
  });
}

function formatDuration(ms) {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  return `${Math.floor(s / 60)}m ${s % 60}s`;
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

  setSpawnState(true);
  const startTime = Date.now();

  // Progress indicator.
  const progressInterval = setInterval(() => {
    const elapsed = formatDuration(Date.now() - startTime);
    spawnOut.textContent = `Spawning agent "${payload.agent_id}"... (${elapsed})\nThis typically takes 30-120 seconds.`;
  }, 1000);
  spawnOut.textContent = `Spawning agent "${payload.agent_id}"...\nThis typically takes 30-120 seconds.`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), SPAWN_TIMEOUT_MS);

  try {
    const res = await fetch('/api/spawn-agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    clearInterval(progressInterval);
    const elapsed = formatDuration(Date.now() - startTime);
    const parsed = await readResponse(res);

    if (res.status === 409) {
      // Spawn busy — another spawn is already in progress.
      const detail = parsed.ok ? parsed.data.detail : 'Another spawn is in progress.';
      spawnOut.textContent = `Spawn busy: ${detail}\nPlease wait for the current spawn to finish and try again.`;
      return;
    }

    if (!res.ok) {
      let errorDetail = parsed.raw.slice(0, 3000);
      if (parsed.ok && parsed.data) {
        const d = parsed.data;
        errorDetail = [
          `Exit code: ${d.exit_code ?? 'unknown'}`,
          d.stderr ? `\nStderr:\n${d.stderr.slice(-2000)}` : '',
          d.stdout ? `\nStdout:\n${d.stdout.slice(-1000)}` : '',
        ].join('');
      }
      spawnOut.textContent = `Spawn failed after ${elapsed} (HTTP ${res.status})\n\n${errorDetail}`;
      return;
    }

    if (!parsed.ok) {
      spawnOut.textContent = `Spawn returned non-JSON after ${elapsed} (HTTP ${res.status})\n${parsed.raw.slice(0, 3000)}`;
      return;
    }

    const d = parsed.data;
    if (d.ok) {
      const meta = d.spawn || {};
      spawnOut.textContent = [
        `Agent "${meta.agent_id || payload.agent_id}" spawned successfully! (${elapsed})`,
        `  Port: ${meta.port || 'unknown'}`,
        `  PID: ${meta.pid || 'unknown'}`,
        `  Guild configured: ${meta.guild_configured ?? d.guild_configured ?? 'unknown'}`,
      ].join('\n');
      form.reset();
    } else {
      spawnOut.textContent = `Spawn reported failure after ${elapsed}:\n${JSON.stringify(d, null, 2)}`;
    }
    loadAgents();
  } catch (err) {
    clearInterval(progressInterval);
    const elapsed = formatDuration(Date.now() - startTime);
    if (err.name === 'AbortError') {
      spawnOut.textContent = `Spawn timed out after ${elapsed}.\nThe agent may still be starting in the background.\nCheck the server logs and try refreshing the agent list.`;
    } else {
      spawnOut.textContent = `Spawn failed after ${elapsed}: ${err.message || err}\n\nPossible causes:\n- Operator bridge is not running\n- Network connectivity issue\n- Server crashed during spawn\n\nTry refreshing the page and checking server logs.`;
    }
  } finally {
    clearTimeout(timeout);
    clearInterval(progressInterval);
    setSpawnState(false);
  }
});

// Poll for active spawn status (useful if page is reloaded during a spawn).
async function checkHealth() {
  try {
    const res = await fetch('/api/health', { signal: AbortSignal.timeout(5000) });
    if (res.ok) {
      const data = await res.json();
      if (data.active_spawn) {
        spawnOut.textContent = `A spawn is currently in progress for agent "${data.active_spawn}".\nPlease wait for it to finish before spawning another.`;
        setSpawnState(true);
        // Re-check in a few seconds.
        setTimeout(async () => {
          await checkHealth();
          if (!submitBtn?.disabled) {
            spawnOut.textContent = '';
            loadAgents();
          }
        }, POLL_INTERVAL_MS);
      }
    }
  } catch {
    // Health check failed — bridge might be down, loadAgents will show the error.
  }
}

loadAgents();
checkHealth();

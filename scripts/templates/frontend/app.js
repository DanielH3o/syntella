const out = document.getElementById('out');

function fmtUptime(s) {
  if (s == null) return 'unknown';
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return m > 0 ? `${h}h ${m}m` : `${h}h`;
}

async function loadDashboard() {
  try {
    const [hRes, aRes] = await Promise.all([
      fetch('/api/health', { signal: AbortSignal.timeout(5000) }),
      fetch('/api/agents', { signal: AbortSignal.timeout(5000) }),
    ]);
    const health = hRes.ok ? await hRes.json() : null;
    const agents = aRes.ok ? await aRes.json() : null;
    const count = agents ? Object.keys(agents.agents || {}).length : '?';
    const active = agents
      ? Object.values(agents.agents || {}).filter(a => a.pid).length
      : '?';

    const dot = health?.ok
      ? '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#22c55e;box-shadow:0 0 6px rgba(34,197,94,0.4);vertical-align:middle;margin-right:6px"></span>'
      : '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#ef4444;box-shadow:0 0 6px rgba(239,68,68,0.4);vertical-align:middle;margin-right:6px"></span>';

    out.innerHTML = `
      <div style="display:flex;gap:24px;flex-wrap:wrap;font-size:0.875rem">
        <div>${dot}<span style="color:#9fb0e8">Bridge:</span> <strong>${health?.ok ? 'Online' : 'Offline'}</strong></div>
        <div><span style="color:#9fb0e8">Uptime:</span> <strong style="font-family:'JetBrains Mono',monospace">${health ? fmtUptime(health.uptime_seconds) : '--'}</strong></div>
        <div><span style="color:#9fb0e8">Agents:</span> <strong>${count}</strong> total, <strong>${active}</strong> active</div>
      </div>`;
  } catch {
    out.innerHTML = '<span style="color:#9fb0e8">Could not reach operator bridge.</span>';
  }
}

loadDashboard();
setInterval(loadDashboard, 15000);

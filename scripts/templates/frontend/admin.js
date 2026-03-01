/* ── Syntella Admin Dashboard ──────────────────────────────────────── */

const SPAWN_TIMEOUT_MS = 300_000;
const HEALTH_POLL_MS = 10_000;
const AGENT_POLL_MS = 15_000;
const MAX_SPAWN_ESTIMATE_S = 180;

const $ = (s) => document.querySelector(s);
const dom = {
  bridgeDot:    $('#bridgeDot'),
  bridgeLabel:  $('#bridgeLabel'),
  uptimeLabel:  $('#uptimeLabel'),
  statTotal:    $('#statTotal'),
  statActive:   $('#statActive'),
  statUptime:   $('#statUptime'),
  agentGrid:    $('#agentGrid'),
  refreshBtn:   $('#refreshAgents'),
  form:         $('#spawnForm'),
  spawnBtn:     $('#spawnBtn'),
  spawnLabel:   $('#spawnBtnLabel'),
  progress:     $('#spawnProgress'),
  progressFill: $('#progressFill'),
  progressText: $('#progressText'),
  progressTime: $('#progressTime'),
  toasts:       $('#toastContainer'),
};

let isSpawning = false;
let bridgeOnline = false;

/* ── Utilities ────────────────────────────────────────────────────── */

function esc(str) {
  const d = document.createElement('div');
  d.textContent = String(str ?? '');
  return d.innerHTML;
}

function fmtUptime(s) {
  if (s == null) return '--';
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return m > 0 ? `${h}h ${m}m` : `${h}h`;
}

function fmtDuration(ms) {
  const s = Math.floor(ms / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}

/* ── Toasts ───────────────────────────────────────────────────────── */

function toast(type, title, detail, ms = 6000) {
  const el = document.createElement('div');
  el.className = `toast toast--${type}`;
  el.innerHTML = `
    <div style="flex:1;min-width:0">
      <strong style="display:block;margin-bottom:1px">${esc(title)}</strong>
      ${detail ? `<span style="opacity:0.8;font-size:0.75rem;word-break:break-word">${esc(detail)}</span>` : ''}
    </div>
    <button class="toast__close" aria-label="Close">&times;</button>
  `;
  dom.toasts.appendChild(el);
  el.querySelector('.toast__close').onclick = () => dismiss(el);
  setTimeout(() => dismiss(el), ms);
}

function dismiss(el) {
  if (!el.parentNode) return;
  el.classList.add('toast--exit');
  el.addEventListener('animationend', () => el.remove());
}

/* ── Health polling ───────────────────────────────────────────────── */

async function pollHealth() {
  try {
    const res = await fetch('/api/health', { signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error();
    const d = await res.json();

    bridgeOnline = true;
    dom.bridgeDot.className = 'status-dot status-dot--online';
    dom.bridgeLabel.textContent = 'Online';
    dom.uptimeLabel.textContent = fmtUptime(d.uptime_seconds);
    dom.statUptime.textContent = fmtUptime(d.uptime_seconds);

    if (d.active_spawn && !isSpawning) {
      dom.spawnLabel.textContent = `Spawn in progress: ${d.active_spawn}`;
      setSpawning(true);
      awaitActiveSpawn(d.active_spawn);
    }
  } catch {
    bridgeOnline = false;
    dom.bridgeDot.className = 'status-dot status-dot--offline';
    dom.bridgeLabel.textContent = 'Offline';
    dom.uptimeLabel.textContent = '';
    dom.statUptime.textContent = '--';
  }
}

/* ── Agents ───────────────────────────────────────────────────────── */

async function loadAgents() {
  try {
    const res = await fetch('/api/agents', { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) return;
    const data = await res.json();
    const agents = data.agents || {};
    renderAgents(agents);
    updateStats(agents);
  } catch { /* swallow — health polling shows offline state */ }
}

function updateStats(agents) {
  const entries = Object.entries(agents);
  dom.statTotal.textContent = entries.length;
  dom.statActive.textContent = entries.filter(([, a]) => a.pid).length;
}

function renderAgents(agents) {
  const entries = Object.entries(agents);

  if (entries.length === 0) {
    dom.agentGrid.innerHTML = `
      <div class="empty-state">
        <div class="empty-state__icon">
          <svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M8 12h.01"/><path d="M16 12h.01"/><path d="M9 16c.85.63 1.885 1 3 1s2.15-.37 3-1"/></svg>
        </div>
        <h3 class="empty-state__title">No agents yet</h3>
        <p class="empty-state__text">Spawn your first agent below to get started.</p>
      </div>`;
    return;
  }

  dom.agentGrid.innerHTML = entries.map(([id, a], i) => {
    const desc = a.personality || a.description || '';
    return `
    <div class="agent-card" style="animation-delay:${i * 70}ms">
      <div class="agent-card__header">
        <div>
          <h3 class="agent-card__name">${esc(id)}</h3>
          <p class="agent-card__role">${esc(a.role || 'Agent')}</p>
        </div>
        <span class="agent-card__status agent-card__status--online">
          <span class="status-dot status-dot--online" style="width:6px;height:6px"></span>
          Running
        </span>
      </div>
      <div class="agent-card__meta">
        <span class="badge">PORT ${a.port ?? '?'}</span>
        <span class="badge">PID ${a.pid ?? '?'}</span>
      </div>
      ${desc ? `<p class="agent-card__personality">${esc(desc)}</p>` : ''}
      <div class="agent-card__actions">
        <button class="btn btn-danger" onclick="confirmStop('${esc(id)}')">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>
          Stop
        </button>
      </div>
    </div>`;
  }).join('');
}

/* ── Stop agent ───────────────────────────────────────────────────── */

function confirmStop(agentId) {
  const overlay = document.createElement('div');
  overlay.className = 'confirm-overlay';
  overlay.innerHTML = `
    <div class="confirm-dialog">
      <h3 class="confirm-dialog__title">Stop Agent</h3>
      <p class="confirm-dialog__text">
        This will terminate the gateway for <strong>${esc(agentId)}</strong>.
        The agent will no longer respond on Discord until re-spawned.
      </p>
      <div class="confirm-dialog__actions">
        <button class="btn btn-ghost" id="dlg-cancel">Cancel</button>
        <button class="btn btn-danger" id="dlg-confirm">Stop Agent</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector('#dlg-cancel').onclick = close;
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.querySelector('#dlg-confirm').onclick = async () => {
    close();
    await stopAgent(agentId);
  };
}

async function stopAgent(agentId) {
  try {
    const res = await fetch('/api/stop-agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ agent_id: agentId }),
    });
    const d = await res.json();
    if (res.ok && d.ok) {
      toast('success', 'Agent stopped', `${agentId} gateway terminated.`);
    } else {
      toast('error', 'Stop failed', d.detail || `HTTP ${res.status}`);
    }
  } catch (err) {
    toast('error', 'Stop failed', err.message);
  }
  loadAgents();
}

/* ── Spawn ────────────────────────────────────────────────────────── */

function setSpawning(active) {
  isSpawning = active;
  dom.spawnBtn.disabled = active;

  if (active) {
    dom.spawnBtn.innerHTML = '<span class="spinner"></span> Spawning...';
    dom.progress.classList.add('active');
  } else {
    dom.spawnBtn.innerHTML = `
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M12 5v14"/><path d="M5 12h14"/></svg>
      Spawn Agent`;
    dom.progress.classList.remove('active');
    dom.progressFill.style.width = '0%';
    dom.spawnLabel.textContent = '';
  }

  dom.form.querySelectorAll('input, textarea').forEach((el) => {
    el.disabled = active;
  });
}

function tickProgress(startTime) {
  if (!isSpawning) return;
  const elapsed = (Date.now() - startTime) / 1000;
  const pct = Math.min((elapsed / MAX_SPAWN_ESTIMATE_S) * 100, 95);
  dom.progressFill.style.width = `${pct}%`;
  dom.progressTime.textContent = fmtDuration(Date.now() - startTime);
  dom.progressText.textContent =
    elapsed < 15 ? 'Allocating port and environment...' :
    elapsed < 45 ? 'Configuring Discord gateway...' :
    elapsed < 90 ? 'Starting agent gateway...' :
    'Finalizing setup...';
  requestAnimationFrame(() => setTimeout(() => tickProgress(startTime), 500));
}

dom.form?.addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(dom.form);
  const payload = {
    agent_id: String(fd.get('agent_id') || '').trim(),
    role: String(fd.get('role') || '').trim(),
    description: String(fd.get('description') || '').trim(),
    discord_token: String(fd.get('discord_token') || '').trim(),
  };

  setSpawning(true);
  const t0 = Date.now();
  tickProgress(t0);

  const ctrl = new AbortController();
  const timeout = setTimeout(() => ctrl.abort(), SPAWN_TIMEOUT_MS);

  try {
    const res = await fetch('/api/spawn-agent', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: ctrl.signal,
    });
    clearTimeout(timeout);
    const elapsed = fmtDuration(Date.now() - t0);

    if (res.status === 409) {
      const d = await res.json().catch(() => ({}));
      toast('info', 'Spawn busy', d.detail || 'Another spawn is in progress.');
      return;
    }

    let data;
    try { data = await res.json(); } catch { data = null; }

    if (!res.ok || !data) {
      const detail = data
        ? `Exit ${data.exit_code ?? '?'} after ${elapsed}${data.stderr ? '\n' + data.stderr.slice(-500) : ''}`
        : `HTTP ${res.status} after ${elapsed}`;
      toast('error', 'Spawn failed', detail, 10000);
      return;
    }

    if (data.ok) {
      const m = data.spawn || {};
      dom.progressFill.style.width = '100%';
      toast('success', `Agent "${m.agent_id || payload.agent_id}" spawned`,
        `Port ${m.port ?? '?'} | PID ${m.pid ?? '?'} | ${elapsed}`);
      dom.form.reset();
      loadAgents();
    } else {
      toast('error', 'Spawn failed', `Exit ${data.exit_code ?? '?'} after ${elapsed}`, 10000);
    }
  } catch (err) {
    clearTimeout(timeout);
    const elapsed = fmtDuration(Date.now() - t0);
    if (err.name === 'AbortError') {
      toast('error', 'Spawn timed out',
        `No response after ${elapsed}. The agent may still be starting.`, 10000);
    } else {
      toast('error', 'Connection failed',
        `${err.message || err} after ${elapsed}`, 10000);
    }
  } finally {
    clearTimeout(timeout);
    setSpawning(false);
  }
});

/* ── Active spawn watcher ─────────────────────────────────────────── */

async function awaitActiveSpawn(agentId) {
  const poll = async () => {
    try {
      const res = await fetch('/api/health', { signal: AbortSignal.timeout(5000) });
      if (res.ok) {
        const d = await res.json();
        if (d.active_spawn) {
          setTimeout(poll, 5000);
          return;
        }
      }
    } catch {
      setTimeout(poll, 5000);
      return;
    }
    setSpawning(false);
    toast('info', 'Spawn completed', `Agent "${agentId}" finished spawning.`);
    loadAgents();
  };
  poll();
}

/* ── Init ─────────────────────────────────────────────────────────── */

pollHealth();
loadAgents();

setInterval(pollHealth, HEALTH_POLL_MS);
setInterval(loadAgents, AGENT_POLL_MS);

dom.refreshBtn?.addEventListener('click', () => {
  loadAgents();
  pollHealth();
});

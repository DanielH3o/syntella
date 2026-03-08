(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, constants, utils, actions } = app;

    const renderBudgetBars = (container, rows, valueSelector, formatter) => {
      const max = Math.max(...rows.map((row) => valueSelector(row)), 0);
      if (!rows.length) {
        container.innerHTML = '<div class="task-empty">No demo data matches the current filter.</div>';
        return;
      }
      container.innerHTML = rows.map((row) => {
        const value = valueSelector(row);
        const width = max ? Math.max((value / max) * 100, 6) : 0;
        return `
          <div class="budget-bar">
            <div class="budget-bar__label">${utils.escapeHtml(row.label)}</div>
            <div class="budget-bar__track"><div class="budget-bar__fill" style="width:${width}%"></div></div>
            <div class="budget-bar__value">${utils.escapeHtml(formatter(value))}</div>
          </div>
        `;
      }).join('');
    };

    actions.renderBudget = async () => {
      const rangeDays = Number(refs.budgetRange.value || 30);
      const focusOnTokens = refs.budgetView.value === 'tokens';
      const activeAgent = refs.budgetAgentFilter.value || 'all';
      const activeModel = refs.budgetModelFilter.value || 'all';
      const referenceQuery = utils.buildQuery({ days: rangeDays });
      const summaryQuery = utils.buildQuery({ days: rangeDays, agent: activeAgent, model: activeModel });
      const eventsQuery = utils.buildQuery({ days: rangeDays, agent: activeAgent, model: activeModel, limit: 8 });
      try {
        const [referenceRes, summaryRes, eventsRes, tasksRes] = await Promise.all([
          fetch(`/api/usage/summary?${referenceQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch(`/api/usage/summary?${summaryQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch(`/api/usage?${eventsQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch('/api/costs/by-task?limit=8', { signal: AbortSignal.timeout(10000) }),
        ]);
        if (!referenceRes.ok || !summaryRes.ok || !eventsRes.ok || !tasksRes.ok) throw new Error('Could not load usage telemetry');
        const referencePayload = await referenceRes.json();
        const summaryPayload = await summaryRes.json();
        const eventsPayload = await eventsRes.json();
        const tasksPayload = await tasksRes.json();
        utils.fillSelectOptions(refs.budgetAgentFilter, (referencePayload.by_agent || []).map((row) => row.agent), 'All agents');
        utils.fillSelectOptions(refs.budgetModelFilter, (referencePayload.by_model || []).map((row) => row.model).filter(Boolean), 'All models');
        if (activeAgent !== refs.budgetAgentFilter.value || activeModel !== refs.budgetModelFilter.value) return actions.renderBudget();

        const totals = summaryPayload.totals || {};
        const byAgent = (summaryPayload.by_agent || []).map((row) => ({
          label: row.agent,
          cost: Number(row.total_cost || 0),
          tokens: Number(row.total_tokens || 0),
          count: Number(row.event_count || 0),
          budget: constants.monthBudgetByAgent[row.agent] || 60,
        }));
        const byModel = (summaryPayload.by_model || []).map((row) => ({
          label: row.model || 'unknown',
          provider: row.provider || '',
          cost: Number(row.total_cost || 0),
          tokens: Number(row.total_tokens || 0),
          count: Number(row.event_count || 0),
        }));
        const events = eventsPayload.events || [];
        const totalCost = Number(totals.total_cost || 0);
        const totalTokensRaw = Number(totals.total_tokens || 0);
        const totalInput = Number(totals.input_tokens || 0);
        const totalOutput = Number(totals.output_tokens || 0);
        const dailyBurn = rangeDays ? totalCost / rangeDays : 0;
        const projectedMonthly = dailyBurn * 30;
        const topAgent = byAgent[0];
        const combinedBudget = utils.sum(byAgent, (row) => row.budget);
        const budgetRatio = combinedBudget ? projectedMonthly / combinedBudget : 0;
        const state = utils.classifyBudgetState(budgetRatio);

        refs.budgetProjectedSpend.textContent = utils.formatCurrency(projectedMonthly);
        refs.budgetProjectedDetail.textContent = `${utils.formatCurrency(dailyBurn)} per day extrapolated across a 30 day month.`;
        refs.budgetActualSpend.textContent = utils.formatCurrency(totalCost);
        refs.budgetActualDetail.textContent = `${Number(totals.event_count || 0)} usage event${Number(totals.event_count || 0) === 1 ? '' : 's'} inside the selected range.`;
        refs.budgetTotalTokens.textContent = utils.numberFormat.format(totalTokensRaw);
        refs.budgetTokenDetail.textContent = `${utils.compactNumber.format(totalInput)} input and ${utils.compactNumber.format(totalOutput)} output tokens.`;
        refs.budgetTopAgent.textContent = topAgent ? topAgent.label : '-';
        refs.budgetTopAgentDetail.textContent = topAgent ? `${utils.formatCurrency(topAgent.cost)} across ${topAgent.count} model responses.` : 'No matching activity in this filter window.';
        refs.budgetHealthBadge.className = `budget-badge${state === 'warning' ? ' is-warning' : state === 'danger' ? ' is-danger' : ''}`;
        refs.budgetHealthBadge.textContent = state === 'danger' ? 'Over target' : state === 'warning' ? 'Watch spend' : 'Healthy';
        refs.budgetAllocationMeta.textContent = `${utils.formatCurrency(projectedMonthly)} projected this month against ${utils.formatCurrency(combinedBudget)} allocated caps.`;
        refs.budgetAllocationList.innerHTML = byAgent.length ? byAgent.map((row) => {
          const ratio = row.budget ? row.cost / row.budget : 0;
          const tone = utils.classifyBudgetState(ratio);
          return `
            <div class="budget-progress__row">
              <div class="budget-progress__top"><span class="budget-progress__name">${utils.escapeHtml(row.label)}</span><span>${utils.escapeHtml(utils.formatCurrency(row.cost))} / ${utils.escapeHtml(utils.formatCurrency(row.budget))}</span></div>
              <div class="budget-progress__track"><div class="budget-progress__fill${tone === 'warning' ? ' is-warning' : tone === 'danger' ? ' is-danger' : ''}" style="width:${Math.min(ratio * 100, 100)}%"></div></div>
            </div>`;
        }).join('') : '<div class="task-empty">No usage allocations found yet.</div>';

        const alerts = [];
        if (!events.length) alerts.push({ tone: '', title: 'No matching usage', copy: 'There are no synced OpenClaw usage events for the current filter set yet.' });
        if (topAgent && totalCost > 0 && topAgent.cost > totalCost * 0.55) alerts.push({ tone: 'warning', title: 'Spend concentration', copy: `${topAgent.label} is carrying ${Math.round((topAgent.cost / totalCost) * 100)}% of spend. Check whether that is intentional.` });
        if (byModel[0] && byModel[0].cost > totalCost * 0.6) alerts.push({ tone: 'warning', title: 'Model concentration', copy: `${byModel[0].label} is responsible for most cost in this slice.` });
        if (state === 'danger') alerts.push({ tone: 'danger', title: 'Projected overrun', copy: `Projected monthly burn is ${utils.formatCurrency(projectedMonthly)}, which exceeds the current budget envelope.` });
        else if (state === 'warning') alerts.push({ tone: 'warning', title: 'Approaching cap', copy: `Projected monthly burn is at ${Math.round(budgetRatio * 100)}% of configured budget caps.` });
        if (!alerts.length) alerts.push({ tone: '', title: 'Spend posture looks controlled', copy: 'No major outliers in the selected slice. This is a good base to build task-level attribution on top of.' });
        refs.budgetAlerts.innerHTML = alerts.map((alert) => `<article class="budget-alert${alert.tone ? ` is-${alert.tone}` : ''}"><h3 class="budget-alert__title">${utils.escapeHtml(alert.title)}</h3><p class="budget-alert__copy">${utils.escapeHtml(alert.copy)}</p></article>`).join('');

        renderBudgetBars(refs.budgetAgentBars, byAgent, (row) => focusOnTokens ? row.tokens : row.cost, (value) => focusOnTokens ? `${utils.compactNumber.format(value)} tok` : utils.formatCurrency(value));
        renderBudgetBars(refs.budgetModelBars, byModel, (row) => focusOnTokens ? row.tokens : row.cost, (value) => focusOnTokens ? `${utils.compactNumber.format(value)} tok` : utils.formatCurrency(value));
        refs.budgetEventsBody.innerHTML = events.length ? events.map((event) => `<tr><td>${utils.escapeHtml(new Date(event.ts).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }))}</td><td>${utils.escapeHtml(event.agent_id)}</td><td>${utils.escapeHtml(event.model || event.provider || 'unknown')}</td><td>${utils.escapeHtml(utils.numberFormat.format(event.total_tokens || 0))}</td><td>${utils.escapeHtml(utils.formatCurrency(event.total_cost || 0))}</td></tr>`).join('') : '<tr><td colspan="5" class="text-muted">No events in this slice.</td></tr>';
        const costTasks = tasksPayload.tasks || [];
        refs.budgetTaskCostsBody.innerHTML = costTasks.length ? costTasks.map((task) => `<tr><td>${utils.escapeHtml(task.title)}</td><td>${utils.escapeHtml(task.assignee || 'unassigned')}</td><td>${utils.escapeHtml(task.status || '-')}</td><td>${utils.escapeHtml(String(task.run_count || 0))}</td><td>${utils.escapeHtml(utils.formatCurrency(task.estimated_cost || 0))}</td></tr>`).join('') : '<tr><td colspan="5" class="text-muted">No task cost estimates yet.</td></tr>';
        refs.budgetPolicyNotes.innerHTML = constants.budgetPolicyTemplates.map((note) => `<article class="budget-alert${note.tone ? ` is-${note.tone}` : ''}"><h3 class="budget-alert__title">${utils.escapeHtml(note.title)}</h3><p class="budget-alert__copy">${utils.escapeHtml(note.copy)}</p></article>`).join('');
      } catch (error) {
        refs.budgetProjectedSpend.textContent = '$0.00';
        refs.budgetActualSpend.textContent = '$0.00';
        refs.budgetTotalTokens.textContent = '0';
        refs.budgetTopAgent.textContent = '-';
        refs.budgetProjectedDetail.textContent = error.message || 'Could not load usage telemetry.';
        refs.budgetActualDetail.textContent = 'Usage sync failed.';
        refs.budgetTokenDetail.textContent = 'No live usage data available.';
        refs.budgetTopAgentDetail.textContent = 'Budget page is waiting on synced usage events.';
        refs.budgetAllocationMeta.textContent = 'Unable to compute allocations.';
        refs.budgetAllocationList.innerHTML = '<div class="task-empty">Could not load usage telemetry.</div>';
        refs.budgetAlerts.innerHTML = `<article class="budget-alert is-danger"><h3 class="budget-alert__title">Usage sync failed</h3><p class="budget-alert__copy">${utils.escapeHtml(error.message || 'Could not load usage telemetry.')}</p></article>`;
        refs.budgetAgentBars.innerHTML = '<div class="task-empty">No live usage data available.</div>';
        refs.budgetModelBars.innerHTML = '<div class="task-empty">No live usage data available.</div>';
        refs.budgetTaskCostsBody.innerHTML = '<tr><td colspan="5" class="text-muted">Could not load task cost estimates.</td></tr>';
        refs.budgetEventsBody.innerHTML = '<tr><td colspan="5" class="text-muted">Could not load usage telemetry.</td></tr>';
        refs.budgetPolicyNotes.innerHTML = constants.budgetPolicyTemplates.map((note) => `<article class="budget-alert${note.tone ? ` is-${note.tone}` : ''}"><h3 class="budget-alert__title">${utils.escapeHtml(note.title)}</h3><p class="budget-alert__copy">${utils.escapeHtml(note.copy)}</p></article>`).join('');
      }
    };

    [refs.budgetRange, refs.budgetAgentFilter, refs.budgetModelFilter, refs.budgetView].forEach((element) => {
      element.addEventListener('change', actions.renderBudget);
    });
  });
})();

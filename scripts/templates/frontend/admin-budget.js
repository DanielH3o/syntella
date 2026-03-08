(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, constants, utils, actions } = app;

    const currentMonthWindow = () => {
      const now = new Date();
      const start = new Date(now.getFullYear(), now.getMonth(), 1);
      const end = new Date(now.getFullYear(), now.getMonth() + 1, 1);
      const elapsedMs = Math.max(now.getTime() - start.getTime(), 1);
      const totalMs = Math.max(end.getTime() - start.getTime(), 1);
      const elapsedDays = elapsedMs / 86_400_000;
      const daysInMonth = totalMs / 86_400_000;
      return {
        start,
        end,
        startIso: start.toISOString(),
        endIso: end.toISOString(),
        elapsedDays,
        daysInMonth,
        label: now.toLocaleString('en-GB', { month: 'long', year: 'numeric' }),
      };
    };

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
      const monthWindow = currentMonthWindow();
      const focusOnTokens = refs.budgetView.value === 'tokens';
      const activeAgent = refs.budgetAgentFilter.value || 'all';
      const activeModel = refs.budgetModelFilter.value || 'all';
      const referenceQuery = utils.buildQuery({ start: monthWindow.startIso, end: monthWindow.endIso });
      const summaryQuery = utils.buildQuery({ start: monthWindow.startIso, end: monthWindow.endIso, agent: activeAgent, model: activeModel });
      const eventsQuery = utils.buildQuery({ start: monthWindow.startIso, end: monthWindow.endIso, agent: activeAgent, model: activeModel, limit: 8 });
      try {
        const [referenceRes, summaryRes, eventsRes, tasksRes, agentsRes] = await Promise.all([
          fetch(`/api/usage/summary?${referenceQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch(`/api/usage/summary?${summaryQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch(`/api/usage?${eventsQuery}`, { signal: AbortSignal.timeout(10000) }),
          fetch('/api/costs/by-task?limit=8', { signal: AbortSignal.timeout(10000) }),
          fetch('/api/agents', { signal: AbortSignal.timeout(10000) }),
        ]);
        if (!referenceRes.ok || !summaryRes.ok || !eventsRes.ok || !tasksRes.ok || !agentsRes.ok) throw new Error('Could not load usage telemetry');
        const referencePayload = await referenceRes.json();
        const summaryPayload = await summaryRes.json();
        const eventsPayload = await eventsRes.json();
        const tasksPayload = await tasksRes.json();
        const agentsPayload = await agentsRes.json();
        const agentCatalog = agentsPayload.agents || {};
        utils.fillSelectOptions(refs.budgetAgentFilter, (referencePayload.by_agent || []).map((row) => row.agent), 'All agents');
        utils.fillSelectOptions(refs.budgetModelFilter, (referencePayload.by_model || []).map((row) => row.model).filter(Boolean), 'All models');
        if (activeAgent !== refs.budgetAgentFilter.value || activeModel !== refs.budgetModelFilter.value) return actions.renderBudget();

        const totals = summaryPayload.totals || {};
        const byAgent = (summaryPayload.by_agent || []).map((row) => ({
          label: row.agent,
          cost: Number(row.total_cost || 0),
          tokens: Number(row.total_tokens || 0),
          count: Number(row.event_count || 0),
          budget: agentCatalog[row.agent] && agentCatalog[row.agent].monthly_budget != null
            ? Number(agentCatalog[row.agent].monthly_budget)
            : null,
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
        const dailyBurn = monthWindow.elapsedDays ? totalCost / monthWindow.elapsedDays : 0;
        const projectedMonthly = dailyBurn * monthWindow.daysInMonth;
        const topAgent = byAgent[0];
        const configuredBudgets = byAgent.filter((row) => row.budget != null);
        const combinedBudget = utils.sum(configuredBudgets, (row) => row.budget);
        const budgetRatio = combinedBudget ? projectedMonthly / combinedBudget : 0;
        const state = utils.classifyBudgetState(budgetRatio);
        const actualRatio = combinedBudget ? totalCost / combinedBudget : 0;

        refs.budgetEnvelopeActual.textContent = utils.formatCurrency(totalCost);
        refs.budgetEnvelopeProjected.textContent = utils.formatCurrency(projectedMonthly);
        refs.budgetEnvelopeTotal.textContent = utils.formatCurrency(combinedBudget);
        refs.budgetEnvelopeCap.textContent = combinedBudget ? `Cap ${utils.formatCurrency(combinedBudget)}` : 'No caps';
        refs.budgetEnvelopeMeta.textContent = combinedBudget
          ? `${monthWindow.label}: ${utils.formatCurrency(totalCost)} month-to-date, with ${utils.formatCurrency(projectedMonthly)} projected by month end.`
          : `${monthWindow.label}: set monthly budgets on the Team page to turn this into a real cap-tracking view.`;
        refs.budgetEnvelopeProjectedBar.style.width = `${combinedBudget ? Math.min(projectedMonthly / combinedBudget, 1) * 100 : 0}%`;
        refs.budgetEnvelopeActualBar.style.width = `${combinedBudget ? Math.min(actualRatio, 1) * 100 : 0}%`;
        refs.budgetProjectedSpend.textContent = utils.formatCurrency(projectedMonthly);
        refs.budgetProjectedDetail.textContent = `${utils.formatCurrency(dailyBurn)} per day projected across ${Math.round(monthWindow.daysInMonth)} days in ${monthWindow.label}.`;
        refs.budgetActualSpend.textContent = utils.formatCurrency(totalCost);
        refs.budgetActualDetail.textContent = `${Number(totals.event_count || 0)} usage event${Number(totals.event_count || 0) === 1 ? '' : 's'} so far this month.`;
        refs.budgetTotalTokens.textContent = utils.numberFormat.format(totalTokensRaw);
        refs.budgetTokenDetail.textContent = `${utils.compactNumber.format(totalInput)} input and ${utils.compactNumber.format(totalOutput)} output tokens.`;
        refs.budgetTopAgent.textContent = topAgent ? topAgent.label : '-';
        refs.budgetTopAgentDetail.textContent = topAgent ? `${utils.formatCurrency(topAgent.cost)} across ${topAgent.count} model responses.` : 'No matching activity in this filter window.';
        refs.budgetHealthBadge.className = `budget-badge${combinedBudget ? (state === 'warning' ? ' is-warning' : state === 'danger' ? ' is-danger' : '') : ''}`;
        refs.budgetHealthBadge.textContent = !combinedBudget ? 'No caps set' : state === 'danger' ? 'Over target' : state === 'warning' ? 'Watch spend' : 'Healthy';
        refs.budgetAllocationMeta.textContent = combinedBudget
          ? `${monthWindow.label}: ${utils.formatCurrency(projectedMonthly)} projected against ${utils.formatCurrency(combinedBudget)} allocated caps.`
          : `${monthWindow.label}: no monthly agent budgets are configured yet. Set them from the Team page.`;
        refs.budgetAllocationList.innerHTML = byAgent.length ? byAgent.map((row) => {
          const ratio = row.budget ? row.cost / row.budget : 0;
          const tone = utils.classifyBudgetState(ratio);
          return `
            <div class="budget-progress__row">
              <div class="budget-progress__top"><span class="budget-progress__name">${utils.escapeHtml(row.label)}</span><span>${utils.escapeHtml(utils.formatCurrency(row.cost))} / ${utils.escapeHtml(row.budget == null ? 'Unset' : utils.formatCurrency(row.budget))}</span></div>
              <div class="budget-progress__track"><div class="budget-progress__fill${row.budget != null && tone === 'warning' ? ' is-warning' : row.budget != null && tone === 'danger' ? ' is-danger' : ''}" style="width:${row.budget == null ? 0 : Math.min(ratio * 100, 100)}%"></div></div>
            </div>`;
        }).join('') : '<div class="task-empty">No usage allocations found yet.</div>';

        const alerts = [];
        if (!events.length) alerts.push({ tone: '', title: 'No matching usage', copy: `There are no synced OpenClaw usage events yet for ${monthWindow.label}.` });
        if (topAgent && totalCost > 0 && topAgent.cost > totalCost * 0.55) alerts.push({ tone: 'warning', title: 'Spend concentration', copy: `${topAgent.label} is carrying ${Math.round((topAgent.cost / totalCost) * 100)}% of spend. Check whether that is intentional.` });
        if (byModel[0] && byModel[0].cost > totalCost * 0.6) alerts.push({ tone: 'warning', title: 'Model concentration', copy: `${byModel[0].label} is responsible for most cost in this slice.` });
        if (!combinedBudget) alerts.push({ tone: 'warning', title: 'No budget caps configured', copy: 'Set monthly agent budgets from the Team page so projected month-end overspend can be flagged properly.' });
        else if (state === 'danger') alerts.push({ tone: 'danger', title: 'Projected overrun', copy: `${monthWindow.label} is projecting to ${utils.formatCurrency(projectedMonthly)}, which exceeds the current budget envelope.` });
        else if (state === 'warning') alerts.push({ tone: 'warning', title: 'Approaching cap', copy: `${monthWindow.label} is trending toward ${Math.round(budgetRatio * 100)}% of configured budget caps.` });
        if (!alerts.length) alerts.push({ tone: '', title: 'Spend posture looks controlled', copy: 'No major outliers in the selected slice. This is a good base to build task-level attribution on top of.' });
        refs.budgetAlerts.innerHTML = alerts.map((alert) => `<article class="budget-alert${alert.tone ? ` is-${alert.tone}` : ''}"><h3 class="budget-alert__title">${utils.escapeHtml(alert.title)}</h3><p class="budget-alert__copy">${utils.escapeHtml(alert.copy)}</p></article>`).join('');

        renderBudgetBars(refs.budgetAgentBars, byAgent, (row) => focusOnTokens ? row.tokens : row.cost, (value) => focusOnTokens ? `${utils.compactNumber.format(value)} tok` : utils.formatCurrency(value));
        renderBudgetBars(refs.budgetModelBars, byModel, (row) => focusOnTokens ? row.tokens : row.cost, (value) => focusOnTokens ? `${utils.compactNumber.format(value)} tok` : utils.formatCurrency(value));
        refs.budgetEventsBody.innerHTML = events.length ? events.map((event) => `<tr><td>${utils.escapeHtml(new Date(event.ts).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }))}</td><td>${utils.escapeHtml(event.agent_id)}</td><td>${utils.escapeHtml(event.model || event.provider || 'unknown')}</td><td>${utils.escapeHtml(utils.numberFormat.format(event.total_tokens || 0))}</td><td>${utils.escapeHtml(utils.formatCurrency(event.total_cost || 0))}</td></tr>`).join('') : '<tr><td colspan="5" class="text-muted">No events in this slice.</td></tr>';
        const costTasks = tasksPayload.tasks || [];
        refs.budgetTaskCostsBody.innerHTML = costTasks.length ? costTasks.map((task) => `<tr><td>${utils.escapeHtml(task.title)}</td><td>${utils.escapeHtml(task.assignee || 'unassigned')}</td><td>${utils.escapeHtml(task.status || '-')}</td><td>${utils.escapeHtml(String(task.run_count || 0))}</td><td>${utils.escapeHtml(utils.formatCurrency(task.estimated_cost || 0))}</td></tr>`).join('') : '<tr><td colspan="5" class="text-muted">No task cost estimates yet.</td></tr>';
        refs.budgetPolicyNotes.innerHTML = constants.budgetPolicyTemplates.map((note) => `<article class="budget-alert${note.tone ? ` is-${note.tone}` : ''}"><h3 class="budget-alert__title">${utils.escapeHtml(note.title)}</h3><p class="budget-alert__copy">${utils.escapeHtml(note.copy)}</p></article>`).join('');
      } catch (error) {
        refs.budgetEnvelopeActual.textContent = '$0.00';
        refs.budgetEnvelopeProjected.textContent = '$0.00';
        refs.budgetEnvelopeTotal.textContent = '$0.00';
        refs.budgetEnvelopeCap.textContent = 'No caps';
        refs.budgetEnvelopeMeta.textContent = 'Unable to compute total budget envelope.';
        refs.budgetEnvelopeProjectedBar.style.width = '0%';
        refs.budgetEnvelopeActualBar.style.width = '0%';
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

    [refs.budgetAgentFilter, refs.budgetModelFilter, refs.budgetView].forEach((element) => {
      element.addEventListener('change', actions.renderBudget);
    });
  });
})();

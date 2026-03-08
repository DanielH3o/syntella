(function () {
  const featureRegistry = [];
  window.SyntellaAdminRegister = (feature) => {
    featureRegistry.push(feature);
  };

  document.querySelectorAll('.nav-item').forEach((item) => {
    item.addEventListener('click', function () {
      document.querySelectorAll('.nav-item').forEach((nav) => nav.classList.remove('active'));
      this.classList.add('active');
    });
  });

  window.addEventListener('DOMContentLoaded', () => {
    const hash = window.location.hash || '#tasks';
    const activeNav = document.querySelector(`.nav-item[href="${hash}"]`);
    if (activeNav) activeNav.classList.add('active');
    if (!window.location.hash) {
      window.location.hash = '#tasks';
    }

    const refs = {
      panelName: document.getElementById('org-panel-name'),
      panelRole: document.getElementById('org-panel-role'),
      panelDesc: document.getElementById('org-panel-desc'),
      panelStatus: document.getElementById('org-panel-status'),
      panelFocus: document.getElementById('org-panel-focus'),
      panelResponsibilities: document.getElementById('org-panel-responsibilities'),
      teamChartShell: document.getElementById('team-chart-shell'),
      teamChartPanelBackdrop: document.getElementById('team-chart-panel-backdrop'),
      teamChartPanelClose: document.getElementById('team-chart-panel-close'),
      teamNewAgentButton: document.getElementById('team-new-agent-button'),
      agentDrawerBackdrop: document.getElementById('agent-drawer-backdrop'),
      agentDrawerClose: document.getElementById('agent-drawer-close'),
      agentForm: document.getElementById('agent-form'),
      agentFeedback: document.getElementById('agent-feedback'),
      agentCancelButton: document.getElementById('agent-cancel-button'),
      agentNameInput: document.getElementById('agent-name-input'),
      agentRoleInput: document.getElementById('agent-role-input'),
      agentDescriptionInput: document.getElementById('agent-description-input'),
      agentModelSelect: document.getElementById('agent-model-select'),
      agentPortInput: document.getElementById('agent-port-input'),
      agentDiscordTokenInput: document.getElementById('agent-discord-token-input'),
      agentChannelIdInput: document.getElementById('agent-channel-id-input'),
      orgRootNode: document.getElementById('team-chart-root-node'),
      orgBranches: document.getElementById('team-chart-members'),
      taskForm: document.getElementById('task-form'),
      taskNewButton: document.getElementById('task-new-button'),
      taskCancelButton: document.getElementById('task-cancel-button'),
      taskTitleInput: document.getElementById('task-title-input'),
      taskDescriptionInput: document.getElementById('task-description-input'),
      taskAssigneeSelect: document.getElementById('task-assignee-select'),
      taskPrioritySelect: document.getElementById('task-priority-select'),
      taskFeedback: document.getElementById('task-feedback'),
      kanbanColumns: Array.from(document.querySelectorAll('.kanban-column')),
      taskDetailTitle: document.getElementById('task-detail-title'),
      taskDetailDescription: document.getElementById('task-detail-description'),
      taskDetailCost: document.getElementById('task-detail-cost'),
      taskDetailTokens: document.getElementById('task-detail-tokens'),
      taskDetailAssignee: document.getElementById('task-detail-assignee'),
      taskDetailStatus: document.getElementById('task-detail-status'),
      taskDetailLatestRun: document.getElementById('task-detail-latest-run'),
      taskDetailRuns: document.getElementById('task-detail-runs'),
      routinesCount: document.getElementById('routines-count'),
      routinesCountDetail: document.getElementById('routines-count-detail'),
      routinesEnabledCount: document.getElementById('routines-enabled-count'),
      routinesEnabledDetail: document.getElementById('routines-enabled-detail'),
      routinesReportCount: document.getElementById('routines-report-count'),
      routinesReportDetail: document.getElementById('routines-report-detail'),
      routinesLastRun: document.getElementById('routines-last-run'),
      routinesLastRunDetail: document.getElementById('routines-last-run-detail'),
      routinesTableBody: document.getElementById('routines-table-body'),
      routinesShell: document.getElementById('routines-shell'),
      routinesNewButton: document.getElementById('routines-new-button'),
      routinesDrawerBackdrop: document.getElementById('routines-drawer-backdrop'),
      routinesDrawerClose: document.getElementById('routines-drawer-close'),
      routineForm: document.getElementById('routine-form'),
      routineNameInput: document.getElementById('routine-name-input'),
      routineAgentSelect: document.getElementById('routine-agent-select'),
      routineScheduleType: document.getElementById('routine-schedule-type'),
      routineScheduleHelper: document.getElementById('routine-schedule-helper'),
      routineScheduleDailySection: document.getElementById('routine-schedule-daily-section'),
      routineScheduleWeeklySection: document.getElementById('routine-schedule-weekly-section'),
      routineScheduleHourlySection: document.getElementById('routine-schedule-hourly-section'),
      routineScheduleDateSection: document.getElementById('routine-schedule-date-section'),
      routineScheduleCustomSection: document.getElementById('routine-schedule-custom-section'),
      routineScheduleTime: document.getElementById('routine-schedule-time'),
      routineScheduleDay: document.getElementById('routine-schedule-day'),
      routineScheduleWeeklyTime: document.getElementById('routine-schedule-weekly-time'),
      routineScheduleHours: document.getElementById('routine-schedule-hours'),
      routineScheduleDate: document.getElementById('routine-schedule-date'),
      routineScheduleDateTime: document.getElementById('routine-schedule-date-time'),
      routineCustomCron: document.getElementById('routine-custom-cron'),
      routineSchedulePreview: document.getElementById('routine-schedule-preview'),
      routineOutputMode: document.getElementById('routine-output-mode'),
      routineReportChannelInput: document.getElementById('routine-report-channel-input'),
      routinePromptInput: document.getElementById('routine-prompt-input'),
      routineEnabledInput: document.getElementById('routine-enabled-input'),
      routineFeedback: document.getElementById('routine-feedback'),
      routineRunButton: document.getElementById('routine-run-button'),
      routineResetButton: document.getElementById('routine-reset-button'),
      routineDetailTitle: document.getElementById('routine-detail-title'),
      routineDetailDescription: document.getElementById('routine-detail-description'),
      routineRunsList: document.getElementById('routine-runs-list'),
      routineReportsList: document.getElementById('routine-reports-list'),
      reportsCount: document.getElementById('reports-count'),
      reportsCountDetail: document.getElementById('reports-count-detail'),
      reportsTodayCount: document.getElementById('reports-today-count'),
      reportsTodayDetail: document.getElementById('reports-today-detail'),
      reportsLatestRoutine: document.getElementById('reports-latest-routine'),
      reportsLatestRoutineDetail: document.getElementById('reports-latest-routine-detail'),
      reportsLatestAgent: document.getElementById('reports-latest-agent'),
      reportsLatestAgentDetail: document.getElementById('reports-latest-agent-detail'),
      reportsTableBody: document.getElementById('reports-table-body'),
      reportDetailTitle: document.getElementById('report-detail-title'),
      reportDetailSummary: document.getElementById('report-detail-summary'),
      reportDetailAgent: document.getElementById('report-detail-agent'),
      reportDetailRoutine: document.getElementById('report-detail-routine'),
      reportDetailStatus: document.getElementById('report-detail-status'),
      reportDetailCreated: document.getElementById('report-detail-created'),
      reportDetailBody: document.getElementById('report-detail-body'),
      budgetRange: document.getElementById('budget-range'),
      budgetAgentFilter: document.getElementById('budget-agent-filter'),
      budgetModelFilter: document.getElementById('budget-model-filter'),
      budgetView: document.getElementById('budget-view'),
      budgetProjectedSpend: document.getElementById('budget-projected-spend'),
      budgetProjectedDetail: document.getElementById('budget-projected-detail'),
      budgetActualSpend: document.getElementById('budget-actual-spend'),
      budgetActualDetail: document.getElementById('budget-actual-detail'),
      budgetTotalTokens: document.getElementById('budget-total-tokens'),
      budgetTokenDetail: document.getElementById('budget-token-detail'),
      budgetTopAgent: document.getElementById('budget-top-agent'),
      budgetTopAgentDetail: document.getElementById('budget-top-agent-detail'),
      budgetHealthBadge: document.getElementById('budget-health-badge'),
      budgetAllocationList: document.getElementById('budget-allocation-list'),
      budgetAllocationMeta: document.getElementById('budget-allocation-meta'),
      budgetAlerts: document.getElementById('budget-alerts'),
      budgetAgentBars: document.getElementById('budget-agent-bars'),
      budgetModelBars: document.getElementById('budget-model-bars'),
      budgetTaskCostsBody: document.getElementById('budget-task-costs-body'),
      budgetEventsBody: document.getElementById('budget-events-body'),
      budgetPolicyNotes: document.getElementById('budget-policy-notes'),
      modelsCount: document.getElementById('models-count'),
      modelsCountDetail: document.getElementById('models-count-detail'),
      modelsEnabledCount: document.getElementById('models-enabled-count'),
      modelsEnabledDetail: document.getElementById('models-enabled-detail'),
      modelsMissingPricing: document.getElementById('models-missing-pricing'),
      modelsMissingPricingDetail: document.getElementById('models-missing-pricing-detail'),
      modelsObservedCount: document.getElementById('models-observed-count'),
      modelsObservedDetail: document.getElementById('models-observed-detail'),
      modelsSearch: document.getElementById('models-search'),
      modelsProviderFilter: document.getElementById('models-provider-filter'),
      modelsStatusFilter: document.getElementById('models-status-filter'),
      modelsTableBody: document.getElementById('models-table-body'),
      modelsDrawerBackdrop: document.getElementById('models-drawer-backdrop'),
      modelsDrawerClose: document.getElementById('models-drawer-close'),
      modelsEditorTitle: document.getElementById('models-editor-title'),
      modelsEditorMeta: document.getElementById('models-editor-meta'),
      modelsForm: document.getElementById('models-form'),
      modelsFeedback: document.getElementById('models-feedback'),
      modelsNewButton: document.getElementById('models-new-button'),
      modelsResetButton: document.getElementById('models-reset-button'),
      modelsCancelButton: document.getElementById('models-cancel-button'),
      modelProviderBaseUrlInput: document.getElementById('model-provider-base-url-input'),
      modelProviderApiAdapterInput: document.getElementById('model-provider-api-adapter-input'),
      modelProviderApiKeyInput: document.getElementById('model-provider-api-key-input'),
      modelProviderApiKeyHelp: document.getElementById('model-provider-api-key-help'),
      modelProviderInput: document.getElementById('model-provider-input'),
      modelIdInput: document.getElementById('model-id-input'),
      modelDisplayNameInput: document.getElementById('model-display-name-input'),
      modelEnabledInput: document.getElementById('model-enabled-input'),
      modelReasoningInput: document.getElementById('model-reasoning-input'),
      modelModalitiesInput: document.getElementById('model-modalities-input'),
      modelContextWindowInput: document.getElementById('model-context-window-input'),
      modelMaxTokensInput: document.getElementById('model-max-tokens-input'),
      modelCostInputInput: document.getElementById('model-cost-input-input'),
      modelCostOutputInput: document.getElementById('model-cost-output-input'),
      modelCostCacheReadInput: document.getElementById('model-cost-cache-read-input'),
      modelCostCacheWriteInput: document.getElementById('model-cost-cache-write-input'),
      modelNotesInput: document.getElementById('model-notes-input'),
    };

    const state = {
      selectedTaskId: null,
      selectedRoutineId: null,
      selectedReportId: null,
      routinesCatalog: [],
      reportsCatalog: [],
      modelsCatalog: [],
      selectedModelKey: null,
    };

    const constants = {
      statusOrder: ['backlog', 'todo', 'in_progress', 'review', 'done'],
      priorityClass: { low: 'priority-low', medium: 'priority-medium', high: 'priority-high' },
      monthBudgetByAgent: { syntella: 180, dev: 240, seo: 90, support: 70 },
      budgetPolicyTemplates: [
        { title: 'Default cheaper models for routine work', copy: 'Most operational flows should stay on smaller models unless the task explicitly needs a premium one.', tone: '' },
        { title: 'Escalate only for synthesis-heavy tasks', copy: 'Planning, architecture, and multi-file reasoning can justify higher spend when they reduce retries and execution churn.', tone: 'warning' },
        { title: 'Track cost per shipped outcome', copy: 'Next step is attaching task and run identifiers to these usage events so the budget page can show spend per delivered task.', tone: '' },
      ],
    };

    const utils = {
      orgNodes: () => Array.from(document.querySelectorAll('.org-node')),
      escapeHtml: (value) => String(value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;'),
      currency: new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'USD' }),
      numberFormat: new Intl.NumberFormat('en-GB'),
      compactNumber: new Intl.NumberFormat('en-GB', { notation: 'compact', maximumFractionDigits: 1 }),
      modelKey: (provider, modelId) => `${provider}::${modelId}`,
      formatCurrency(value) { return this.currency.format(value || 0); },
      parseFormNumber(value) {
        if (value === '' || value === null || value === undefined) return null;
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : null;
      },
      formatDateTime(value) {
        return value
          ? new Date(value).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' })
          : '-';
      },
      sum(items, selector) { return items.reduce((total, item) => total + selector(item), 0); },
      fillSelectOptions(select, values, fallbackLabel) {
        const selected = select.value;
        select.innerHTML = [`<option value="all">${this.escapeHtml(fallbackLabel)}</option>`]
          .concat(values.sort().map((value) => `<option value="${this.escapeHtml(value)}">${this.escapeHtml(value)}</option>`))
          .join('');
        select.value = values.includes(selected) ? selected : 'all';
      },
      compileRoutineSchedule({
        scheduleType,
        scheduleTime,
        scheduleDay,
        scheduleHours,
        scheduleDate,
        customCron,
        timezone,
      }) {
        const time = (scheduleTime || '09:00').trim();
        const [hourRaw = '9', minuteRaw = '0'] = time.split(':');
        const hour = Number(hourRaw);
        const minute = Number(minuteRaw);
        const tz = (timezone || Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC').trim() || 'UTC';
        if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(minute) || minute < 0 || minute > 59) {
          throw new Error('Enter a valid time.');
        }
        if (scheduleType === 'daily') {
          return {
            cron_expression: `${minute} ${hour} * * *`,
            schedule_value: time,
            schedule_summary: `Runs daily at ${time} ${tz}`,
          };
        }
        if (scheduleType === 'weekdays') {
          return {
            cron_expression: `${minute} ${hour} * * 1-5`,
            schedule_value: time,
            schedule_summary: `Runs weekdays at ${time} ${tz}`,
          };
        }
        if (scheduleType === 'weekly') {
          const dayMap = {
            '0': 'Sunday',
            '1': 'Monday',
            '2': 'Tuesday',
            '3': 'Wednesday',
            '4': 'Thursday',
            '5': 'Friday',
            '6': 'Saturday',
          };
          const day = String(scheduleDay || '1');
          return {
            cron_expression: `${minute} ${hour} * * ${day}`,
            schedule_value: `${day}@${time}`,
            schedule_summary: `Runs every ${dayMap[day] || 'Monday'} at ${time} ${tz}`,
          };
        }
        if (scheduleType === 'hourly') {
          const interval = Number(scheduleHours || 4);
          if (!Number.isInteger(interval) || interval < 1 || interval > 24) {
            throw new Error('Hourly routines must run every 1 to 24 hours.');
          }
          return {
            cron_expression: `0 */${interval} * * *`,
            schedule_value: String(interval),
            schedule_summary: `Runs every ${interval} hour${interval === 1 ? '' : 's'}`,
          };
        }
        if (scheduleType === 'date') {
          const date = (scheduleDate || '').trim();
          if (!date) {
            throw new Error('Select a run date.');
          }
          const localDate = new Date(`${date}T${time}`);
          if (Number.isNaN(localDate.getTime())) {
            throw new Error('Enter a valid run date and time.');
          }
          return {
            cron_expression: localDate.toISOString(),
            schedule_value: `${date}@${time}`,
            schedule_summary: `Runs once on ${date} at ${time} ${tz}`,
          };
        }
        const cron = (customCron || '').trim();
        if (!cron) {
          throw new Error('Enter a cron expression for custom schedules.');
        }
        return {
          cron_expression: cron,
          schedule_value: cron,
          schedule_summary: `Custom cron (${cron}) in ${tz}`,
        };
      },
      classifyBudgetState(ratio) {
        if (ratio >= 1) return 'danger';
        if (ratio >= 0.8) return 'warning';
        return 'healthy';
      },
      buildQuery(params) {
        return new URLSearchParams(
          Object.entries(params).filter(([, value]) => value !== undefined && value !== null && value !== '')
        ).toString();
      },
    };

    const ui = {
      setTeamPanelOpen(isOpen) { refs.teamChartShell.classList.toggle('is-panel-open', Boolean(isOpen)); },
      setAgentDrawerOpen(isOpen) { refs.teamChartShell.classList.toggle('is-agent-drawer-open', Boolean(isOpen)); },
      setModelsDrawerOpen(isOpen) {
        const shell = document.querySelector('.models-shell');
        if (shell) shell.classList.toggle('is-drawer-open', Boolean(isOpen));
      },
      setRoutinesDrawerOpen(isOpen) {
        if (refs.routinesShell) refs.routinesShell.classList.toggle('is-drawer-open', Boolean(isOpen));
      },
      setAgentFeedback(message, tone = '') {
        refs.agentFeedback.textContent = message;
        refs.agentFeedback.className = `agent-feedback${tone ? ` is-${tone}` : ''}`;
      },
      resetAgentForm() { refs.agentForm.reset(); this.setAgentFeedback(''); },
      setTaskFeedback(message, tone = '') {
        refs.taskFeedback.textContent = message;
        refs.taskFeedback.className = `task-feedback${tone ? ` is-${tone}` : ''}`;
      },
      setRoutineFeedback(message, tone = '') {
        refs.routineFeedback.textContent = message;
        refs.routineFeedback.className = `models-feedback${tone ? ` is-${tone}` : ''}`;
      },
      setModelsFeedback(message, tone = '') {
        refs.modelsFeedback.textContent = message;
        refs.modelsFeedback.className = `models-feedback${tone ? ` is-${tone}` : ''}`;
      },
      toggleTaskForm(visible) {
        refs.taskForm.classList.toggle('is-hidden', !visible);
        refs.taskNewButton.textContent = visible ? 'Hide Form' : 'New Task';
        if (visible) refs.taskTitleInput.focus();
      },
      formatRunStatus(run) {
        if (!run) return 'No run';
        return run.ended_at ? run.status : 'active';
      },
      populateAssignees(agents) {
        const current = refs.taskAssigneeSelect.value;
        const currentRoutine = refs.routineAgentSelect.value;
        const ids = Object.keys(agents || {});
        const names = ids.length ? ids : ['syntella'];
        refs.taskAssigneeSelect.innerHTML = ['<option value="">unassigned</option>']
          .concat(names.sort().map((agentId) => `<option value="${utils.escapeHtml(agentId)}">${utils.escapeHtml(agentId)}</option>`))
          .join('');
        if (names.includes(current)) refs.taskAssigneeSelect.value = current;
        refs.routineAgentSelect.innerHTML = ['<option value="">Select an agent</option>']
          .concat(names.sort().map((agentId) => `<option value="${utils.escapeHtml(agentId)}">${utils.escapeHtml(agentId)}</option>`))
          .join('');
        if (names.includes(currentRoutine)) refs.routineAgentSelect.value = currentRoutine;
        utils.fillSelectOptions(refs.budgetAgentFilter, names, 'All agents');
      },
    };

    const app = { refs, state, constants, utils, ui, actions: {} };
    window.SyntellaAdminApp = app;

    featureRegistry.forEach((feature) => feature(app));
    app.actions.init = async () => {
      const tasksPromise = typeof app.actions.loadTasks === 'function' ? app.actions.loadTasks() : Promise.resolve();
      const routinesPromise = typeof app.actions.loadRoutines === 'function' ? app.actions.loadRoutines() : Promise.resolve();
      const reportsPromise = typeof app.actions.loadReports === 'function' ? app.actions.loadReports() : Promise.resolve();
      const modelsPromise = typeof app.actions.loadModels === 'function' ? app.actions.loadModels() : Promise.resolve();
      const budgetPromise = typeof app.actions.renderBudget === 'function' ? app.actions.renderBudget() : Promise.resolve();
      const teamPromise = typeof app.actions.loadDepartments === 'function' ? app.actions.loadDepartments() : Promise.resolve();
      await Promise.all([
        tasksPromise,
        routinesPromise,
        reportsPromise,
        modelsPromise,
        budgetPromise,
        teamPromise,
      ]);
    };
    if (typeof app.actions.init === 'function') {
      app.actions.init();
    }
  });
})();

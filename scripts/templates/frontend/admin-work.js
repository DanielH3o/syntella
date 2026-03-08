(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, state, constants, utils, ui, actions } = app;

    const syncRoutineScheduleFields = () => {
      const type = refs.routineScheduleType.value || 'daily';
      const showDaily = ['daily', 'weekdays'].includes(type);
      const showWeekly = type === 'weekly';
      const showHourly = type === 'hourly';
      const showDate = type === 'date';
      const showCustom = type === 'custom';
      refs.routineScheduleDailySection.hidden = !showDaily;
      refs.routineScheduleWeeklySection.hidden = !showWeekly;
      refs.routineScheduleHourlySection.hidden = !showHourly;
      refs.routineScheduleDateSection.hidden = !showDate;
      refs.routineScheduleCustomSection.hidden = !showCustom;
      refs.routineScheduleDailySection.style.display = showDaily ? 'grid' : 'none';
      refs.routineScheduleWeeklySection.style.display = showWeekly ? 'grid' : 'none';
      refs.routineScheduleHourlySection.style.display = showHourly ? 'grid' : 'none';
      refs.routineScheduleDateSection.style.display = showDate ? 'grid' : 'none';
      refs.routineScheduleCustomSection.style.display = showCustom ? 'grid' : 'none';
      refs.routineScheduleHelper.textContent = {
        daily: 'Runs every day at a specific local time.',
        weekdays: 'Runs Monday to Friday at a specific local time.',
        weekly: 'Runs once a week on the selected day and time.',
        hourly: 'Runs repeatedly at a fixed hour interval.',
        date: 'Runs once on the selected date and time.',
        custom: 'Advanced mode for full cron expressions.',
      }[type] || 'Configure when this routine should run.';
    };

    const updateRoutineSchedulePreview = () => {
      syncRoutineScheduleFields();
      try {
        const type = refs.routineScheduleType.value;
        const scheduleTime = type === 'weekly'
          ? refs.routineScheduleWeeklyTime.value
          : type === 'date'
            ? refs.routineScheduleDateTime.value
          : refs.routineScheduleTime.value;
        const compiled = utils.compileRoutineSchedule({
          scheduleType: type,
          scheduleTime,
          scheduleDay: refs.routineScheduleDay.value,
          scheduleHours: refs.routineScheduleHours.value,
          scheduleDate: refs.routineScheduleDate.value,
          customCron: refs.routineCustomCron.value,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        });
        refs.routineSchedulePreview.value = `${compiled.schedule_summary} • ${compiled.cron_expression}`;
      } catch (error) {
        refs.routineSchedulePreview.value = error.message || 'Invalid schedule';
      }
    };

    const renderTaskDetail = (task) => {
      if (!task) {
        refs.taskDetailTitle.textContent = 'Select a task';
        refs.taskDetailDescription.textContent = 'Choose a task card to inspect its estimated cost and run history.';
        refs.taskDetailCost.textContent = '$0.00';
        refs.taskDetailTokens.textContent = '0';
        refs.taskDetailAssignee.textContent = '-';
        refs.taskDetailStatus.textContent = '-';
        refs.taskDetailLatestRun.innerHTML = '<li><span>No run selected yet.</span></li>';
        refs.taskDetailRuns.innerHTML = '<li><span>No runs recorded yet.</span></li>';
        return;
      }
      refs.taskDetailTitle.textContent = task.title || 'Untitled task';
      refs.taskDetailDescription.textContent = task.description || 'No description yet.';
      refs.taskDetailCost.textContent = utils.formatCurrency(task.estimated_cost || 0);
      refs.taskDetailTokens.textContent = utils.numberFormat.format(task.estimated_tokens || 0);
      refs.taskDetailAssignee.textContent = task.assignee || 'unassigned';
      refs.taskDetailStatus.textContent = task.status || 'backlog';
      const latestRun = task.latest_run;
      refs.taskDetailLatestRun.innerHTML = latestRun ? `
        <li>
          <strong>${utils.escapeHtml(latestRun.agent_id)} • ${utils.escapeHtml(ui.formatRunStatus(latestRun))}</strong>
          <span>${utils.escapeHtml(utils.formatCurrency(latestRun.estimated_cost || 0))} • ${utils.escapeHtml(utils.numberFormat.format(latestRun.estimated_tokens || 0))} tokens</span>
          <span>Started ${utils.escapeHtml(utils.formatDateTime(latestRun.started_at))}</span>
          <span>${latestRun.ended_at ? `Ended ${utils.escapeHtml(utils.formatDateTime(latestRun.ended_at))}` : 'Still open'}</span>
        </li>
      ` : '<li><span>No run recorded yet.</span></li>';
      refs.taskDetailRuns.innerHTML = (task.runs || []).length ? task.runs.map((run) => `
        <li>
          <strong>${utils.escapeHtml(run.agent_id)} • ${utils.escapeHtml(ui.formatRunStatus(run))}</strong>
          <span>${utils.escapeHtml(utils.formatCurrency(run.estimated_cost || 0))} • ${utils.escapeHtml(utils.numberFormat.format(run.estimated_tokens || 0))} tokens</span>
          <span>Window: ${utils.escapeHtml(utils.formatDateTime(run.started_at))} to ${utils.escapeHtml(run.ended_at ? utils.formatDateTime(run.ended_at) : 'present')}</span>
        </li>
      `).join('') : '<li><span>No runs recorded yet.</span></li>';
    };

    const selectTaskCard = (taskId) => {
      state.selectedTaskId = taskId;
      document.querySelectorAll('.task-card').forEach((card) => {
        card.classList.toggle('is-selected', Number(card.dataset.taskId) === Number(taskId));
      });
    };

    const loadTaskDetail = async (taskId) => {
      try {
        const response = await fetch(`/api/tasks/${taskId}`, { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error('Could not load task detail');
        const payload = await response.json();
        selectTaskCard(taskId);
        renderTaskDetail(payload.task);
      } catch (error) {
        ui.setTaskFeedback(error.message || 'Could not load task detail', 'error');
      }
    };

    const createTaskCard = (task) => {
      const card = document.createElement('article');
      card.className = 'task-card';
      card.draggable = true;
      card.dataset.taskId = String(task.id);
      card.dataset.taskStatus = task.status || 'backlog';
      card.innerHTML = `
        <h4 class="task-title">${utils.escapeHtml(task.title || 'Untitled task')}</h4>
        <p class="text-muted text-sm" style="margin:0 0 12px 0;">${utils.escapeHtml(task.description || 'No description yet.')}</p>
        <div class="task-cost-row">
          <span>${utils.escapeHtml(utils.formatCurrency(task.estimated_cost || 0))} estimated</span>
          <span class="task-run-badge ${(task.open_run && !task.open_run.ended_at) ? 'is-open' : 'is-closed'}">${utils.escapeHtml(task.open_run && !task.open_run.ended_at ? 'run active' : (task.latest_run ? ui.formatRunStatus(task.latest_run) : 'no run'))}</span>
        </div>
        <div class="task-meta">
          <span class="task-assignee">${utils.escapeHtml(task.assignee || 'unassigned')}</span>
          <span class="task-priority ${constants.priorityClass[task.priority] || constants.priorityClass.medium}" title="${utils.escapeHtml(task.priority || 'medium')}"></span>
        </div>
      `;
      card.addEventListener('click', () => loadTaskDetail(task.id));
      card.addEventListener('dragstart', () => card.classList.add('is-dragging'));
      card.addEventListener('dragend', () => {
        card.classList.remove('is-dragging');
        document.querySelectorAll('.kanban-items').forEach((items) => items.classList.remove('is-drop-target'));
      });
      return card;
    };

    const updateKanbanCounts = () => {
      refs.kanbanColumns.forEach((column) => {
        const count = column.querySelectorAll('.task-card').length;
        const countEl = column.querySelector('.kanban-count');
        if (countEl) countEl.textContent = String(count);
        const items = column.querySelector('.kanban-items');
        const empty = items.querySelector('.task-empty');
        if (!count && !empty) {
          items.innerHTML = '<div class="task-empty">No tasks here yet.</div>';
        } else if (count && empty) {
          empty.remove();
        }
      });
    };

    const renderTasks = (tasks) => {
      refs.kanbanColumns.forEach((column) => { column.querySelector('.kanban-items').innerHTML = ''; });
      const sorted = [...tasks].sort((left, right) => {
        const statusDelta = constants.statusOrder.indexOf(left.status) - constants.statusOrder.indexOf(right.status);
        if (statusDelta !== 0) return statusDelta;
        return (right.id || 0) - (left.id || 0);
      });
      sorted.forEach((task) => {
        const column = document.querySelector(`.kanban-column[data-status="${task.status || 'backlog'}"] .kanban-items`);
        if (column) column.appendChild(createTaskCard(task));
      });
      updateKanbanCounts();
      if (state.selectedTaskId) {
        const stillExists = tasks.some((task) => Number(task.id) === Number(state.selectedTaskId));
        if (stillExists) {
          loadTaskDetail(state.selectedTaskId);
        } else {
          state.selectedTaskId = null;
          renderTaskDetail(null);
        }
      } else if (sorted.length) {
        loadTaskDetail(sorted[0].id);
      } else {
        renderTaskDetail(null);
      }
    };

    actions.loadTasks = async () => {
      try {
        const response = await fetch('/api/tasks', { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error('Could not load tasks');
        const payload = await response.json();
        renderTasks(payload.tasks || []);
      } catch (error) {
        ui.setTaskFeedback(error.message || 'Could not load tasks', 'error');
      }
    };

    const renderReportDetail = (report = null) => {
      if (!report) {
        state.selectedReportId = null;
        refs.reportDetailTitle.textContent = 'Select a report';
        refs.reportDetailSummary.textContent = 'Choose a report to inspect the durable summary and full body.';
        refs.reportDetailAgent.textContent = '-';
        refs.reportDetailRoutine.textContent = '-';
        refs.reportDetailStatus.textContent = '-';
        refs.reportDetailCreated.textContent = '-';
        refs.reportDetailBody.textContent = 'No report selected.';
        return;
      }
      state.selectedReportId = Number(report.id);
      refs.reportDetailTitle.textContent = report.title || 'Report';
      refs.reportDetailSummary.textContent = report.summary || 'No summary.';
      refs.reportDetailAgent.textContent = report.agent_id || '-';
      refs.reportDetailRoutine.textContent = report.routine_name || '-';
      refs.reportDetailStatus.textContent = report.status || '-';
      refs.reportDetailCreated.textContent = utils.formatDateTime(report.created_at);
      refs.reportDetailBody.textContent = report.body || report.summary || 'No body available.';
    };

    const resetRoutineForm = (routine = null) => {
      if (!routine) {
        state.selectedRoutineId = null;
        refs.routineDetailTitle.textContent = 'No routine selected';
        refs.routineDetailDescription.textContent = 'The drawer stays closed until you click a routine or create a new one.';
        refs.routineForm.reset();
        refs.routineScheduleType.value = 'daily';
        refs.routineScheduleTime.value = '09:00';
        refs.routineScheduleWeeklyTime.value = '09:00';
        refs.routineScheduleDay.value = '1';
        refs.routineScheduleHours.value = '4';
        refs.routineScheduleDate.value = '';
        refs.routineScheduleDateTime.value = '09:00';
        refs.routineCustomCron.value = '';
        refs.routineEnabledInput.checked = true;
        refs.routineRunsList.innerHTML = '<li><span>No routine selected.</span></li>';
        refs.routineReportsList.innerHTML = '<li><span>No routine selected.</span></li>';
        ui.setRoutineFeedback('');
        updateRoutineSchedulePreview();
        ui.setRoutinesDrawerOpen(false);
        return;
      }
      state.selectedRoutineId = Number(routine.id);
      refs.routineDetailTitle.textContent = routine.name || 'Routine';
      refs.routineDetailDescription.textContent = routine.prompt || 'No instruction saved yet.';
      refs.routineNameInput.value = routine.name || '';
      refs.routineAgentSelect.value = routine.agent_id || '';
      refs.routineScheduleType.value = routine.schedule_type || 'daily';
      refs.routineScheduleTime.value = routine.schedule_time || '09:00';
      refs.routineScheduleWeeklyTime.value = routine.schedule_time || '09:00';
      refs.routineScheduleDay.value = String(routine.schedule_day ?? '1');
      refs.routineScheduleHours.value = routine.schedule_interval_hours || '4';
      refs.routineScheduleDate.value = routine.schedule_date || '';
      refs.routineScheduleDateTime.value = routine.schedule_time || '09:00';
      refs.routineCustomCron.value = routine.cron_expression || '';
      refs.routineOutputMode.value = routine.output_mode || 'report_if_needed';
      refs.routineReportChannelInput.value = routine.report_channel_id || '';
      refs.routinePromptInput.value = routine.prompt || '';
      refs.routineEnabledInput.checked = Boolean(routine.enabled);
      refs.routineRunsList.innerHTML = (routine.runs || []).length
        ? routine.runs.map((run) => `<li><strong>${utils.escapeHtml(utils.formatDateTime(run.started_at))}</strong><br><span>${utils.escapeHtml(run.status || '-')}</span><br><span>${utils.escapeHtml(run.output_summary || 'No summary')}</span></li>`).join('')
        : '<li><span>No runs recorded yet.</span></li>';
      refs.routineReportsList.innerHTML = (routine.reports || []).length
        ? routine.reports.map((report) => `<li data-report-id="${report.id}"><strong>${utils.escapeHtml(report.title)}</strong><br><span>${utils.escapeHtml(report.summary || 'No summary')}</span></li>`).join('')
        : '<li><span>No reports linked yet.</span></li>';
      ui.setRoutineFeedback('');
      updateRoutineSchedulePreview();
      ui.setRoutinesDrawerOpen(true);
    };

    const loadRoutineDetail = async (routineId) => {
      try {
        const response = await fetch(`/api/routines/${routineId}`, { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error('Could not load routine');
        const payload = await response.json();
        resetRoutineForm(payload.routine || null);
        refs.routineReportsList.querySelectorAll('[data-report-id]').forEach((item) => {
          item.addEventListener('click', async () => {
            const reportId = item.dataset.reportId;
            if (!reportId) return;
            const reportRes = await fetch(`/api/reports/${reportId}`, { signal: AbortSignal.timeout(5000) });
            if (!reportRes.ok) return;
            const reportPayload = await reportRes.json();
            renderReportDetail(reportPayload.report || null);
            window.location.hash = '#reports';
            const reportsNav = document.querySelector('.nav-item[href="#reports"]');
            if (reportsNav) {
              document.querySelectorAll('.nav-item').forEach((nav) => nav.classList.remove('active'));
              reportsNav.classList.add('active');
            }
          });
        });
      } catch (error) {
        ui.setRoutineFeedback(error.message || 'Could not load routine', 'error');
      }
    };

    actions.loadRoutines = async () => {
      try {
        const response = await fetch('/api/routines', { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error('Could not load routines');
        const payload = await response.json();
        state.routinesCatalog = payload.routines || [];
        const enabled = state.routinesCatalog.filter((item) => item.enabled);
        const reportCount = state.routinesCatalog.reduce((sum, item) => sum + Number(item.report_count || 0), 0);
        const latest = state.routinesCatalog.filter((item) => item.last_run_at).sort((a, b) => new Date(b.last_run_at) - new Date(a.last_run_at))[0];
        refs.routinesCount.textContent = utils.numberFormat.format(state.routinesCatalog.length);
        refs.routinesEnabledCount.textContent = utils.numberFormat.format(enabled.length);
        refs.routinesReportCount.textContent = utils.numberFormat.format(reportCount);
        refs.routinesLastRun.textContent = latest ? utils.formatDateTime(latest.last_run_at) : '-';
        refs.routinesCountDetail.textContent = `${utils.numberFormat.format(state.routinesCatalog.length)} routines defined.`;
        refs.routinesEnabledDetail.textContent = `${utils.numberFormat.format(enabled.length)} enabled and ready to run.`;
        refs.routinesReportDetail.textContent = `${utils.numberFormat.format(reportCount)} reports generated from routines.`;
        refs.routinesLastRunDetail.textContent = latest ? latest.name : 'No routine has run yet.';
        refs.routinesTableBody.innerHTML = state.routinesCatalog.length ? state.routinesCatalog.map((routine) => `
          <tr data-routine-id="${routine.id}" class="${Number(state.selectedRoutineId) === Number(routine.id) ? 'is-selected' : ''}">
            <td>${utils.escapeHtml(routine.name)}</td>
            <td>${utils.escapeHtml(routine.agent_id || '-')}</td>
            <td>${utils.escapeHtml(routine.schedule_summary || routine.schedule_value || routine.schedule_type || '-')}</td>
            <td><span class="models-status${routine.enabled ? '' : ' is-muted'}">${routine.enabled ? 'Enabled' : 'Paused'}</span></td>
            <td>${utils.escapeHtml(utils.formatDateTime(routine.last_run_at))}</td>
          </tr>
        `).join('') : '<tr><td colspan="5"><div class="models-empty">No routines yet.</div></td></tr>';
        refs.routinesTableBody.querySelectorAll('tr[data-routine-id]').forEach((row) => {
          row.addEventListener('click', () => loadRoutineDetail(row.dataset.routineId));
        });
        if (state.selectedRoutineId && !state.routinesCatalog.some((item) => Number(item.id) === Number(state.selectedRoutineId))) {
          resetRoutineForm(null);
        }
      } catch (error) {
        refs.routinesTableBody.innerHTML = `<tr><td colspan="5"><div class="models-empty">${utils.escapeHtml(error.message || 'Could not load routines.')}</div></td></tr>`;
        ui.setRoutineFeedback(error.message || 'Could not load routines', 'error');
      }
    };

    actions.loadReports = async () => {
      try {
        const response = await fetch('/api/reports?limit=50', { signal: AbortSignal.timeout(5000) });
        if (!response.ok) throw new Error('Could not load reports');
        const payload = await response.json();
        state.reportsCatalog = payload.reports || [];
        const today = new Date().toISOString().slice(0, 10);
        const todayCount = state.reportsCatalog.filter((item) => String(item.created_at || '').slice(0, 10) === today).length;
        const latest = state.reportsCatalog[0];
        refs.reportsCount.textContent = utils.numberFormat.format(state.reportsCatalog.length);
        refs.reportsTodayCount.textContent = utils.numberFormat.format(todayCount);
        refs.reportsLatestRoutine.textContent = latest?.routine_name || '-';
        refs.reportsLatestAgent.textContent = latest?.agent_id || '-';
        refs.reportsCountDetail.textContent = `${utils.numberFormat.format(state.reportsCatalog.length)} reports stored.`;
        refs.reportsTodayDetail.textContent = `${utils.numberFormat.format(todayCount)} created today.`;
        refs.reportsLatestRoutineDetail.textContent = latest?.title || 'No reports yet.';
        refs.reportsLatestAgentDetail.textContent = latest?.summary || 'No reports yet.';
        refs.reportsTableBody.innerHTML = state.reportsCatalog.length ? state.reportsCatalog.map((report) => `
          <tr data-report-id="${report.id}" class="${Number(state.selectedReportId) === Number(report.id) ? 'is-selected' : ''}">
            <td>${utils.escapeHtml(report.title)}</td>
            <td>${utils.escapeHtml(report.agent_id || '-')}</td>
            <td>${utils.escapeHtml(report.routine_name || '-')}</td>
            <td><span class="models-status">${utils.escapeHtml(report.status || '-')}</span></td>
            <td>${utils.escapeHtml(utils.formatDateTime(report.created_at))}</td>
          </tr>
        `).join('') : '<tr><td colspan="5"><div class="models-empty">No reports yet.</div></td></tr>';
        refs.reportsTableBody.querySelectorAll('tr[data-report-id]').forEach((row) => {
          row.addEventListener('click', async () => {
            const reportId = row.dataset.reportId;
            const reportRes = await fetch(`/api/reports/${reportId}`, { signal: AbortSignal.timeout(5000) });
            if (!reportRes.ok) return;
            const reportPayload = await reportRes.json();
            renderReportDetail(reportPayload.report || null);
            refs.reportsTableBody.querySelectorAll('tr[data-report-id]').forEach((item) => item.classList.remove('is-selected'));
            row.classList.add('is-selected');
          });
        });
      } catch (error) {
        refs.reportsTableBody.innerHTML = `<tr><td colspan="5"><div class="models-empty">${utils.escapeHtml(error.message || 'Could not load reports.')}</div></td></tr>`;
      }
    };

    const updateTaskStatus = async (taskId, status) => {
      const response = await fetch(`/api/tasks/${taskId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status }),
      });
      if (!response.ok) {
        const payload = await response.json().catch(() => ({}));
        throw new Error(payload.error || 'Could not update task status');
      }
      return response.json();
    };

    refs.kanbanColumns.forEach((column) => {
      const items = column.querySelector('.kanban-items');
      items.addEventListener('dragover', (event) => {
        event.preventDefault();
        items.classList.add('is-drop-target');
      });
      items.addEventListener('dragleave', () => items.classList.remove('is-drop-target'));
      items.addEventListener('drop', async (event) => {
        event.preventDefault();
        items.classList.remove('is-drop-target');
        const dragging = document.querySelector('.task-card.is-dragging');
        if (!dragging) return;
        const status = column.dataset.status;
        const previousColumn = dragging.closest('.kanban-items');
        if (dragging.dataset.taskStatus === status) return;
        items.appendChild(dragging);
        updateKanbanCounts();
        try {
          await updateTaskStatus(dragging.dataset.taskId, status);
          dragging.dataset.taskStatus = status;
          ui.setTaskFeedback('Task updated.', 'success');
          await actions.loadTasks();
        } catch (error) {
          previousColumn.appendChild(dragging);
          updateKanbanCounts();
          ui.setTaskFeedback(error.message || 'Could not update task', 'error');
        }
      });
    });

    refs.taskNewButton.addEventListener('click', () => {
      ui.toggleTaskForm(refs.taskForm.classList.contains('is-hidden'));
      if (!refs.taskForm.classList.contains('is-hidden')) ui.setTaskFeedback('');
    });
    refs.taskCancelButton.addEventListener('click', () => {
      refs.taskForm.reset();
      refs.taskPrioritySelect.value = 'medium';
      ui.toggleTaskForm(false);
      ui.setTaskFeedback('');
    });
    refs.taskForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      ui.setTaskFeedback('Creating task...');
      try {
        const response = await fetch('/api/tasks', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            title: refs.taskTitleInput.value.trim(),
            description: refs.taskDescriptionInput.value.trim(),
            assignee: refs.taskAssigneeSelect.value,
            priority: refs.taskPrioritySelect.value,
            status: 'backlog',
          }),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not create task');
        refs.taskForm.reset();
        refs.taskPrioritySelect.value = 'medium';
        ui.toggleTaskForm(false);
        ui.setTaskFeedback('Task created.', 'success');
        await actions.loadTasks();
      } catch (error) {
        ui.setTaskFeedback(error.message || 'Could not create task', 'error');
      }
    });

    refs.routineResetButton.addEventListener('click', () => resetRoutineForm(null));
    refs.routinesNewButton.addEventListener('click', () => {
      refs.routineForm.reset();
      refs.routineScheduleType.value = 'daily';
      refs.routineScheduleTime.value = '09:00';
      refs.routineScheduleWeeklyTime.value = '09:00';
      refs.routineScheduleDay.value = '1';
      refs.routineScheduleHours.value = '4';
      refs.routineScheduleDate.value = '';
      refs.routineScheduleDateTime.value = '09:00';
      refs.routineCustomCron.value = '';
      refs.routineEnabledInput.checked = true;
      refs.routineRunsList.innerHTML = '<li><span>No routine selected.</span></li>';
      refs.routineReportsList.innerHTML = '<li><span>No routine selected.</span></li>';
      refs.routineDetailTitle.textContent = 'New routine';
      refs.routineDetailDescription.textContent = 'Create recurring work for an agent. Tasks are one-off; routines are scheduled loops.';
      state.selectedRoutineId = null;
      ui.setRoutineFeedback('');
      updateRoutineSchedulePreview();
      ui.setRoutinesDrawerOpen(true);
      refs.routineNameInput.focus();
    });
    [
      refs.routineScheduleType,
      refs.routineScheduleTime,
      refs.routineScheduleWeeklyTime,
      refs.routineScheduleDay,
      refs.routineScheduleHours,
      refs.routineScheduleDate,
      refs.routineScheduleDateTime,
      refs.routineCustomCron,
    ].forEach((element) => {
      element.addEventListener('input', updateRoutineSchedulePreview);
      element.addEventListener('change', updateRoutineSchedulePreview);
    });
    refs.routinesDrawerBackdrop.addEventListener('click', () => resetRoutineForm(null));
    refs.routinesDrawerClose.addEventListener('click', () => resetRoutineForm(null));
    refs.routineRunButton.addEventListener('click', async () => {
      if (!state.selectedRoutineId) {
        ui.setRoutineFeedback('Select or save a routine first.', 'error');
        return;
      }
      ui.setRoutineFeedback('Running routine...');
      try {
        const response = await fetch(`/api/routines/${state.selectedRoutineId}/run`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not run routine');
        resetRoutineForm(payload.routine || null);
        await Promise.all([actions.loadRoutines(), actions.loadReports()]);
        ui.setRoutineFeedback('Routine run recorded.', 'success');
      } catch (error) {
        ui.setRoutineFeedback(error.message || 'Could not run routine.', 'error');
      }
    });
    refs.routineForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      ui.setRoutineFeedback('Saving routine...');
      try {
        const type = refs.routineScheduleType.value;
        const scheduleTime = type === 'weekly'
          ? refs.routineScheduleWeeklyTime.value
          : type === 'date'
            ? refs.routineScheduleDateTime.value
          : refs.routineScheduleTime.value;
        const compiled = utils.compileRoutineSchedule({
          scheduleType: type,
          scheduleTime,
          scheduleDay: refs.routineScheduleDay.value,
          scheduleHours: refs.routineScheduleHours.value,
          scheduleDate: refs.routineScheduleDate.value,
          customCron: refs.routineCustomCron.value,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        });
        const body = {
          name: refs.routineNameInput.value.trim(),
          agent_id: refs.routineAgentSelect.value,
          schedule_type: type,
          schedule_value: compiled.schedule_value,
          schedule_summary: compiled.schedule_summary,
          schedule_time: scheduleTime,
          schedule_day: refs.routineScheduleDay.value,
          schedule_interval_hours: refs.routineScheduleHours.value,
          schedule_date: refs.routineScheduleDate.value,
          cron_expression: compiled.cron_expression,
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC',
          prompt: refs.routinePromptInput.value.trim(),
          output_mode: refs.routineOutputMode.value,
          report_channel_id: refs.routineReportChannelInput.value.trim(),
          enabled: refs.routineEnabledInput.checked,
        };
        const url = state.selectedRoutineId ? `/api/routines/${state.selectedRoutineId}` : '/api/routines';
        const method = state.selectedRoutineId ? 'PUT' : 'POST';
        const response = await fetch(url, {
          method,
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not save routine');
        resetRoutineForm(payload.routine || null);
        await actions.loadRoutines();
        ui.setRoutineFeedback('Routine saved.', 'success');
      } catch (error) {
        ui.setRoutineFeedback(error.message || 'Could not save routine.', 'error');
      }
    });

    updateRoutineSchedulePreview();
  });
})();

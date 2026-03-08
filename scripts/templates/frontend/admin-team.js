(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, state, utils, ui, actions } = app;

    const clearOrgPanel = () => {
      state.selectedAgentId = null;
      utils.orgNodes().forEach((item) => item.classList.remove('is-selected'));
      refs.panelName.textContent = 'No agent selected';
      refs.panelRole.textContent = 'Pick any agent card in the team view';
      refs.panelDesc.textContent = 'The drawer stays closed until you click an agent.';
      refs.panelStatus.textContent = 'Status: -';
      refs.panelFocus.textContent = 'Focus: -';
      refs.panelResponsibilities.innerHTML = '<li>Select an agent to inspect status, role, and responsibilities.</li>';
      refs.panelBudgetInput.value = '';
      refs.panelBudgetInput.disabled = true;
      refs.panelBudgetSave.disabled = true;
      refs.panelBudgetHelp.textContent = 'Select an agent to configure their budget cap.';
      ui.setAgentPanelBudgetFeedback('');
      ui.setTeamPanelOpen(false);
    };

    const renderOrgPanel = (node) => {
      state.selectedAgentId = node.dataset.agentId || null;
      utils.orgNodes().forEach((item) => item.classList.toggle('is-selected', item === node));
      refs.panelName.textContent = node.dataset.agentName || '';
      refs.panelRole.textContent = node.dataset.agentRole || '';
      refs.panelDesc.textContent = node.dataset.agentDesc || '';
      refs.panelStatus.textContent = `Status: ${node.dataset.agentStatus || 'Unknown'}`;
      refs.panelFocus.textContent = `Focus: ${node.dataset.agentFocus || 'N/A'}`;
      const responsibilities = (node.dataset.agentResponsibilities || '').split('|').filter(Boolean);
      refs.panelResponsibilities.innerHTML = responsibilities.map((item) => `<li>${utils.escapeHtml(item)}</li>`).join('');
      refs.panelBudgetInput.disabled = false;
      refs.panelBudgetSave.disabled = false;
      refs.panelBudgetInput.value = node.dataset.agentBudget || '';
      refs.panelBudgetHelp.textContent = node.dataset.agentBudget
        ? `Current monthly budget cap: ${utils.formatCurrency(Number(node.dataset.agentBudget || 0))}.`
        : 'No monthly budget cap is set for this agent yet.';
      ui.setAgentPanelBudgetFeedback('');
      ui.setTeamPanelOpen(true);
    };

    const bindOrgNode = (node) => {
      if (node.dataset.orgBound === 'true') return;
      node.dataset.orgBound = 'true';
      node.addEventListener('click', () => renderOrgPanel(node));
    };

    const applyNodeData = (node, data) => {
      node.dataset.agentId = data.id;
      node.dataset.agentName = data.name;
      node.dataset.agentRole = data.role;
      node.dataset.agentStatus = data.status;
      node.dataset.agentFocus = data.focus;
      node.dataset.agentDesc = data.description;
      node.dataset.agentResponsibilities = data.responsibilities.join('|');
      node.dataset.agentBudget = data.monthlyBudget == null ? '' : String(data.monthlyBudget);
      const eyebrowDot = data.status === 'Running' ? 'status-dot--online' : 'status-dot--offline';
      node.innerHTML = `
        <span class="org-node__eyebrow"><span class="status-dot ${eyebrowDot}"></span> ${utils.escapeHtml(data.eyebrow)}</span>
        <div class="org-node__title-row">
          <h3 class="org-node__name">${utils.escapeHtml(data.name)}</h3>
          <span class="org-pill">${utils.escapeHtml(data.department)}</span>
        </div>
        <p class="org-node__role">${utils.escapeHtml(data.summary)}</p>
        <p class="org-node__desc">${utils.escapeHtml(data.description)}</p>
        ${data.meta.length ? `<div class="org-node__meta">${data.meta.map((item) => `<span class="org-pill">${utils.escapeHtml(item)}</span>`).join('')}</div>` : ''}
      `;
    };

    const normalizeAgent = (agentId, agent, isRoot) => {
      const status = agent && agent.status ? agent.status : (agent && agent.pid ? 'Running' : 'Discovered');
      const role = agent && agent.role ? agent.role : (isRoot ? 'Main Agent' : 'Team Member');
      const description = agent && agent.description ? agent.description : (isRoot ? 'Primary local OpenClaw profile.' : 'Discovered local agent.');
      return {
        id: agentId,
        name: agentId,
        role,
        status,
        focus: isRoot ? 'System orchestration, delegation, oversight' : description,
        description,
        responsibilities: isRoot
          ? ['Routes and coordinates local work', 'Owns the primary profile', 'Acts as root for the team view']
          : ['Handles assigned work', 'Operates as an independent agent', agent && agent.channel_id ? `Listens only on inbox channel ${agent.channel_id}` : 'Should be assigned a dedicated inbox channel'],
        eyebrow: isRoot ? 'Root Agent' : 'Team Member',
        department: isRoot ? 'Primary profile' : role,
        summary: role,
        monthlyBudget: agent && agent.monthly_budget != null ? Number(agent.monthly_budget) : null,
        meta: [
          status === 'Running' ? 'Active now' : status,
          agent && agent.specialty === 'seo' ? 'SEO specialist' : null,
          agent && agent.monthly_budget != null ? `Budget ${utils.formatCurrency(Number(agent.monthly_budget || 0))}` : 'Budget unset',
          agent && agent.port ? `Port ${agent.port}` : null,
          agent && agent.channel_id ? `Inbox ${agent.channel_id}` : null,
          agent && agent.session_count ? `${agent.session_count} sessions` : null,
        ].filter(Boolean),
      };
    };

    const createBranchNode = (agentId, agent) => {
      const branch = document.createElement('div');
      branch.className = 'team-chart__member';
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'org-node';
      applyNodeData(button, normalizeAgent(agentId, agent, false));
      bindOrgNode(button);
      branch.appendChild(button);
      return branch;
    };

    actions.loadDepartments = async () => {
      const selectedAgentId = state.selectedAgentId;
      try {
        const response = await fetch('/api/departments', { signal: AbortSignal.timeout(5000) });
        if (!response.ok) return;
        const payload = await response.json();
        const agents = payload.agents || {};
        state.agentsCatalog = agents;
        ui.populateAssignees(agents);
        const rootId = agents.main ? 'main' : (Object.keys(agents)[0] || 'main');
        const rootAgent = agents[rootId] || {};
        applyNodeData(refs.orgRootNode, normalizeAgent(rootId, rootAgent, true));
        bindOrgNode(refs.orgRootNode);
        const entries = Object.entries(agents).filter(([agentId]) => agentId !== rootId);
        if (!entries.length) {
          refs.orgBranches.innerHTML = '';
          clearOrgPanel();
          return;
        }
        refs.orgBranches.innerHTML = '';
        entries.sort(([left], [right]) => left.localeCompare(right)).forEach(([agentId, agent]) => {
          refs.orgBranches.appendChild(createBranchNode(agentId, agent));
        });
        const selectedNode = utils.orgNodes().find((item) => item.dataset.agentId === selectedAgentId);
        if (selectedNode) renderOrgPanel(selectedNode);
        else clearOrgPanel();
      } catch {
        bindOrgNode(refs.orgRootNode);
        clearOrgPanel();
      }
    };

    refs.teamChartPanelBackdrop.addEventListener('click', clearOrgPanel);
    refs.teamChartPanelClose.addEventListener('click', clearOrgPanel);
    refs.teamNewAgentButton.addEventListener('click', () => {
      ui.resetAgentForm();
      ui.setAgentDrawerOpen(true);
      refs.agentNameInput.focus();
    });
    refs.agentDrawerBackdrop.addEventListener('click', () => ui.setAgentDrawerOpen(false));
    refs.agentDrawerClose.addEventListener('click', () => ui.setAgentDrawerOpen(false));
    refs.agentCancelButton.addEventListener('click', () => ui.setAgentDrawerOpen(false));
    refs.agentForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      ui.setAgentFeedback('Creating agent...');
      try {
        const body = {
          agent_id: refs.agentNameInput.value.trim(),
          role: refs.agentRoleInput.value.trim(),
          description: refs.agentDescriptionInput.value.trim(),
          model_primary: refs.agentModelSelect.value,
          specialty: refs.agentSpecialtySelect.value,
          port: refs.agentPortInput.value.trim(),
          discord_token: refs.agentDiscordTokenInput.value.trim(),
          channel_id: refs.agentChannelIdInput.value.trim(),
          monthly_budget: refs.agentMonthlyBudgetInput.value.trim(),
        };
        const response = await fetch('/api/spawn-agent', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok || payload.ok === false) throw new Error(payload.detail || payload.error || payload.stderr || 'Could not create agent');
        ui.setAgentFeedback('Agent created.', 'success');
        ui.resetAgentForm();
        ui.setAgentDrawerOpen(false);
        await Promise.all([actions.loadDepartments(), actions.loadTasks()]);
      } catch (error) {
        ui.setAgentFeedback(error.message || 'Could not create agent.', 'error');
      }
    });

    refs.panelBudgetSave.addEventListener('click', async () => {
      if (!state.selectedAgentId) return;
      ui.setAgentPanelBudgetFeedback('Saving budget...');
      try {
        const response = await fetch(`/api/agents/${encodeURIComponent(state.selectedAgentId)}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            monthly_budget: refs.panelBudgetInput.value.trim(),
          }),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok || payload.ok === false) throw new Error(payload.error || 'Could not save budget');
        ui.setAgentPanelBudgetFeedback('Budget saved.', 'success');
        await Promise.all([actions.loadDepartments(), typeof actions.renderBudget === 'function' ? actions.renderBudget() : Promise.resolve()]);
      } catch (error) {
        ui.setAgentPanelBudgetFeedback(error.message || 'Could not save budget.', 'error');
      }
    });

    utils.orgNodes().forEach(bindOrgNode);
  });
})();

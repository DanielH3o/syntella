(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, state, utils, ui, actions } = app;

    const INTEGRATION_META = {
      ghost: { label: 'Ghost CMS' },
      google_search_console: { label: 'Google Search Console' },
      google_analytics: { label: 'Google Analytics' },
    };

    const currentIntegration = () => state.integrationsCatalog.find((item) => item.system === state.selectedIntegrationSystem) || null;

    const renderDynamicFields = (integration = null) => {
      const system = state.selectedIntegrationSystem || (integration && integration.system) || '';
      const descriptor = (integration || state.integrationsCatalog.find((item) => item.system === system)) || null;
      const configFields = descriptor ? descriptor.config_fields || [] : [];
      const secretFields = descriptor ? descriptor.secret_fields || [] : [];
      refs.integrationDynamicFields.innerHTML = configFields.concat(secretFields).map((field) => {
        const value = descriptor && descriptor.config ? (descriptor.config[field.key] || '') : '';
        const help = field.configured ? 'Stored already. Enter a new value only if you want to replace it.' : 'No value saved yet.';
        if (field.type === 'textarea') {
          return `
            <div class="task-form__field">
              <label class="form-label" for="integration-field-${utils.escapeHtml(field.key)}">${utils.escapeHtml(field.label)}</label>
              <textarea id="integration-field-${utils.escapeHtml(field.key)}" data-field-key="${utils.escapeHtml(field.key)}" data-field-type="${field.type}" data-secret="${field.configured !== undefined ? 'true' : 'false'}" placeholder="${utils.escapeHtml(field.placeholder || '')}">${field.configured !== undefined ? '' : utils.escapeHtml(value)}</textarea>
              ${field.configured !== undefined ? `<p class="models-helper">${utils.escapeHtml(help)}</p>` : ''}
            </div>
          `;
        }
        return `
          <div class="task-form__field">
            <label class="form-label" for="integration-field-${utils.escapeHtml(field.key)}">${utils.escapeHtml(field.label)}</label>
            <input id="integration-field-${utils.escapeHtml(field.key)}" data-field-key="${utils.escapeHtml(field.key)}" data-field-type="${field.type}" data-secret="${field.configured !== undefined ? 'true' : 'false'}" type="${field.type === 'password' ? 'password' : 'text'}" value="${field.configured !== undefined ? '' : utils.escapeHtml(value)}" placeholder="${utils.escapeHtml(field.placeholder || '')}" />
            ${field.configured !== undefined ? `<p class="models-helper">${utils.escapeHtml(help)}</p>` : ''}
          </div>
        `;
      }).join('');
    };

    const resetIntegrationForm = (integration = null) => {
      state.selectedIntegrationSystem = integration ? integration.system : null;
      refs.integrationsEditorTitle.textContent = integration ? integration.display_name : 'Configure Integration';
      refs.integrationsEditorMeta.textContent = integration ? integration.description : 'Select a system and store the config the matching tools will need.';
      refs.integrationSystemValue.textContent = integration ? integration.display_name : 'Select an integration row';
      refs.integrationScopeSelect.value = integration && integration.allowed_specialties && integration.allowed_specialties.includes('seo') ? 'seo' : '';
      refs.integrationEnabledInput.checked = integration ? Boolean(integration.enabled) : false;
      refs.integrationNotesInput.value = integration ? (integration.notes || '') : '';
      renderDynamicFields(integration);
      ui.setIntegrationsFeedback('');
    };

    const renderIntegrations = () => {
      const integrations = state.integrationsCatalog;
      const enabled = integrations.filter((item) => item.enabled).length;
      const configured = integrations.filter((item) => item.configured).length;
      const seoScoped = integrations.filter((item) => (item.allowed_specialties || []).includes('seo')).length;
      refs.integrationsCount.textContent = utils.numberFormat.format(integrations.length);
      refs.integrationsEnabledCount.textContent = utils.numberFormat.format(enabled);
      refs.integrationsConfiguredCount.textContent = utils.numberFormat.format(configured);
      refs.integrationsSeoCount.textContent = utils.numberFormat.format(seoScoped);
      refs.integrationsCountDetail.textContent = `${utils.numberFormat.format(integrations.length)} systems available for agent tooling.`;
      refs.integrationsEnabledDetail.textContent = `${utils.numberFormat.format(enabled)} can currently be used by connected tools.`;
      refs.integrationsConfiguredDetail.textContent = `${utils.numberFormat.format(configured)} have saved config or credentials.`;
      refs.integrationsSeoDetail.textContent = `${utils.numberFormat.format(seoScoped)} are currently limited to SEO-specialist agents.`;
      refs.integrationsTableBody.innerHTML = integrations.map((item) => {
        const selected = state.selectedIntegrationSystem === item.system ? 'is-selected' : '';
        const status = item.enabled ? (item.configured ? 'Enabled' : 'Needs setup') : 'Disabled';
        const statusClass = item.enabled ? (item.configured ? '' : ' is-warning') : ' is-muted';
        const secretsCount = (item.secret_fields || []).filter((field) => field.configured).length;
        const access = (item.allowed_specialties || []).includes('seo') ? 'SEO only' : 'All specialties';
        return `
          <tr data-integration-system="${utils.escapeHtml(item.system)}" class="${selected}">
            <td><strong>${utils.escapeHtml(item.display_name)}</strong><br /><span class="text-muted">${utils.escapeHtml(item.description)}</span></td>
            <td><span class="models-status${statusClass}">${utils.escapeHtml(status)}</span></td>
            <td>${utils.escapeHtml(access)}</td>
            <td>${utils.escapeHtml(`${secretsCount} saved`)}</td>
            <td>${utils.escapeHtml(item.updated_at ? utils.formatDateTime(item.updated_at) : '-')}</td>
          </tr>
        `;
      }).join('');
      refs.integrationsTableBody.querySelectorAll('tr[data-integration-system]').forEach((row) => {
        row.addEventListener('click', () => {
          const integration = state.integrationsCatalog.find((item) => item.system === row.dataset.integrationSystem);
          if (!integration) return;
          resetIntegrationForm(integration);
          ui.setIntegrationsDrawerOpen(true);
          renderIntegrations();
        });
      });
    };

    actions.loadIntegrations = async () => {
      try {
        const response = await fetch('/api/integrations', { signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error('Could not load integrations');
        const payload = await response.json();
        state.integrationsCatalog = payload.integrations || [];
        const selected = currentIntegration() || null;
        resetIntegrationForm(selected);
        renderIntegrations();
      } catch (error) {
        refs.integrationsTableBody.innerHTML = `<tr><td colspan="5"><div class="models-empty">${utils.escapeHtml(error.message || 'Could not load integrations.')}</div></td></tr>`;
        ui.setIntegrationsFeedback(error.message || 'Could not load integrations.', 'error');
      }
    };

    refs.integrationsCancelButton.addEventListener('click', () => ui.setIntegrationsDrawerOpen(false));
    refs.integrationsDrawerBackdrop.addEventListener('click', () => ui.setIntegrationsDrawerOpen(false));
    refs.integrationsDrawerClose.addEventListener('click', () => ui.setIntegrationsDrawerOpen(false));
    refs.integrationsResetButton.addEventListener('click', async () => {
      const system = state.selectedIntegrationSystem;
      if (!system) {
        ui.setIntegrationsFeedback('Select an integration row first.', 'error');
        return;
      }
      ui.setIntegrationsFeedback('Clearing integration...');
      try {
        const response = await fetch('/api/integrations', {
          method: 'DELETE',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ system }),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not clear integration');
        state.integrationsCatalog = payload.integrations || [];
        resetIntegrationForm(null);
        renderIntegrations();
        ui.setIntegrationsFeedback('Integration cleared.', 'success');
      } catch (error) {
        ui.setIntegrationsFeedback(error.message || 'Could not clear integration.', 'error');
      }
    });
    refs.integrationsForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      ui.setIntegrationsFeedback('Saving integration...');
      try {
        const system = state.selectedIntegrationSystem;
        if (!system) throw new Error('Select an integration row first.');
        const body = {
          system,
          enabled: refs.integrationEnabledInput.checked,
          allowed_specialties: refs.integrationScopeSelect.value ? [refs.integrationScopeSelect.value] : [],
          notes: refs.integrationNotesInput.value.trim(),
        };
        refs.integrationDynamicFields.querySelectorAll('[data-field-key]').forEach((field) => {
          body[field.dataset.fieldKey] = field.value;
        });
        const response = await fetch('/api/integrations', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not save integration');
        state.integrationsCatalog = payload.integrations || [];
        const refreshed = state.integrationsCatalog.find((item) => item.system === system) || null;
        resetIntegrationForm(refreshed);
        renderIntegrations();
        ui.setIntegrationsFeedback(`${INTEGRATION_META[system]?.label || 'Integration'} saved.`, 'success');
      } catch (error) {
        ui.setIntegrationsFeedback(error.message || 'Could not save integration.', 'error');
      }
    });
  });
})();

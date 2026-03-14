(function () {
  window.SyntellaAdminRegister((app) => {
    const { refs, state, utils, ui, actions } = app;
    const runtimeMessage = (payload, successMessage) => {
      const runtime = payload && payload.runtime;
      if (!runtime) return successMessage;
      if (runtime.ok) return `${successMessage} Gateway reloaded successfully.`;
      return `${successMessage} Config saved, but gateway reload failed. Check ${runtime.log_file || 'gateway logs'}.`;
    };

    const currentModelSelection = () => state.modelsCatalog.find((item) => utils.modelKey(item.provider, item.model_id) === state.selectedModelKey) || null;

    const resetModelsForm = (model = null) => {
      if (!model) {
        state.selectedModelKey = null;
        refs.modelsEditorTitle.textContent = 'New Model';
        refs.modelsEditorMeta.textContent = 'Add a model to the shared OpenClaw catalog so agents can actually use it.';
        refs.modelProviderBaseUrlInput.value = '';
        refs.modelProviderApiAdapterInput.value = '';
        refs.modelProviderApiKeyInput.value = '';
        refs.modelProviderApiKeyHelp.textContent = 'Stored in OpenClaw config. Existing keys are never shown back in the UI.';
        refs.modelProviderInput.value = '';
        refs.modelIdInput.value = '';
        refs.modelDisplayNameInput.value = '';
        refs.modelEnabledInput.checked = true;
        refs.modelReasoningInput.checked = false;
        refs.modelModalitiesInput.value = '';
        refs.modelContextWindowInput.value = '';
        refs.modelMaxTokensInput.value = '';
        refs.modelCostInputInput.value = '';
        refs.modelCostOutputInput.value = '';
        refs.modelCostCacheReadInput.value = '';
        refs.modelCostCacheWriteInput.value = '';
        refs.modelNotesInput.value = '';
        return;
      }
      state.selectedModelKey = utils.modelKey(model.provider, model.model_id);
      refs.modelsEditorTitle.textContent = model.display_name || model.model_id;
      refs.modelsEditorMeta.textContent = `${model.provider} • ${model.has_override ? 'Override active' : 'Using shared OpenClaw config'}`;
      refs.modelProviderBaseUrlInput.value = model.provider_base_url || '';
      refs.modelProviderApiAdapterInput.value = model.provider_api_adapter || '';
      refs.modelProviderApiKeyInput.value = '';
      refs.modelProviderApiKeyHelp.textContent = model.provider_has_api_key
        ? 'An API key already exists for this provider. Enter a new one only if you want to replace it.'
        : 'No provider API key detected yet. Add one here if this provider needs it.';
      refs.modelProviderInput.value = model.provider || '';
      refs.modelIdInput.value = model.model_id || '';
      refs.modelDisplayNameInput.value = model.display_name || '';
      refs.modelEnabledInput.checked = Boolean(model.enabled);
      refs.modelReasoningInput.checked = Boolean(model.reasoning);
      refs.modelModalitiesInput.value = (model.input_modalities || []).join(',');
      refs.modelContextWindowInput.value = model.context_window || '';
      refs.modelMaxTokensInput.value = model.max_tokens || '';
      refs.modelCostInputInput.value = model.cost_input ?? '';
      refs.modelCostOutputInput.value = model.cost_output ?? '';
      refs.modelCostCacheReadInput.value = model.cost_cache_read ?? '';
      refs.modelCostCacheWriteInput.value = model.cost_cache_write ?? '';
      refs.modelNotesInput.value = model.notes || '';
      ui.setModelsDrawerOpen(true);
    };

    const filteredModels = () => {
      const search = (refs.modelsSearch.value || '').trim().toLowerCase();
      const provider = refs.modelsProviderFilter.value || 'all';
      const status = refs.modelsStatusFilter.value || 'all';
      return state.modelsCatalog.filter((model) => {
        if (provider !== 'all' && model.provider !== provider) return false;
        if (status === 'enabled' && !model.enabled) return false;
        if (status === 'disabled' && model.enabled) return false;
        if (status === 'missing_pricing' && model.pricing_complete) return false;
        if (status === 'observed' && !model.observed) return false;
        if (!search) return true;
        return [model.display_name, model.model_id, model.provider]
          .filter(Boolean)
          .some((value) => value.toLowerCase().includes(search));
      });
    };

    const renderModels = () => {
      const providers = [...new Set(state.modelsCatalog.map((model) => model.provider).filter(Boolean))];
      utils.fillSelectOptions(refs.modelsProviderFilter, providers, 'All providers');
      const visible = filteredModels();
      const enabledCount = state.modelsCatalog.filter((model) => model.enabled).length;
      const missingPricingCount = state.modelsCatalog.filter((model) => !model.pricing_complete).length;
      const observedCount = state.modelsCatalog.filter((model) => model.observed).length;
      refs.modelsCount.textContent = utils.numberFormat.format(state.modelsCatalog.length);
      refs.modelsEnabledCount.textContent = utils.numberFormat.format(enabledCount);
      refs.modelsMissingPricing.textContent = utils.numberFormat.format(missingPricingCount);
      refs.modelsObservedCount.textContent = utils.numberFormat.format(observedCount);
      refs.modelsCountDetail.textContent = `${utils.numberFormat.format(visible.length)} visible with current filters.`;
      refs.modelsEnabledDetail.textContent = `${utils.numberFormat.format(enabledCount)} enabled for future agent use.`;
      refs.modelsMissingPricingDetail.textContent = `${utils.numberFormat.format(missingPricingCount)} need manual pricing help.`;
      refs.modelsObservedDetail.textContent = `${utils.numberFormat.format(observedCount)} have already appeared in usage logs.`;
      if (!visible.length) {
        refs.modelsTableBody.innerHTML = '<tr><td colspan="5"><div class="models-empty">No models match the current filter.</div></td></tr>';
        return;
      }
      refs.modelsTableBody.innerHTML = visible.map((model) => {
        const key = utils.modelKey(model.provider, model.model_id);
        const statusClass = model.enabled ? (model.pricing_complete ? '' : ' is-warning') : ' is-muted';
        const statusLabel = model.enabled ? (model.pricing_complete ? 'Enabled' : 'Needs pricing') : 'Disabled';
        return `
          <tr data-model-key="${utils.escapeHtml(key)}" class="${state.selectedModelKey === key ? 'is-selected' : ''}">
            <td><strong>${utils.escapeHtml(model.display_name || model.model_id)}</strong><br /><span class="text-muted">${utils.escapeHtml(model.model_id)}</span></td>
            <td>${utils.escapeHtml(model.provider)}</td>
            <td><span class="models-status${statusClass}">${utils.escapeHtml(statusLabel)}</span></td>
            <td>${utils.escapeHtml((model.cost_input || model.cost_input === 0) ? `$${Number(model.cost_input).toFixed(2)}` : '-')}</td>
            <td>${utils.escapeHtml((model.cost_output || model.cost_output === 0) ? `$${Number(model.cost_output).toFixed(2)}` : '-')}</td>
          </tr>
        `;
      }).join('');
      refs.modelsTableBody.querySelectorAll('tr[data-model-key]').forEach((row) => {
        row.addEventListener('click', () => {
          const model = state.modelsCatalog.find((item) => utils.modelKey(item.provider, item.model_id) === row.dataset.modelKey);
          if (!model) return;
          resetModelsForm(model);
          renderModels();
        });
      });
    };

    actions.loadModels = async () => {
      try {
        const response = await fetch('/api/models', { signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error('Could not load model catalog');
        const payload = await response.json();
        state.modelsCatalog = payload.models || [];
        const enabledModels = state.modelsCatalog
          .filter((model) => model.enabled)
          .sort((left, right) => (left.display_name || left.model_id).localeCompare(right.display_name || right.model_id));
        refs.agentModelSelect.innerHTML = ['<option value="">Select a model</option>']
          .concat(enabledModels.map((model) => `<option value="${utils.escapeHtml(`${model.provider}/${model.model_id}`)}">${utils.escapeHtml(`${model.display_name || model.model_id} (${model.provider}/${model.model_id})`)}</option>`))
          .join('');
        const selected = currentModelSelection();
        resetModelsForm(selected || null);
        renderModels();
      } catch (error) {
        refs.modelsTableBody.innerHTML = `<tr><td colspan="5"><div class="models-empty">${utils.escapeHtml(error.message || 'Could not load models.')}</div></td></tr>`;
        ui.setModelsFeedback(error.message || 'Could not load models.', 'error');
      }
    };

    [refs.modelsSearch, refs.modelsProviderFilter, refs.modelsStatusFilter].forEach((element) => {
      element.addEventListener('input', renderModels);
      element.addEventListener('change', renderModels);
    });

    refs.modelsNewButton.addEventListener('click', () => {
      ui.setModelsFeedback('');
      resetModelsForm(null);
      ui.setModelsDrawerOpen(true);
    });
    refs.modelsCancelButton.addEventListener('click', () => {
      ui.setModelsFeedback('');
      ui.setModelsDrawerOpen(false);
    });
    refs.modelsDrawerBackdrop.addEventListener('click', () => ui.setModelsDrawerOpen(false));
    refs.modelsDrawerClose.addEventListener('click', () => ui.setModelsDrawerOpen(false));
    refs.modelsResetButton.addEventListener('click', async () => {
      const selected = currentModelSelection();
      if (!selected || !selected.has_override) {
        ui.setModelsFeedback('No saved override to clear for this model.', 'error');
        return;
      }
      ui.setModelsFeedback('Clearing override...');
      try {
        const response = await fetch('/api/models/overrides', {
          method: 'DELETE',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ provider: selected.provider, model_id: selected.model_id }),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not clear model override');
        state.modelsCatalog = payload.models || [];
        const refreshed = state.modelsCatalog.find((item) => utils.modelKey(item.provider, item.model_id) === utils.modelKey(selected.provider, selected.model_id)) || null;
        resetModelsForm(refreshed);
        renderModels();
        ui.setModelsFeedback(runtimeMessage(payload, 'Override cleared.'), payload.runtime && !payload.runtime.ok ? 'error' : 'success');
      } catch (error) {
        ui.setModelsFeedback(error.message || 'Could not clear override.', 'error');
      }
    });
    refs.modelsForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      ui.setModelsFeedback('Saving override...');
      try {
        const body = {
          provider: refs.modelProviderInput.value.trim(),
          model_id: refs.modelIdInput.value.trim(),
          display_name: refs.modelDisplayNameInput.value.trim(),
          provider_base_url: refs.modelProviderBaseUrlInput.value.trim(),
          provider_api_adapter: refs.modelProviderApiAdapterInput.value.trim(),
          provider_api_key: refs.modelProviderApiKeyInput.value,
          enabled: refs.modelEnabledInput.checked,
          reasoning: refs.modelReasoningInput.checked,
          input_modalities: refs.modelModalitiesInput.value.trim(),
          context_window: utils.parseFormNumber(refs.modelContextWindowInput.value.trim()),
          max_tokens: utils.parseFormNumber(refs.modelMaxTokensInput.value.trim()),
          cost_input: utils.parseFormNumber(refs.modelCostInputInput.value.trim()),
          cost_output: utils.parseFormNumber(refs.modelCostOutputInput.value.trim()),
          cost_cache_read: utils.parseFormNumber(refs.modelCostCacheReadInput.value.trim()),
          cost_cache_write: utils.parseFormNumber(refs.modelCostCacheWriteInput.value.trim()),
          notes: refs.modelNotesInput.value.trim(),
        };
        const response = await fetch('/api/models/overrides', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.error || 'Could not save model override');
        state.modelsCatalog = payload.models || [];
        const refreshed = state.modelsCatalog.find((item) => utils.modelKey(item.provider, item.model_id) === utils.modelKey(body.provider, body.model_id)) || null;
        resetModelsForm(refreshed);
        renderModels();
        refs.modelProviderApiKeyInput.value = '';
        ui.setModelsFeedback(runtimeMessage(payload, 'Model saved to the shared OpenClaw catalog.'), payload.runtime && !payload.runtime.ok ? 'error' : 'success');
      } catch (error) {
        ui.setModelsFeedback(error.message || 'Could not save model.', 'error');
      }
    });
  });
})();

import { createConsumer } from "@rails/actioncable"

export class DataManageManager {
  constructor(api, modal, { onRefreshGraph }) {
    this.api = api;
    this.modal = modal;
    this.onRefreshGraph = onRefreshGraph;
    this.cable = null;
    this.exportSubscription = null;
  }

  async show() {
    let rootNodes = [];
    let orphanNodes = [];
    let projects = [];
    let duplicateRelations = { count: 0, duplicates: [] };

    try {
      [rootNodes, orphanNodes, duplicateRelations] = await Promise.all([
        this.api.fetchRootNodes(),
        this.api.fetchOrphans(),
        this.api.fetchDuplicateRelations()
      ]);
      projects = rootNodes.filter(n => n.entity_type === 'Project');
    } catch (error) {
      console.error('Error fetching data for Data Manage modal:', error);
    }

    this.modal.show('Data Manage', this.#buildContent(rootNodes, orphanNodes, projects, duplicateRelations));
    this.#bindEvents(orphanNodes, duplicateRelations);
  }

  switchTab(tab) {
    for (const key of ['export', 'import', 'cleanup']) {
      const tabEl = document.getElementById(`${key}-tab`);
      const contentEl = document.getElementById(`${key}-content`);
      if (tabEl) {
        tabEl.className = key === tab ? 'dm-tab dm-tab--active' : 'dm-tab';
      }
      if (contentEl) contentEl.style.display = key === tab ? 'block' : 'none';
    }
  }

  // --- Export ---

  async exportSelectedNodes() {
    const checkboxes = document.querySelectorAll('.export-node-checkbox:checked');
    const selectedIds = Array.from(checkboxes).map(cb => cb.value);

    if (selectedIds.length === 0) {
      alert('Please select at least one node to export.');
      return;
    }

    if (selectedIds.length < 3) {
      const params = new URLSearchParams();
      selectedIds.forEach(id => params.append('ids[]', id));
      window.location.href = `/data_exchange/export?${params.toString()}`;
      this.modal.close();
      return;
    }

    await this.#startAsyncExport(selectedIds);
  }

  async #startAsyncExport(selectedIds) {
    const progressContainer = document.getElementById('export-progress-container');
    const nodeList = document.getElementById('export-node-list');
    const exportBtn = document.getElementById('export-btn');

    if (progressContainer) progressContainer.classList.remove('graph-hidden');
    if (nodeList) nodeList.classList.add('graph-hidden');
    if (exportBtn) {
      exportBtn.disabled = true;
      exportBtn.classList.add('graph-btn--disabled');
      exportBtn.textContent = 'Exporting...';
    }

    try {
      const result = await this.api.startAsyncExport(selectedIds);
      if (!result.success) throw new Error(result.error || 'Failed to start export');
      this.#subscribeToExportProgress(result.export_id);
    } catch (error) {
      console.error('Error starting async export:', error);
      alert('Failed to start export: ' + error.message);
      this.#resetExportUI();
    }
  }

  #subscribeToExportProgress(exportId) {
    if (!this.cable) this.cable = createConsumer();

    this.exportSubscription = this.cable.subscriptions.create(
      { channel: 'ExportProgressChannel', export_id: exportId },
      {
        received: (data) => this.#handleExportProgress(data),
        connected: () => {},
        disconnected: () => {}
      }
    );
  }

  #handleExportProgress(data) {
    const progressBar = document.getElementById('export-progress-bar');
    const progressMessage = document.getElementById('export-progress-message');
    const progressPercentage = document.getElementById('export-progress-percentage');

    if (data.type === 'progress') {
      if (progressBar) progressBar.style.width = `${data.percentage}%`;
      if (progressMessage) progressMessage.textContent = data.message || 'Exporting...';
      if (progressPercentage) progressPercentage.textContent = `${Math.round(data.percentage)}%`;
    } else if (data.type === 'complete') {
      if (progressBar) progressBar.style.width = '100%';
      if (progressMessage) progressMessage.textContent = 'Export complete! Starting download...';
      if (progressPercentage) progressPercentage.textContent = '100%';
      this.#unsubscribeFromExportProgress();

      if (data.success && data.download_path) {
        setTimeout(() => {
          window.location.href = data.download_path;
          this.modal.close();
        }, 500);
      } else {
        alert('Export completed but download link not available.');
        this.#resetExportUI();
      }
    } else if (data.type === 'error') {
      this.#unsubscribeFromExportProgress();
      alert('Export failed: ' + (data.error || 'Unknown error'));
      this.#resetExportUI();
    }
  }

  #unsubscribeFromExportProgress() {
    if (this.exportSubscription) {
      this.exportSubscription.unsubscribe();
      this.exportSubscription = null;
    }
  }

  #resetExportUI() {
    const progressContainer = document.getElementById('export-progress-container');
    const nodeList = document.getElementById('export-node-list');
    const exportBtn = document.getElementById('export-btn');
    const progressBar = document.getElementById('export-progress-bar');

    if (progressContainer) progressContainer.classList.add('graph-hidden');
    if (nodeList) nodeList.classList.remove('graph-hidden');
    if (progressBar) progressBar.style.width = '0%';
    if (exportBtn) {
      exportBtn.disabled = false;
      exportBtn.classList.remove('graph-btn--disabled');
      exportBtn.textContent = 'Export Selected';
    }
  }

  // --- Import ---

  handleImportFileSelect(input) {
    const file = input.files[0];
    const fileNameDisplay = document.getElementById('selected-file-name');
    const submitBtn = document.getElementById('import-submit-btn');

    if (file) {
      fileNameDisplay.textContent = `Selected: ${file.name}`;
      fileNameDisplay.classList.remove('graph-hidden');
      submitBtn.disabled = false;
      submitBtn.classList.remove('graph-btn--disabled');
    } else {
      fileNameDisplay.classList.add('graph-hidden');
      submitBtn.disabled = true;
      submitBtn.classList.add('graph-btn--disabled');
    }
  }

  // --- Cleanup ---

  async deleteAllDuplicateRelations(count) {
    if (!confirm(`Delete ${count} duplicate relation(s)?\n\nThe older relation in each pair will be kept.`)) return;

    try {
      const result = await this.api.deleteAllDuplicateRelations();
      if (result.success) {
        this.modal.close();
        this.onRefreshGraph();
        alert(result.message || `Deleted ${result.deleted_count} duplicate relations.`);
        setTimeout(() => {
          this.show();
          setTimeout(() => this.switchTab('cleanup'), 100);
        }, 300);
      } else {
        alert('Error: ' + (result.error || 'Failed to delete duplicate relations'));
      }
    } catch (error) {
      console.error('Error deleting duplicate relations:', error);
      alert('An error occurred while deleting duplicate relations.');
    }
  }

  async moveOrphanNode(nodeId) {
    const parentSelect = document.getElementById(`parent-select-${nodeId}`);
    const parentId = parentSelect?.value;
    if (!parentId) { alert('Please select a parent project first.'); return; }
    if (!confirm('Are you sure you want to move this node under the selected parent?')) return;

    try {
      const result = await this.api.moveOrphanNode(nodeId, parentId);
      if (result.success) {
        alert(result.message);
        document.getElementById(`orphan-row-${nodeId}`)?.remove();
        this.onRefreshGraph();
      } else {
        alert('Error: ' + (result.error || 'Failed to move node'));
      }
    } catch (error) {
      console.error('Error moving node:', error);
      alert('An error occurred while moving the node.');
    }
  }

  async mergeOrphanNode(nodeId) {
    const parentSelect = document.getElementById(`parent-select-${nodeId}`);
    const targetId = parentSelect?.value;
    if (!targetId) { alert('Please select a target node to merge into first.'); return; }
    if (!confirm('Are you sure you want to merge this node into the selected target? The source node will be deleted and its data will be transferred to the target.')) return;

    try {
      const result = await this.api.mergeOrphanNode(nodeId, targetId);
      if (result.success) {
        alert(result.message);
        document.getElementById(`orphan-row-${nodeId}`)?.remove();
        this.onRefreshGraph();
      } else {
        alert('Error: ' + (result.error || 'Failed to merge node'));
      }
    } catch (error) {
      console.error('Error merging node:', error);
      alert('An error occurred while merging the node.');
    }
  }

  async deleteOrphanNode(nodeId, nodeName) {
    if (!confirm(`Are you sure you want to delete "${nodeName}" forever? This action cannot be undone.`)) return;

    try {
      const result = await this.api.deleteOrphanNode(nodeId);
      if (result.success) {
        alert(result.message);
        document.getElementById(`orphan-row-${nodeId}`)?.remove();
        this.onRefreshGraph();
      } else {
        alert('Error: ' + (result.error || 'Failed to delete node'));
      }
    } catch (error) {
      console.error('Error deleting node:', error);
      alert('An error occurred while deleting the node.');
    }
  }

  // --- DOM event binding (replaces window.graphController pattern) ---

  #bindEvents(orphanNodes, duplicateRelations) {
    for (const tab of ['export', 'import', 'cleanup']) {
      const btn = document.getElementById(`${tab}-tab`);
      if (btn) btn.onclick = () => this.switchTab(tab);
    }

    const selectAll = document.getElementById('select-all-nodes');
    if (selectAll) {
      selectAll.onchange = () => {
        document.querySelectorAll('.export-node-checkbox').forEach(cb => cb.checked = selectAll.checked);
      };
    }

    const exportBtn = document.getElementById('export-btn');
    if (exportBtn) exportBtn.onclick = () => this.exportSelectedNodes();

    const importFile = document.getElementById('import-file');
    if (importFile) importFile.onchange = () => this.handleImportFileSelect(importFile);

    document.querySelectorAll('[data-dm-action="close"]').forEach(btn => {
      btn.onclick = () => this.modal.close();
    });

    if (duplicateRelations.count > 0) {
      const delDupBtn = document.getElementById('delete-dup-relations-btn');
      if (delDupBtn) delDupBtn.onclick = () => this.deleteAllDuplicateRelations(duplicateRelations.count);
    }

    orphanNodes.forEach(orphan => {
      const moveBtn = document.getElementById(`orphan-move-${orphan.id}`);
      const mergeBtn = document.getElementById(`orphan-merge-${orphan.id}`);
      const deleteBtn = document.getElementById(`orphan-delete-${orphan.id}`);
      if (moveBtn) moveBtn.onclick = () => this.moveOrphanNode(orphan.id);
      if (mergeBtn) mergeBtn.onclick = () => this.mergeOrphanNode(orphan.id);
      if (deleteBtn) deleteBtn.onclick = () => this.deleteOrphanNode(orphan.id, orphan.name);
    });
  }

  // --- HTML builders ---

  #buildContent(rootNodes, orphanNodes, projects, duplicateRelations) {
    const esc = (t) => this.modal.escapeHtml(t);
    const csrfToken = this.api.getCSRFToken();

    return `
      <div class="dm-container">
        <div class="dm-tabs">
          <button id="export-tab" class="dm-tab dm-tab--active">Export</button>
          <button id="import-tab" class="dm-tab">Import</button>
          <button id="cleanup-tab" class="dm-tab">Clean up</button>
        </div>

        <!-- Export Tab Content -->
        <div id="export-content">
          <p class="dm-description">
            Select root nodes to export. All linked children and observations will be included.
          </p>

          <div id="export-progress-container" class="dm-progress graph-hidden">
            <div class="dm-progress__header">
              <span id="export-progress-message">Starting export...</span>
              <span id="export-progress-percentage">0%</span>
            </div>
            <div class="dm-progress__track">
              <div id="export-progress-bar" class="dm-progress__bar"></div>
            </div>
          </div>

          <div id="export-node-list" class="dm-node-list">
            ${rootNodes.length > 0 ? `
              <div class="dm-select-all">
                <label>
                  <input type="checkbox" id="select-all-nodes">
                  <strong>Select All</strong>
                </label>
              </div>
              <hr class="dm-hr">
              ${rootNodes.map(node => `
                <label class="dm-node-label">
                  <input type="checkbox" class="export-node-checkbox" value="${node.id}">
                  <span class="dm-node-label__info">
                    <strong>${esc(node.name)}</strong>
                    <span class="dm-node-label__type">(${node.entity_type || 'N/A'})</span>
                  </span>
                  <span class="dm-node-label__obs">${node.observations_count || 0} obs</span>
                </label>
              `).join('')}
            ` : '<p class="dm-empty">No root nodes found.</p>'}
          </div>

          <div class="graph-form-actions">
            <button type="button" data-dm-action="close" class="graph-btn graph-btn--lg graph-btn--secondary">
              Cancel
            </button>
            <button type="button" id="export-btn" class="graph-btn graph-btn--lg graph-btn--success">
              Export Selected
            </button>
          </div>
        </div>

        <!-- Import Tab Content -->
        <div id="import-content" style="display: none;">
          <p class="dm-description">
            Select a JSON file to import. The file should be in the graph_mem export format.
          </p>

          <form id="import-form" action="/data_exchange/import_upload" method="post" enctype="multipart/form-data">
            <input type="hidden" name="authenticity_token" value="${csrfToken}">

            <div class="dm-dropzone">
              <input type="file" id="import-file" name="file" accept=".json" class="graph-hidden">
              <label for="import-file" style="cursor: pointer;">
                <div class="dm-dropzone__icon">📁</div>
                <div class="dm-dropzone__title">Click to select a JSON file</div>
                <div class="dm-dropzone__subtitle">or drag and drop here</div>
              </label>
              <div id="selected-file-name" class="dm-selected-file graph-hidden"></div>
            </div>

            <div class="graph-form-actions">
              <button type="button" data-dm-action="close" class="graph-btn graph-btn--lg graph-btn--secondary">
                Cancel
              </button>
              <button type="submit" id="import-submit-btn" disabled
                      class="graph-btn graph-btn--lg graph-btn--primary graph-btn--disabled">
                Upload and Review
              </button>
            </div>
          </form>
        </div>

        <!-- Cleanup Tab Content -->
        <div id="cleanup-content" style="display: none;">
          ${this.#buildDuplicateRelationsSection(duplicateRelations)}

          <h4 class="dm-section-title">Orphan Nodes</h4>
          <p class="dm-description dm-section-desc">
            Manage orphan nodes: move them under a project, merge with existing nodes, or delete them.
          </p>

          <div class="dm-orphan-wrap">
            ${orphanNodes.length > 0 ? `
              <table class="dm-orphan-table">
                <thead>
                  <tr>
                    <th>Node</th>
                    <th>Suggested Parent</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  ${orphanNodes.map(orphan => this.#buildOrphanRow(orphan, projects)).join('')}
                </tbody>
              </table>
            ` : '<p class="dm-empty dm-empty--lg">No orphan nodes found. All nodes are properly organized.</p>'}
          </div>

          <div class="graph-form-actions">
            <button type="button" data-dm-action="close" class="graph-btn graph-btn--lg graph-btn--secondary">
              Close
            </button>
          </div>
        </div>
      </div>
    `;
  }

  #buildDuplicateRelationsSection(duplicateRelations) {
    const esc = (t) => this.modal.escapeHtml(t);
    const hasIssues = duplicateRelations.count > 0;

    return `
      <div class="dm-alert ${hasIssues ? 'dm-alert--warning' : 'dm-alert--success'}">
        <div class="dm-alert__header">
          <div>
            <span class="dm-alert__title">
              ${hasIssues ? '⚠️' : '✅'} Duplicate Relations
            </span>
            <p class="dm-alert__text">
              ${hasIssues
                ? `Found ${duplicateRelations.count} duplicate relation pair(s) (A→B and B→A with same type)`
                : 'No duplicate relations found'}
            </p>
          </div>
          ${hasIssues ? `
            <button id="delete-dup-relations-btn" class="graph-btn graph-btn--danger">
              Delete All Duplicates
            </button>
          ` : ''}
        </div>
        ${hasIssues && duplicateRelations.duplicates.length > 0 ? `
          <div class="dm-dup-table-wrap">
            <table class="dm-dup-table">
              <tr>
                <th>Keep (older)</th>
                <th>Delete (newer)</th>
                <th>Type</th>
              </tr>
              ${duplicateRelations.duplicates.slice(0, 10).map(d => `
                <tr>
                  <td>${esc(d.keep.from_name)} → ${esc(d.keep.to_name)}</td>
                  <td>${esc(d.delete.from_name)} → ${esc(d.delete.to_name)}</td>
                  <td>${d.relation_type}</td>
                </tr>
              `).join('')}
              ${duplicateRelations.duplicates.length > 10 ? `
                <tr><td colspan="3" class="dm-dup-table__more">...and ${duplicateRelations.duplicates.length - 10} more</td></tr>
              ` : ''}
            </table>
          </div>
        ` : ''}
      </div>
    `;
  }

  #buildOrphanRow(orphan, projects) {
    const esc = (t) => this.modal.escapeHtml(t);

    return `
      <tr id="orphan-row-${orphan.id}">
        <td>
          <div class="dm-orphan-name">${esc(orphan.name)}</div>
          <div class="dm-orphan-meta">
            (${orphan.entity_type}) - ${orphan.observations_count || 0} obs, ${orphan.children_count || 0} children
          </div>
        </td>
        <td>
          <select id="parent-select-${orphan.id}" class="dm-orphan-select">
            <option value="">-- Select parent --</option>
            ${orphan.suggested_parents && orphan.suggested_parents.length > 0 ?
              orphan.suggested_parents.map(p => `
                <option value="${p.id}" ${orphan.suggested_parents[0].id === p.id ? 'selected' : ''}>
                  ${esc(p.name)} (score: ${p.score})
                </option>
              `).join('') : ''}
            <optgroup label="All Projects">
              ${projects.filter(p => !orphan.suggested_parents?.find(sp => sp.id === p.id)).map(p => `
                <option value="${p.id}">${esc(p.name)}</option>
              `).join('')}
            </optgroup>
          </select>
        </td>
        <td class="dm-orphan-actions">
          <button id="orphan-move-${orphan.id}" title="Move to selected parent"
                  class="dm-orphan-btn dm-orphan-btn--move">Move</button><button id="orphan-merge-${orphan.id}" title="Merge into selected parent"
                  class="dm-orphan-btn dm-orphan-btn--merge">Merge</button><button id="orphan-delete-${orphan.id}" title="Delete this node"
                  class="dm-orphan-btn dm-orphan-btn--delete"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg></button>
        </td>
      </tr>
    `;
  }
}

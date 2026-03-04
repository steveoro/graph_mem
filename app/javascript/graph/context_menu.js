const RELATION_TYPES = [
  'part_of', 'depends_on', 'relates_to', 'implements', 'extends',
  'solves', 'configured_by', 'tested_by', 'migrated_by',
  'authorizes', 'integrates_with', 'replaces'
];

export class ContextMenuManager {
  constructor(api, modal, { onRefreshGraph }) {
    this.api = api;
    this.modal = modal;
    this.onRefreshGraph = onRefreshGraph;
    this.currentMenu = null;
  }

  showNodeMenu(event, cy) {
    const node = event.target;
    const data = node.data();
    const position = event.renderedPosition || event.position;

    this.hide();

    const menu = document.createElement('div');
    menu.className = 'contextual-menu';

    const aliases = data.aliases ? data.aliases.trim() : '';
    const menuItems = [
      { text: `<strong>${data.label}</strong>`, divider: true },
      { text: `ID: ${data.id}` },
      { text: `Type: ${data.type || 'N/A'}` },
      ...(aliases ? [{ text: `Aliases: ${aliases}` }] : []),
      { text: `Observations: ${data.memory_observations_count || 0}`, action: 'show-observations' },
      { divider: true },
      { text: 'Edit data', action: 'edit' },
      { text: 'Toggle relations', action: 'toggle-relations' },
      { text: 'Toggle observations', action: 'toggle-observations' },
      { text: 'Delete', action: 'delete', danger: true }
    ];

    menuItems.forEach(item => {
      const el = document.createElement('div');
      if (item.divider) {
        el.className = 'ctx-divider';
        if (item.text) {
          el.innerHTML = item.text;
          el.className = 'ctx-header';
        }
      } else {
        el.innerHTML = item.text;
        el.className = 'ctx-item' +
          (item.action ? ' ctx-item--clickable' : '') +
          (item.danger ? ' ctx-item--danger' : '');
        if (item.action) {
          el.onclick = (e) => {
            e.stopPropagation();
            this.#handleNodeAction(item.action, data, cy);
            this.hide();
          };
        }
      }
      menu.appendChild(el);
    });

    const containerRect = cy.container().getBoundingClientRect();
    menu.style.left = (containerRect.left + position.x) + 'px';
    menu.style.top = (containerRect.top + position.y) + 'px';

    document.body.appendChild(menu);
    this.currentMenu = menu;
  }

  showEdgeMenu(event, cy) {
    const edge = event.target;
    const data = edge.data();
    const position = event.renderedPosition || event.position;

    this.hide();

    const menu = document.createElement('div');
    menu.className = 'contextual-menu edge-menu';

    const fromName = data.from_entity_name || data.source;
    const toName = data.to_entity_name || data.target;

    const menuItems = [
      { text: `<strong>Relation</strong>`, divider: true, edge: true },
      { text: `${fromName} → ${toName}` },
      { text: `Type: ${data.label}` },
      { divider: true },
      { text: 'Edit Type', action: 'edit-type' },
      { text: 'Delete Relation', action: 'delete', danger: true }
    ];

    menuItems.forEach(item => {
      const el = document.createElement('div');
      if (item.divider && !item.text) {
        el.className = 'ctx-divider';
      } else if (item.divider) {
        el.innerHTML = item.text;
        el.className = 'ctx-header' + (item.edge ? ' ctx-header--edge' : '');
      } else {
        el.innerHTML = item.text;
        el.className = 'ctx-item' +
          (item.action ? ' ctx-item--clickable' : '') +
          (item.danger ? ' ctx-item--danger' : '');
        if (item.action) {
          el.onclick = (e) => {
            e.stopPropagation();
            this.#handleEdgeAction(item.action, data, edge);
            this.hide();
          };
        }
      }
      menu.appendChild(el);
    });

    const containerRect = cy.container().getBoundingClientRect();
    menu.style.left = (containerRect.left + position.x) + 'px';
    menu.style.top = (containerRect.top + position.y) + 'px';

    document.body.appendChild(menu);
    this.currentMenu = menu;
  }

  hide() {
    if (this.currentMenu) {
      this.currentMenu.remove();
      this.currentMenu = null;
    }
  }

  // --- Node actions ---

  async #handleNodeAction(action, nodeData, cy) {
    switch (action) {
      case 'show-observations':
        await this.#showObservationsModal(nodeData, cy);
        break;
      case 'edit':
        this.#showEditModal(nodeData);
        break;
      case 'toggle-relations':
        this.#toggleNodeRelations(nodeData.id, cy);
        break;
      case 'toggle-observations':
        if (nodeData.memory_observations_count > 10) {
          if (!confirm(`This entity has ${nodeData.memory_observations_count} observations. Show them all?`)) return;
        }
        await this.#showObservationsModal(nodeData, cy);
        break;
      case 'delete':
        await this.#deleteNode(nodeData, cy);
        break;
    }
  }

  async #showObservationsModal(nodeData, cy) {
    try {
      const observations = await this.api.fetchObservations(nodeData.id);

      const contentCounts = {};
      observations.forEach(obs => {
        contentCounts[obs.content] = (contentCounts[obs.content] || 0) + 1;
      });
      const hasDuplicates = Object.values(contentCounts).some(count => count > 1);
      const duplicateCount = Object.values(contentCounts).reduce((sum, count) => sum + (count > 1 ? count - 1 : 0), 0);

      this.modal.show('Entity Observations', `
        <h3>${nodeData.label} (ID: ${nodeData.id})</h3>
        <p><strong>Type:</strong> ${nodeData.type || 'N/A'}</p>
        <p><strong>Total Observations:</strong> ${observations.length}</p>
        ${hasDuplicates ? `
          <div class="obs-warning-box">
            <p><strong>Found ${duplicateCount} duplicate observation(s)</strong></p>
            <button id="delete-dup-obs-btn" class="graph-btn graph-btn--danger">
              Delete All Duplicates
            </button>
          </div>
        ` : ''}
        <hr>
        ${observations.length > 0 ?
          observations
            .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
            .map(obs => {
              const isDuplicate = contentCounts[obs.content] > 1;
              return `
                <div class="obs-card ${isDuplicate ? 'obs-card--duplicate' : ''}">
                  <div class="obs-card__date">
                    ${new Date(obs.created_at).toLocaleString()}
                    ${isDuplicate ? '<span class="obs-card__dup-badge">[DUPLICATE]</span>' : ''}
                  </div>
                  <div>${obs.content}</div>
                </div>
              `;
            }).join('')
          : '<p>No observations found.</p>'
        }
      `);

      if (hasDuplicates) {
        const btn = document.getElementById('delete-dup-obs-btn');
        if (btn) btn.onclick = () => this.#deleteDuplicateObservations(nodeData.id, cy);
      }
    } catch (error) {
      console.error('Error fetching observations:', error);
      alert('Failed to load observations.');
    }
  }

  async #deleteDuplicateObservations(entityId, cy) {
    if (!confirm(
      'Are you sure you want to delete all duplicate observations? This action cannot be undone.\n\n' +
      'Duplicate observations (with identical content) will be removed, keeping only the oldest one of each.'
    )) return;

    try {
      const result = await this.api.deleteDuplicateObservations(entityId);
      alert(`Success! ${result.message}`);
      this.modal.close();
      this.onRefreshGraph();

      const nodeData = cy.getElementById(entityId.toString()).data();
      if (nodeData) {
        setTimeout(() => this.#showObservationsModal(nodeData, cy), 500);
      }
    } catch (error) {
      console.error('Error deleting duplicate observations:', error);
      alert('An error occurred while deleting duplicate observations.');
    }
  }

  #showEditModal(nodeData) {
    const aliases = nodeData.aliases ? nodeData.aliases.trim() : '';
    this.modal.show('Edit Entity', `
      <h3>Edit Entity</h3>
      <form id="edit-entity-form">
        <div class="graph-form-group">
          <label class="graph-form-label">Name:</label>
          <input type="text" id="entity-name" value="${nodeData.label}" class="graph-form-input">
        </div>
        <div class="graph-form-group">
          <label class="graph-form-label">Type:</label>
          <input type="text" id="entity-type" value="${nodeData.type || ''}" class="graph-form-input">
        </div>
        <div class="graph-form-group--lg">
          <label class="graph-form-label">Aliases:</label>
          <input type="text" id="entity-aliases" value="${aliases}"
                 placeholder="Comma-separated alternative names" class="graph-form-input">
          <small class="graph-form-hint">Enter alternative names separated by commas</small>
        </div>
        <div class="graph-form-actions">
          <button type="button" id="edit-cancel-btn" class="graph-btn graph-btn--secondary">Cancel</button>
          <button type="submit" class="graph-btn graph-btn--primary">Save</button>
        </div>
      </form>
    `);

    document.getElementById('edit-cancel-btn').onclick = () => this.modal.close();
    document.getElementById('edit-entity-form').onsubmit = async (e) => {
      e.preventDefault();
      const name = document.getElementById('entity-name').value.trim();
      const type = document.getElementById('entity-type').value.trim();
      const aliasesVal = document.getElementById('entity-aliases').value.trim();

      if (!name) { alert('Name is required.'); return; }

      try {
        await this.api.updateEntity(nodeData.id, { name, entity_type: type, aliases: aliasesVal });
        this.modal.close();
        this.onRefreshGraph();
        alert('Entity updated successfully.');
      } catch (error) {
        console.error('Error updating entity:', error);
        alert(`Failed to update entity: ${error.message}`);
      }
    };
  }

  #toggleNodeRelations(nodeId, cy) {
    const node = cy.$id(nodeId);
    const connectedEdges = node.connectedEdges();
    const connectedNodes = node.neighborhood().nodes();

    if (connectedEdges.hasClass('hidden-relation')) {
      connectedEdges.removeClass('hidden-relation').show();
      connectedNodes.removeClass('hidden-relation').show();
    } else {
      connectedEdges.addClass('hidden-relation').hide();
      connectedNodes.addClass('hidden-relation').hide();
    }
  }

  async #deleteNode(nodeData, cy) {
    if (!confirm(`Are you sure you want to delete "${nodeData.label}"? This action cannot be undone.`)) return;

    try {
      await this.api.deleteEntity(nodeData.id);
      cy.$id(nodeData.id).remove();
      alert('Entity deleted successfully.');
    } catch (error) {
      console.error('Error deleting entity:', error);
      alert(`Failed to delete entity: ${error.message}`);
    }
  }

  // --- Edge actions ---

  async #handleEdgeAction(action, edgeData, edge) {
    switch (action) {
      case 'edit-type':
        this.#showEditRelationTypeModal(edgeData);
        break;
      case 'delete':
        await this.#deleteRelation(edgeData, edge);
        break;
    }
  }

  #showEditRelationTypeModal(edgeData) {
    const currentType = edgeData.label;
    const fromName = edgeData.from_entity_name || edgeData.source;
    const toName = edgeData.to_entity_name || edgeData.target;

    const optionsHtml = RELATION_TYPES.map(type =>
      `<option value="${type}" ${type === currentType ? 'selected' : ''}>${type}</option>`
    ).join('');

    this.modal.show('Edit Relation Type', `
      <div class="relation-info--spaced">
        <p><strong>From:</strong> ${fromName}</p>
        <p><strong>To:</strong> ${toName}</p>
      </div>
      <div class="graph-form-group--lg">
        <label for="relation-type-select" class="graph-form-label--bold">Relation Type:</label>
        <select id="relation-type-select" class="graph-form-select">
          ${optionsHtml}
        </select>
      </div>
      <div class="graph-form-actions--flex">
        <button id="rel-cancel-btn" class="graph-btn graph-btn--lg graph-btn--outline">Cancel</button>
        <button id="rel-save-btn" class="graph-btn graph-btn--lg graph-btn--primary">Save</button>
      </div>
    `);

    document.getElementById('rel-cancel-btn').onclick = () => this.modal.close();
    document.getElementById('rel-save-btn').onclick = async () => {
      const select = document.getElementById('relation-type-select');
      if (!select) return;

      try {
        const result = await this.api.updateRelationType(edgeData.relation_id, select.value);
        if (result.success) {
          this.modal.close();
          this.onRefreshGraph();
          alert('Relation type updated successfully.');
        } else {
          alert('Error: ' + (result.error || 'Failed to update relation type'));
        }
      } catch (error) {
        console.error('Error updating relation type:', error);
        alert('An error occurred while updating the relation type.');
      }
    };
  }

  async #deleteRelation(edgeData, edge) {
    const fromName = edgeData.from_entity_name || edgeData.source;
    const toName = edgeData.to_entity_name || edgeData.target;

    if (!confirm(`Delete relation "${fromName} -[${edgeData.label}]-> ${toName}"?`)) return;

    try {
      const result = await this.api.deleteRelation(edgeData.relation_id);
      if (result.success) {
        edge.remove();
        alert(result.message || 'Relation deleted successfully.');
      } else {
        alert('Error: ' + (result.error || 'Failed to delete relation'));
      }
    } catch (error) {
      console.error('Error deleting relation:', error);
      alert('An error occurred while deleting the relation.');
    }
  }
}

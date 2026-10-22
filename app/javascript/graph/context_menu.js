import { el, text, br } from 'lib/dom';
import { analyzeObservations, renderDuplicateWarning, renderObservationCards } from 'graph/observation_renderer';

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
      { header: String(data.label ?? ''), divider: true },
      { label: 'ID: ' + (data.id ?? '') },
      { label: 'Type: ' + (data.type || 'N/A') },
      ...(aliases ? [{ label: 'Aliases: ' + aliases }] : []),
      { label: 'Observations: ' + (data.memory_observations_count || 0), action: 'show-observations' },
      { divider: true },
      { label: 'Edit data', action: 'edit' },
      { label: 'Toggle relations', action: 'toggle-relations' },
      { label: 'Toggle observations', action: 'toggle-observations' },
      { label: 'Delete', action: 'delete', danger: true }
    ];

    menuItems.forEach(item => {
      const itemEl = document.createElement('div');
      if (item.divider && !item.header) {
        itemEl.className = 'ctx-divider';
      } else if (item.header !== undefined) {
        const strong = document.createElement('strong');
        strong.textContent = item.header;
        itemEl.appendChild(strong);
        itemEl.className = 'ctx-header';
      } else {
        itemEl.textContent = item.label;
        itemEl.className = 'ctx-item' +
          (item.action ? ' ctx-item--clickable' : '') +
          (item.danger ? ' ctx-item--danger' : '');
        if (item.action) {
          itemEl.onclick = (e) => {
            e.stopPropagation();
            this.#handleNodeAction(item.action, data, cy);
            this.hide();
          };
        }
      }
      menu.appendChild(itemEl);
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

    const fromName = String(data.from_entity_name || data.source || '');
    const toName = String(data.to_entity_name || data.target || '');

    const menuItems = [
      { staticHeader: 'Relation', divider: true, edge: true },
      { label: fromName + ' \u2192 ' + toName },
      { label: 'Type: ' + (data.label || '') },
      { divider: true },
      { label: 'Edit Type', action: 'edit-type' },
      { label: 'Delete Relation', action: 'delete', danger: true }
    ];

    menuItems.forEach(item => {
      const itemEl = document.createElement('div');
      if (item.divider && !item.staticHeader) {
        itemEl.className = 'ctx-divider';
      } else if (item.staticHeader !== undefined) {
        const strong = document.createElement('strong');
        strong.textContent = item.staticHeader;
        itemEl.appendChild(strong);
        itemEl.className = 'ctx-header' + (item.edge ? ' ctx-header--edge' : '');
      } else {
        itemEl.textContent = item.label;
        itemEl.className = 'ctx-item' +
          (item.action ? ' ctx-item--clickable' : '') +
          (item.danger ? ' ctx-item--danger' : '');
        if (item.action) {
          itemEl.onclick = (e) => {
            e.stopPropagation();
            this.#handleEdgeAction(item.action, data, edge);
            this.hide();
          };
        }
      }
      menu.appendChild(itemEl);
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
          if (!confirm('This entity has ' + nodeData.memory_observations_count + ' observations. Show them all?')) return;
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
      const analysis = analyzeObservations(observations);

      const frag = document.createDocumentFragment();

      frag.appendChild(el('h3', {},
        text(String(nodeData.label ?? '') + ' (ID: ' + (nodeData.id ?? '') + ')')));
      frag.appendChild(el('p', {},
        el('strong', {}, 'Type:'), text(' ' + (nodeData.type || 'N/A'))));
      frag.appendChild(el('p', {},
        el('strong', {}, 'Total Observations:'), text(' ' + observations.length)));

      const warning = renderDuplicateWarning(analysis);
      if (warning) frag.appendChild(warning);

      frag.appendChild(document.createElement('hr'));
      frag.appendChild(renderObservationCards(observations, analysis));

      this.modal.show('Entity Observations', frag);

      if (analysis.hasDuplicates) {
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
      alert('Success! ' + result.message);
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

    const nameInput = el('input', {
      type: 'text', id: 'entity-name', className: 'graph-form-input', value: String(nodeData.label ?? '')
    });
    const typeInput = el('input', {
      type: 'text', id: 'entity-type', className: 'graph-form-input', value: String(nodeData.type || '')
    });
    const aliasesInput = el('input', {
      type: 'text', id: 'entity-aliases', className: 'graph-form-input',
      placeholder: 'Comma-separated alternative names', value: aliases
    });

    const form = el('form', { id: 'edit-entity-form' },
      el('h3', {}, 'Edit Entity'),
      el('div', { className: 'graph-form-group' },
        el('label', { className: 'graph-form-label' }, 'Name:'),
        nameInput
      ),
      el('div', { className: 'graph-form-group' },
        el('label', { className: 'graph-form-label' }, 'Type:'),
        typeInput
      ),
      el('div', { className: 'graph-form-group--lg' },
        el('label', { className: 'graph-form-label' }, 'Aliases:'),
        aliasesInput,
        el('small', { className: 'graph-form-hint' }, 'Enter alternative names separated by commas')
      ),
      el('div', { className: 'graph-form-actions' },
        el('button', { type: 'button', id: 'edit-cancel-btn', className: 'graph-btn graph-btn--secondary' }, 'Cancel'),
        el('button', { type: 'submit', className: 'graph-btn graph-btn--primary' }, 'Save')
      )
    );

    this.modal.show('Edit Entity', form);

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
        alert('Failed to update entity: ' + error.message);
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
    if (!confirm('Are you sure you want to delete "' + (nodeData.label ?? '') + '"? This action cannot be undone.')) return;

    try {
      await this.api.deleteEntity(nodeData.id);
      cy.$id(nodeData.id).remove();
      alert('Entity deleted successfully.');
    } catch (error) {
      console.error('Error deleting entity:', error);
      alert('Failed to delete entity: ' + error.message);
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
    const fromName = String(edgeData.from_entity_name || edgeData.source || '');
    const toName = String(edgeData.to_entity_name || edgeData.target || '');

    const options = RELATION_TYPES.map(type => {
      const opt = el('option', { value: type }, type);
      if (type === currentType) opt.selected = true;
      return opt;
    });

    const select = el('select', { id: 'relation-type-select', className: 'graph-form-select' }, ...options);

    const frag = document.createDocumentFragment();
    frag.appendChild(
      el('div', { className: 'relation-info--spaced' },
        el('p', {}, el('strong', {}, 'From:'), text(' ' + fromName)),
        el('p', {}, el('strong', {}, 'To:'), text(' ' + toName))
      )
    );
    frag.appendChild(
      el('div', { className: 'graph-form-group--lg' },
        el('label', { htmlFor: 'relation-type-select', className: 'graph-form-label--bold' }, 'Relation Type:'),
        select
      )
    );
    frag.appendChild(
      el('div', { className: 'graph-form-actions--flex' },
        el('button', { id: 'rel-cancel-btn', className: 'graph-btn graph-btn--lg graph-btn--outline' }, 'Cancel'),
        el('button', { id: 'rel-save-btn', className: 'graph-btn graph-btn--lg graph-btn--primary' }, 'Save')
      )
    );

    this.modal.show('Edit Relation Type', frag);

    document.getElementById('rel-cancel-btn').onclick = () => this.modal.close();
    document.getElementById('rel-save-btn').onclick = async () => {
      const selectEl = document.getElementById('relation-type-select');
      if (!selectEl) return;

      try {
        const result = await this.api.updateRelationType(edgeData.relation_id, selectEl.value);
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
    const fromName = String(edgeData.from_entity_name || edgeData.source || '');
    const toName = String(edgeData.to_entity_name || edgeData.target || '');

    if (!confirm('Delete relation "' + fromName + ' -[' + (edgeData.label || '') + ']-> ' + toName + '"?')) return;

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

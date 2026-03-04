export class DragDropManager {
  constructor(api, modal, { onRefreshGraph }) {
    this.api = api;
    this.modal = modal;
    this.onRefreshGraph = onRefreshGraph;
    this.currentMenu = null;
    this.currentCloseHandler = null;
  }

  initialize(cy, containerTarget) {
    this.cy = cy;
    this.containerTarget = containerTarget;

    cy.on('grab', 'node', (event) => {
      const node = event.target;
      node.data('originalPosition', { x: node.position('x'), y: node.position('y') });
    });

    cy.on('free', 'node', (event) => this.#handleNodeDrop(event));

    cy.on('dragover', 'node', (event) => {
      event.target.addClass('potential-drop-target');
    });

    cy.on('dragout', 'node', (event) => {
      event.target.removeClass('potential-drop-target');
    });
  }

  hideMenu() {
    if (this.currentMenu) {
      this.currentMenu.remove();
      this.currentMenu = null;
    }
  }

  #handleNodeDrop(event) {
    const draggedNode = event.target;
    let targetFound = null;

    this.cy.nodes().not(draggedNode).forEach((potentialTarget) => {
      if (targetFound) return;

      const targetBB = potentialTarget.renderedBoundingBox();
      const draggedBB = draggedNode.renderedBoundingBox();

      const isOverlapping = (
        draggedBB.x1 < targetBB.x2 &&
        draggedBB.x2 > targetBB.x1 &&
        draggedBB.y1 < targetBB.y2 &&
        draggedBB.y2 > targetBB.y1
      );

      if (isOverlapping) targetFound = potentialTarget;
    });

    if (!targetFound) return;

    const sourceId = draggedNode.id();
    const targetId = targetFound.id();
    const dropPosition = event.renderedPosition || event.position || targetFound.renderedPosition() || {
      x: window.innerWidth / 2, y: window.innerHeight / 2
    };

    this.#showActionMenu({
      sourceId,
      targetId,
      sourceName: draggedNode.data('label') || sourceId,
      targetName: targetFound.data('label') || targetId,
      sourceType: draggedNode.data('type'),
      targetType: targetFound.data('type'),
      draggedNode,
      targetNode: targetFound,
      dropPosition
    });
  }

  #showActionMenu(actionData) {
    const { sourceName, targetName, sourceType, targetType, draggedNode, dropPosition } = actionData;

    this.hideMenu();

    const menu = document.createElement('div');
    menu.className = 'node-action-menu';

    const header = document.createElement('div');
    header.className = 'node-action-menu__header';
    header.innerHTML = `
      <div class="node-action-menu__title">Node-to-Node Action</div>
      <div class="node-action-menu__subtitle">"${sourceName}" → "${targetName}"</div>
    `;
    menu.appendChild(header);

    const typesMatch = (sourceType === targetType) ||
                      (!sourceType && !targetType) ||
                      (sourceType === null && targetType === null);

    const actions = [
      {
        text: 'Merge Nodes',
        description: 'Merge source into target (preserves target name as alias)',
        action: 'merge',
        enabled: typesMatch,
        icon: '🔗',
        disabledReason: typesMatch ? null : `Cannot merge different types: "${sourceType || 'N/A'}" ≠ "${targetType || 'N/A'}"`
      },
      {
        text: 'Create Relation',
        description: 'Create a relationship between the nodes',
        action: 'create-relation',
        enabled: true,
        icon: '→'
      },
      {
        text: 'Cancel',
        description: 'Return source node to original position',
        action: 'cancel',
        enabled: true,
        icon: '✕',
        cancel: true
      }
    ];

    actions.forEach(actionItem => {
      const el = document.createElement('div');
      const isEnabled = actionItem.enabled;
      const isCancel = actionItem.cancel;

      el.className = 'node-action-menu__item' +
        (!isEnabled ? ' node-action-menu__item--disabled' : '') +
        (isCancel ? ' node-action-menu__item--cancel' : '');

      el.innerHTML = `
        <div class="node-action-menu__item-row">
          <span class="node-action-menu__icon">${actionItem.icon}</span>
          <span class="node-action-menu__item-name">${actionItem.text}</span>
        </div>
        <div class="node-action-menu__desc">
          ${actionItem.disabledReason || actionItem.description}
        </div>
      `;

      if (isEnabled) {
        el.onclick = async (e) => {
          if (this.currentCloseHandler) {
            document.removeEventListener('click', this.currentCloseHandler);
            this.currentCloseHandler = null;
          }

          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          this.hideMenu();

          if (actionItem.action === 'merge') {
            const confirmMessage = `Do you really want to merge these two nodes and their subgraphs into a single one?\n\nSource: "${sourceName}" (type: ${sourceType || 'N/A'})\nTarget: "${targetName}" (type: ${targetType || 'N/A'})`;
            if (confirm(confirmMessage)) {
              this.#mergeEntities(actionData).catch(err => console.error('Error in merge:', err));
            } else {
              draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
            }
          } else if (actionItem.action === 'create-relation') {
            this.#showCreateRelationModal(actionData);
          } else if (actionItem.action === 'cancel') {
            draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
          }

          return false;
        };
      }

      menu.appendChild(el);
    });

    const containerRect = this.containerTarget.getBoundingClientRect();
    const menuX = Math.min(containerRect.left + dropPosition.x + 10, window.innerWidth - 240);
    const menuY = Math.min(containerRect.top + dropPosition.y - 10, window.innerHeight - 200);
    menu.style.left = menuX + 'px';
    menu.style.top = menuY + 'px';

    document.body.appendChild(menu);
    this.currentMenu = menu;

    const closeHandler = (e) => {
      if (!menu.contains(e.target)) {
        this.hideMenu();
        document.removeEventListener('click', closeHandler);
        this.currentCloseHandler = null;
      }
    };
    this.currentCloseHandler = closeHandler;
    setTimeout(() => document.addEventListener('click', closeHandler), 100);
  }

  async #mergeEntities({ sourceId, targetId, targetName, draggedNode }) {
    try {
      if (targetName) {
        await this.api.addTargetNameAsAlias(sourceId, targetName);
      }

      await this.api.mergeEntities(sourceId, targetId);

      if (this.cy) {
        const sourceNode = this.cy.$id(sourceId);
        if (sourceNode.length > 0) this.cy.remove(sourceNode);
      }
      alert(`'${sourceId}' merged into '${targetId}'.`);
    } catch (error) {
      console.error('Error during merge:', error);
      alert(`Failed to merge: ${error.message}`);
    }
  }

  #showCreateRelationModal({ sourceId, targetId, sourceName, targetName }) {
    this.modal.show('Create Relation', `
      <h3>Create Relation</h3>
      <p>Create a relationship between:</p>
      <div class="relation-info">
        <strong>"${sourceName}"</strong> → <strong>"${targetName}"</strong>
      </div>
      <form id="create-relation-form">
        <div class="graph-form-group--lg">
          <label class="graph-form-label">Relation Type:</label>
          <input type="text" id="relation-type" placeholder="e.g., depends_on, relates_to, part_of"
                 class="graph-form-input">
          <small class="graph-form-hint">Describe how the first node relates to the second</small>
        </div>
        <div class="graph-form-actions">
          <button type="button" id="create-rel-cancel-btn" class="graph-btn graph-btn--secondary">Cancel</button>
          <button type="submit" class="graph-btn graph-btn--primary">Create Relation</button>
        </div>
      </form>
    `);

    document.getElementById('create-rel-cancel-btn').onclick = () => this.modal.close();
    document.getElementById('create-relation-form').onsubmit = async (e) => {
      e.preventDefault();
      const relationType = document.getElementById('relation-type').value.trim();
      if (!relationType) { alert('Relation type is required.'); return; }

      try {
        await this.api.createRelation(sourceId, targetId, relationType);
        this.modal.close();
        this.onRefreshGraph();
        alert('Relation created successfully.');
      } catch (error) {
        console.error('Error creating relation:', error);
        alert(`Failed to create relation: ${error.message}`);
      }
    };
  }
}

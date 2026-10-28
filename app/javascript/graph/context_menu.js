// The canvas's right-click menus (UI-4b). Every label is set with textContent. Read items only
// for now: Show in panel, Open neighbourhood, Toggle relations (edges: the endpoints).
export class ContextMenuManager {
  // actions: { select(id), openNeighbourhood(id) }
  constructor(actions, { readOnly = true } = {}) {
    this.actions = actions;
    this.readOnly = readOnly;
    this.currentMenu = null;
  }

  showNodeMenu(event, cy) {
    const data = event.target.data();
    const items = [
      { header: String(data.label ?? '') },
      { label: 'Type: ' + (data.type || 'N/A') },
      { label: 'Observations: ' + (data.memory_observations_count || 0) },
      { divider: true },
      { label: 'Show in panel', testid: 'ctx-show', run: () => this.actions.select(data.id) },
      { label: 'Open neighbourhood', testid: 'ctx-neighbourhood', run: () => this.actions.openNeighbourhood(data.id) },
      { label: 'Toggle relations', testid: 'ctx-toggle-relations', run: () => this.#toggleRelations(cy, data.id) }
    ];
    this.#show(event, cy, 'contextual-menu', items);
  }

  showEdgeMenu(event, cy) {
    const data = event.target.data();
    const items = [
      { header: 'Relation', edge: true },
      { label: String(data.from_entity_name || data.source || '') + ' → ' + String(data.to_entity_name || data.target || '') },
      { label: 'Type: ' + (data.label || '') }
    ];
    this.#show(event, cy, 'contextual-menu edge-menu', items);
  }

  hide() {
    this.currentMenu?.remove();
    this.currentMenu = null;
  }

  #show(event, cy, className, items) {
    this.hide();
    const position = event.renderedPosition || event.position;
    const menu = document.createElement('div');
    menu.className = className;
    menu.dataset.testid = 'explore-context-menu';
    menu.setAttribute('role', 'menu');

    items.forEach((item) => menu.appendChild(this.#item(item)));

    const rect = cy.container().getBoundingClientRect();
    menu.style.left = (rect.left + window.scrollX + position.x) + 'px';
    menu.style.top = (rect.top + window.scrollY + position.y) + 'px';
    document.body.appendChild(menu);
    this.currentMenu = menu;
  }

  #item(item) {
    const itemEl = document.createElement('div');
    if (item.divider) {
      itemEl.className = 'ctx-divider';
    } else if (item.header !== undefined) {
      const strong = document.createElement('strong');
      strong.textContent = item.header;
      itemEl.appendChild(strong);
      itemEl.className = 'ctx-header' + (item.edge ? ' ctx-header--edge' : '');
    } else {
      itemEl.textContent = item.label;
      itemEl.className = 'ctx-item' + (item.run ? ' ctx-item--clickable' : '') + (item.danger ? ' ctx-item--danger' : '');
      if (item.testid) itemEl.dataset.testid = item.testid;
      if (item.run) {
        itemEl.setAttribute('role', 'menuitem');
        itemEl.addEventListener('click', (e) => {
          e.stopPropagation();
          this.hide();
          item.run();
        });
      }
    }
    return itemEl;
  }

  #toggleRelations(cy, nodeId) {
    const node = cy.$id(String(nodeId));
    const edges = node.connectedEdges();
    const hidden = edges.hasClass('hidden-relation');
    edges.toggleClass('hidden-relation', !hidden).style('display', hidden ? 'element' : 'none');
  }
}

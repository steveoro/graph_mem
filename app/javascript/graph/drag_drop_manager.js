import { el, text } from 'lib/dom';

// Drop a node on another (UI-4b W7, operator only): a menu with Add relation…, Move under… (not
// for a project root) and Merge A into B… (same type only, neither a project root). Each item
// opens its server-rendered dialog through `actions`; nothing is written from here. Cancel (or
// a click elsewhere) puts the node back. Every label is set as text.
export class DragDropManager {
  // actions: { addRelation(fromId, toId), move(nodeId, parentId), merge(sourceId, targetId) }
  constructor(actions) {
    this.actions = actions;
    this.currentMenu = null;
    this.closeHandler = null;
  }

  initialize(cy, container) {
    this.cy = cy;
    this.container = container;
    cy.on('grab', 'node', (event) => {
      const node = event.target;
      node.scratch('_explore_origin', { ...node.position() });
    });
    cy.on('free', 'node', (event) => this.handleDrop(event.target));
  }

  // Exposed for the system specs, which can't drag reliably headless.
  handleDrop(dragged) {
    const target = this.#overlapping(dragged);
    if (target) this.showMenu(dragged, target);
  }

  showMenu(dragged, target) {
    this.hideMenu();
    const source = dragged.data();
    const other = target.data();
    const sourceRoot = source.type === 'Project';
    const sameType = source.type === other.type && !sourceRoot && other.type !== 'Project';

    const items = [
      { label: 'Add relation…', testid: 'drop-add-relation', run: () => this.actions.addRelation(source.id, other.id) }
    ];
    if (!sourceRoot) {
      items.push({ label: 'Move under “' + String(other.label ?? '') + '”…', testid: 'drop-move', run: () => this.actions.move(source.id, other.id) });
    }
    if (sameType) {
      items.push({ label: 'Merge “' + String(source.label ?? '') + '” into “' + String(other.label ?? '') + '”…', testid: 'drop-merge', run: () => this.actions.merge(source.id, other.id) });
    }
    items.push({ label: 'Cancel', testid: 'drop-cancel', cancel: true, run: () => this.#restore(dragged) });

    const menu = el('div', { className: 'node-action-menu', role: 'menu', 'data-testid': 'explore-drop-menu' },
      el('div', { className: 'node-action-menu__header' },
        el('div', { className: 'node-action-menu__title' }, 'Node-to-node action'),
        el('div', { className: 'node-action-menu__subtitle' },
          text('“' + String(source.label ?? '') + '” → “' + String(other.label ?? '') + '”'))
      )
    );
    items.forEach((item) => {
      const row = el('div', {
        className: 'node-action-menu__item' + (item.cancel ? ' node-action-menu__item--cancel' : ''),
        role: 'menuitem', 'data-testid': item.testid
      }, el('span', { className: 'node-action-menu__item-name' }, item.label));
      row.addEventListener('click', (event) => {
        event.stopPropagation();
        this.hideMenu();
        if (!item.cancel) this.#restore(dragged);
        item.run();
      });
      menu.appendChild(row);
    });

    const rect = this.container.getBoundingClientRect();
    const position = target.renderedPosition();
    menu.style.left = Math.min(rect.left + window.scrollX + position.x + 10, window.scrollX + window.innerWidth - 260) + 'px';
    menu.style.top = (rect.top + window.scrollY + position.y - 10) + 'px';
    document.body.appendChild(menu);
    this.currentMenu = menu;

    this.closeHandler = (event) => {
      if (menu.contains(event.target)) return;
      this.hideMenu();
      this.#restore(dragged);
    };
    setTimeout(() => this.closeHandler && document.addEventListener('click', this.closeHandler), 100);
  }

  hideMenu() {
    if (this.closeHandler) document.removeEventListener('click', this.closeHandler);
    this.closeHandler = null;
    this.currentMenu?.remove();
    this.currentMenu = null;
  }

  #overlapping(dragged) {
    const box = dragged.renderedBoundingBox();
    return this.cy.nodes().not(dragged).toArray().find((node) => {
      const other = node.renderedBoundingBox();
      return box.x1 < other.x2 && box.x2 > other.x1 && box.y1 < other.y2 && box.y2 > other.y1;
    }) || null;
  }

  // The node goes back where it was: a dialog decides what happens next.
  #restore(node) {
    const origin = node.scratch('_explore_origin');
    if (origin) node.position(origin);
  }
}

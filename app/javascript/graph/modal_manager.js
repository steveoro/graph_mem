import { el } from 'lib/dom';

export class ModalManager {
  constructor() {
    this.currentModal = null;
  }

  /**
   * show(title, contentNode)
   *
   * title       — plain string (code constant, never user data).
   * contentNode — a DOM Node (Element or DocumentFragment) built by the caller.
   */
  show(title, contentNode) {
    this.close();

    const overlay = document.createElement('div');
    overlay.className = 'graph-modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'graph-modal';

    const closeBtn = el('button', { className: 'graph-modal-close', onclick: () => this.close() }, '\u00d7');

    const heading = el('h2', {}, title);   // title is always a code-defined constant
    modal.appendChild(heading);
    if (contentNode) modal.appendChild(contentNode);
    modal.appendChild(closeBtn);

    overlay.appendChild(modal);
    document.body.appendChild(overlay);
    this.currentModal = overlay;
  }

  close() {
    if (this.currentModal) {
      this.currentModal.remove();
      this.currentModal = null;
    }
  }
}

export class ModalManager {
  constructor() {
    this.currentModal = null;
  }

  show(title, content) {
    this.close();

    const overlay = document.createElement('div');
    overlay.className = 'graph-modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'graph-modal';

    const closeBtn = document.createElement('button');
    closeBtn.innerHTML = '\u00d7';
    closeBtn.className = 'graph-modal-close';
    closeBtn.onclick = () => this.close();

    modal.innerHTML = `<h2>${title}</h2>${content}`;
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

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
}

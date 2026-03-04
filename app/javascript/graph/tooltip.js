export class Tooltip {
  constructor() {
    this.currentTooltip = null;
  }

  show(node, position, containerRect) {
    this.hide();

    const data = node.data();
    const tooltip = document.createElement('div');
    tooltip.className = 'node-tooltip';

    const aliases = data.aliases ? data.aliases.trim() : '';
    tooltip.innerHTML = `
      <strong>${data.label}</strong><br>
      ID: ${data.id}<br>
      Type: ${data.type || 'N/A'}<br>
      ${aliases ? `Aliases: ${aliases}<br>` : ''}
      Observations: ${data.memory_observations_count || 0}
    `;

    tooltip.style.left = (containerRect.left + position.x + 10) + 'px';
    tooltip.style.top = (containerRect.top + position.y - 10) + 'px';

    document.body.appendChild(tooltip);
    this.currentTooltip = tooltip;
  }

  hide() {
    if (this.currentTooltip) {
      this.currentTooltip.remove();
      this.currentTooltip = null;
    }
  }
}

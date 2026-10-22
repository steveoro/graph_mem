import { el, text, br } from 'lib/dom';

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

    tooltip.appendChild(el('strong', {}, String(data.label ?? '')));
    tooltip.appendChild(br());
    tooltip.appendChild(text('ID: ' + (data.id ?? '')));
    tooltip.appendChild(br());
    tooltip.appendChild(text('Type: ' + (data.type || 'N/A')));
    tooltip.appendChild(br());
    if (aliases) {
      tooltip.appendChild(text('Aliases: ' + aliases));
      tooltip.appendChild(br());
    }
    tooltip.appendChild(text('Observations: ' + (data.memory_observations_count || 0)));

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

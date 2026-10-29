/**
 * Keyboard access for Explore's canvas menus (UI-4b): the first [role="menuitem"] gets focus,
 * ArrowDown / ArrowUp (and Home / End) move between items, Enter or Space activates one, and
 * Escape closes the menu through `onClose`. Items stay plain elements with click handlers.
 *
 *   bindMenuKeys(menu, { onClose: () => this.hide() })
 */
export function bindMenuKeys(menu, { onClose } = {}) {
  const items = () => Array.from(menu.querySelectorAll('[role="menuitem"]'));
  items().forEach((item) => { item.tabIndex = -1; });

  menu.addEventListener('keydown', (event) => {
    const list = items();
    const index = list.indexOf(document.activeElement);
    const move = (to) => { event.preventDefault(); list[(to + list.length) % list.length]?.focus(); };

    switch (event.key) {
      case 'ArrowDown': return move(index + 1);
      case 'ArrowUp': return move(index - 1);
      case 'Home': return move(0);
      case 'End': return move(list.length - 1);
      case 'Enter':
      case ' ':
        if (index >= 0) { event.preventDefault(); list[index].click(); }
        return undefined;
      case 'Escape':
        event.preventDefault();
        return onClose?.();
      default:
        return undefined;
    }
  });

  items()[0]?.focus({ preventScroll: true });
}

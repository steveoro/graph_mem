/**
 * Safe DOM helpers (UI-0, F1).
 *
 * escapeHtml  — converts a value to text, escaping all HTML special chars.
 * el          — creates a DOM element; children can be strings (auto-escaped)
 *               or existing DOM nodes.
 * text        — creates a Text node from a value.
 * br          — creates a <br> element.
 */

export function escapeHtml(value) {
  const div = document.createElement('div');
  div.textContent = String(value ?? '');
  return div.innerHTML;
}

export function text(value) {
  return document.createTextNode(String(value ?? ''));
}

export function br() {
  return document.createElement('br');
}

/**
 * el(tag, attrs, ...children)
 *
 * attrs  — plain object; keys map to element properties / attributes:
 *            className, id, type, value, placeholder, selected, for (htmlFor),
 *            onclick, onsubmit — assigned as properties.
 *            All others → setAttribute.
 * children — strings become Text nodes; DOM nodes are appended directly.
 */
export function el(tag, attrs = {}, ...children) {
  const element = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null) continue;
    if (k === 'className') {
      element.className = v;
    } else if (k === 'htmlFor') {
      element.htmlFor = v;
    } else if (k in element && typeof element[k] !== 'string') {
      element[k] = v;         // onclick, value, selected, type, …
    } else {
      element.setAttribute(k, v);
    }
  }
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === 'string') {
      element.appendChild(document.createTextNode(child));
    } else if (child instanceof Node) {
      element.appendChild(child);
    }
  }
  return element;
}

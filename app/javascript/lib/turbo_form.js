/**
 * Explore's only write path from JavaScript (UI-4b W7): builds a real <form> carrying the CSRF
 * token from <meta name="csrf-token">, asks for a Turbo Stream answer, optionally confirms with
 * data-turbo-confirm, and submits it through Turbo. Used for Remove relation in the edge menu;
 * every other edit is a server-rendered form.
 *
 *   submitTurboForm('/explore/relations/31', 'delete', {}, { confirm: 'Remove this relation?' })
 */
export function submitTurboForm(action, method = 'post', fields = {}, { confirm = null } = {}) {
  const form = document.createElement('form');
  form.method = 'post';
  form.action = action;
  form.hidden = true;
  form.dataset.turboStream = 'true';
  if (confirm) form.dataset.turboConfirm = confirm;

  const add = (name, value) => {
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = name;
    input.value = String(value ?? '');
    form.appendChild(input);
  };
  const token = document.querySelector('meta[name="csrf-token"]')?.content;
  const param = document.querySelector('meta[name="csrf-param"]')?.content || 'authenticity_token';
  if (token) add(param, token);
  if (method.toLowerCase() !== 'post') add('_method', method.toLowerCase());
  Object.entries(fields).forEach(([name, value]) => add(name, value));

  document.body.appendChild(form);
  form.addEventListener('turbo:submit-end', () => form.remove(), { once: true });
  // A declined confirm never ends a submission: drop the form anyway.
  setTimeout(() => form.isConnected && form.remove(), 60000);
  form.requestSubmit();
  return form;
}

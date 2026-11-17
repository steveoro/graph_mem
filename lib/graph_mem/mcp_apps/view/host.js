// Host context (graph_mem 1.88.0): theming, display mode, size and model context, over the bridge.
// - Theming: hostContext.styles.variables are standard CSS variables (often light-dark() values)
//   set on :root, and hostContext.theme picks the color scheme; the shell has fallbacks for both.
//   Fonts come from --font-sans/--font-mono or the system: the host CSP blocks embedded fonts.
// - Display mode: fullscreen is requested only when hostContext.availableDisplayModes lists it,
//   and the mode the host answers with wins.
// - Size: ui/notifications/size-changed when the document's size changes.
// - Model context: ui/update-model-context replaces what the view told the model before, so the
//   view sends one short summary (scope, counts, selected ids), debounced.

const host = (() => {
  const VARIABLE_NAME = /^--[a-z0-9-]+$/;
  let context = {};
  const listeners = [];

  function applyVariables(variables) {
    const style = document.documentElement.style;
    for (const [name, value] of Object.entries(variables)) {
      if (VARIABLE_NAME.test(name) && typeof value === "string" && value.length <= 500) style.setProperty(name, value);
    }
  }

  function applyTheme(theme) {
    if (theme !== "light" && theme !== "dark") return;
    document.documentElement.dataset.theme = theme;
  }

  // Merges a (partial) host context, as ui/notifications/host-context-changed asks.
  function apply(partial) {
    if (!partial || typeof partial !== "object") return;
    context = { ...context, ...partial };
    const variables = partial.styles && partial.styles.variables;
    if (variables && typeof variables === "object") applyVariables(variables);
    if ("theme" in partial) applyTheme(partial.theme);
    if ("displayMode" in partial) document.documentElement.classList.toggle("fullscreen", partial.displayMode === "fullscreen");
    listeners.forEach((listener) => listener(context, partial));
  }

  const onChange = (listener) => listeners.push(listener);

  function canFullscreen() {
    return Array.isArray(context.availableDisplayModes) && context.availableDisplayModes.includes("fullscreen");
  }

  const isFullscreen = () => context.displayMode === "fullscreen";

  async function toggleFullscreen() {
    const mode = isFullscreen() ? "inline" : "fullscreen";
    if (mode === "fullscreen" && !canFullscreen()) return;
    const result = await bridge.request("ui/request-display-mode", { mode });
    const actual = result && typeof result.mode === "string" ? result.mode : context.displayMode;
    apply({ displayMode: actual });
  }

  function watchSize() {
    let last = "";
    let timer = null;
    const send = () => {
      const width = Math.ceil(document.documentElement.scrollWidth);
      const height = Math.ceil(document.documentElement.scrollHeight);
      const key = `${width}x${height}`;
      if (key === last) return;
      last = key;
      bridge.notify("ui/notifications/size-changed", { width, height });
    };
    new ResizeObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(send, 100);
    }).observe(document.body);
    send();
  }

  let modelTimer = null;
  function updateModelContext(text, structuredContent) {
    clearTimeout(modelTimer);
    modelTimer = setTimeout(() => {
      bridge.request("ui/update-model-context", { content: [{ type: "text", text }], structuredContent })
        .catch((error) => console.warn("graph_mem view: model context not updated", error));
    }, 400);
  }

  // A CSS color (a variable with its fallback) resolved to rgb(), for the canvas, which can't
  // read CSS variables or light-dark().
  function resolveColor(expression) {
    const probe = document.createElement("span");
    probe.style.color = expression;
    probe.hidden = true;
    document.body.append(probe);
    const color = getComputedStyle(probe).color;
    probe.remove();
    return color;
  }

  return { apply, onChange, get: () => context, canFullscreen, isFullscreen, toggleFullscreen, watchSize, updateModelContext, resolveColor };
})();

// MCP Apps stub view (graph_mem 1.87.0, step A). Talks JSON-RPC 2.0 with the host over
// postMessage: ui/initialize, then ui/notifications/initialized; shows the entity count of the
// tool result the host pushes; answers ui/resource-teardown. Step B (1.88.0) draws the graph.
// Rules: only messages from window.parent; only JSON-RPC 2.0 replies to a pending request or a
// method handled here; an unknown request gets -32601, anything else is ignored; page text only
// through textContent.

const PROTOCOL_VERSION = "2026-01-26";
const pending = new Map();
let nextId = 1;
let entityIds = [];

const $ = (id) => document.getElementById(id);
const setText = (id, text) => { $(id).textContent = text; };

function post(message) {
  // The view doesn't know the host's origin; the host routes the message to this frame.
  window.parent.postMessage({ jsonrpc: "2.0", ...message }, "*");
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    post({ id, method, params });
  });
}

const notify = (method, params) => post({ method, params });

function showResult(result) {
  const structured = result && typeof result === "object" ? result.structuredContent : null;
  const entities = structured && Array.isArray(structured.entities) ? structured.entities : [];
  entityIds = entities.map((entity) => entity && entity.entity_id).filter((id) => Number.isInteger(id));
  setText("count", `${entities.length} ${entities.length === 1 ? "entity" : "entities"} in the result`);
  $("details").hidden = entityIds.length === 0;
}

// Host → view requests and notifications this view handles.
const handlers = {
  "ui/notifications/tool-result": (params) => { setText("status", "Tool result received."); showResult(params); },
  "ui/notifications/tool-input": () => setText("status", "Waiting for the tool result…"),
  "ui/notifications/tool-cancelled": () => setText("status", "The tool call was cancelled."),
  "ui/notifications/host-context-changed": () => {},
  "ui/resource-teardown": () => ({}),
  ping: () => ({})
};

window.addEventListener("message", (event) => {
  if (event.source !== window.parent) return;
  const message = event.data;
  if (!message || typeof message !== "object" || message.jsonrpc !== "2.0") return;

  const isReply = "id" in message && !("method" in message);
  if (isReply) {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(message.error);
    else waiter.resolve(message.result);
    return;
  }

  if (typeof message.method !== "string") return;
  if (!Object.hasOwn(handlers, message.method)) {
    // A request (it has an id) gets an answer, as JSON-RPC 2.0 requires; a notification is dropped.
    if ("id" in message) post({ id: message.id, error: { code: -32601, message: "Method not found" } });
    return;
  }
  const answer = handlers[message.method](message.params);
  if ("id" in message) post({ id: message.id, result: answer ?? {} });
});

$("details").addEventListener("click", async () => {
  setText("details-status", "Loading…");
  try {
    const result = await request("tools/call", { name: "get_entities", arguments: { entity_ids: entityIds.slice(0, 20), observation_limit: 1 } });
    const loaded = result && result.structuredContent && Array.isArray(result.structuredContent.entities) ? result.structuredContent.entities.length : 0;
    setText("details-status", `get_entities answered with ${loaded} ${loaded === 1 ? "entity" : "entities"}.`);
  } catch (_error) {
    setText("details-status", "get_entities failed.");
  }
});

try {
  await request("ui/initialize", {
    protocolVersion: PROTOCOL_VERSION,
    appInfo: { name: "graph-mem-graph-view", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  });
  notify("ui/notifications/initialized", {});
  setText("status", "Connected. Waiting for the tool result…");
} catch (_error) {
  setText("status", "The host refused the view.");
}

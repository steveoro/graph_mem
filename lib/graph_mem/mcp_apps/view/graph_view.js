// graph_mem graph view (MCP Apps). Step B2 (1.88.0): the 1.87.0 stub on the shared bridge and
// host helpers; it shows the entity count of the tool result the host pushes.

const $ = (id) => document.getElementById(id);
const setText = (id, text) => { $(id).textContent = text; };

let entityIds = [];

function showResult(result) {
  const data = bridge.structured(result);
  const entities = data && Array.isArray(data.entities) ? data.entities : [];
  entityIds = entities.map((entity) => entity && entity.entity_id).filter((id) => Number.isInteger(id));
  setText("count", `${entities.length} ${entities.length === 1 ? "entity" : "entities"} in the result`);
  $("details").hidden = entityIds.length === 0;
  host.updateModelContext(`graph_mem graph view: ${entities.length} entities in the tool result.`, { view: "graph", entity_count: entities.length });
}

bridge.on("ui/notifications/tool-input", () => setText("status", "Waiting for the tool result…"));
bridge.on("ui/notifications/tool-input-partial", () => {});
bridge.on("ui/notifications/tool-result", (params) => {
  if (bridge.busy()) return; // a host echoing the view's own call: not a result to show
  setText("status", "Tool result received.");
  showResult(params);
});
bridge.on("ui/notifications/tool-cancelled", () => setText("status", "The tool call was cancelled."));
bridge.on("ui/notifications/host-context-changed", (params) => host.apply(params));
bridge.on("ui/resource-teardown", () => ({}));
bridge.on("ping", () => ({}));

host.onChange(() => {
  $("fullscreen").hidden = !host.canFullscreen();
  setText("fullscreen", host.isFullscreen() ? "Exit fullscreen" : "Fullscreen");
});

$("fullscreen").addEventListener("click", () => host.toggleFullscreen().catch(() => setText("status", "The host refused the display mode.")));

$("details").addEventListener("click", async () => {
  setText("details-status", "Loading…");
  try {
    const data = await bridge.callTool("get_entities", { entity_ids: entityIds.slice(0, 20), observation_limit: 1 });
    const loaded = Array.isArray(data.entities) ? data.entities.length : 0;
    setText("details-status", `get_entities answered with ${loaded} ${loaded === 1 ? "entity" : "entities"}.`);
  } catch (_error) {
    setText("details-status", "get_entities failed.");
  }
});

try {
  const initialized = await bridge.request("ui/initialize", {
    protocolVersion: PROTOCOL_VERSION,
    appInfo: { name: "graph-mem-graph-view", version: "1.1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  });
  host.apply((initialized && initialized.hostContext) || {});
  bridge.notify("ui/notifications/initialized", {});
  host.watchSize();
  setText("status", "Connected. Waiting for the tool result…");
} catch (_error) {
  setText("status", "The host refused the view.");
}

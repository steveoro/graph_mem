// graph_mem graph view, Graph mode (MCP Apps, 1.88.0).
// Draws the tool result the host pushes (traverse_graph or find_shortest_path) with the Explore
// styles. Every action is the view's own read-tool call; the view never writes and never calls
// set_context: its scope is view state, told to the model through ui/update-model-context.
// A host may mount the view only once per chat (Cursor does), so the view must stand on its own
// without a fresh tool result.

const $ = (id) => document.getElementById(id);
const setText = (id, text) => { $(id).textContent = text; };

const RESULT_WAIT_MS = 1500;
const VIEW_STYLES = [
  { selector: "node.path", style: { "border-width": 4, "border-color": "#7c3aed", "border-opacity": 1 } },
  { selector: "edge.path", style: { "width": 4, "line-color": "#7c3aed", "target-arrow-color": "#7c3aed" } }
];

const state = {
  scope: "",            // what is drawn, in words ("Traversal from …", "Context project: …")
  entities: new Map(),  // entity_id → entity summary (adapter.js)
  relations: new Map(), // relation_id → relation summary
  focus: new Set(),     // entity ids drawn with the focus border
  gotToolResult: false
};

const cy = cytoscape({
  container: $("graph"),
  style: [...GRAPH_STYLES, ...VIEW_STYLES],
  elements: [],
  wheelSensitivity: LAYOUT_OPTIONS.wheelSensitivity,
  minZoom: 0.05,
  maxZoom: 4
});

function setStatus(text, { error = false } = {}) {
  setText("status", text);
  $("status").classList.toggle("error", error);
}

function themeCanvas() {
  const muted = host.resolveColor("var(--gm-muted)");
  const border = host.resolveColor("var(--gm-border)");
  cy.style().selector("edge").style({ "line-color": border, "target-arrow-color": border, "color": muted }).update();
}

function runLayout() {
  const animate = cy.nodes().length <= 200;
  cy.layout({ ...LAYOUT_OPTIONS, animate, fit: true }).run();
}

function showEmpty(text) {
  setText("empty-text", text);
  $("empty").hidden = false;
}

function describeScope() {
  const selected = typeof selectedIds === "function" ? selectedIds() : [];
  const names = selected.map((id) => `${(state.entities.get(id) || {}).name || "entity"} (#${id})`);
  const parts = [`graph_mem graph view: ${state.scope || "nothing drawn"}.`,
    `${plural(state.entities.size, "entity", "entities")} and ${plural(state.relations.size, "relation", "relations")} drawn.`];
  if (names.length) parts.push(`Selected: ${names.join(", ")}.`);
  host.updateModelContext(parts.join(" "), {
    view: "graph",
    scope: state.scope,
    entity_count: state.entities.size,
    relation_count: state.relations.size,
    selected_entity_ids: selected
  });
}

function updateCounts() {
  setText("counts", state.entities.size ? `${plural(state.entities.size, "entity", "entities")}, ${plural(state.relations.size, "relation", "relations")}` : "");
  $("fit").disabled = state.entities.size === 0;
}

// Replaces the drawing with `graph` ({entities, relations} from capGraph).
// @param options {{scope: string, note?: string, focusIds?: Set<number>}}
function draw(graph, { scope, note = "", focusIds = new Set() }) {
  state.scope = scope;
  state.focus = focusIds;
  state.entities = new Map(graph.entities.map((entity) => [entity.entity_id, entity]));
  state.relations = new Map(graph.relations.map((relation) => [relation.relation_id, relation]));
  cy.elements().remove();
  cy.add(toElements(graph.entities, graph.relations, focusIds));
  setText("scope", scope);
  setText("note", note);
  $("empty").hidden = graph.entities.length > 0;
  if (graph.entities.length === 0) showEmpty("Nothing to draw.");
  runLayout();
  updateCounts();
  describeScope();
}

function scopeOf(data, kind) {
  if (kind === "path") return `Shortest path, ${plural(data.hop_count || 0, "hop", "hops")}`;
  if (data.traversal && Number.isInteger(data.traversal.start_entity_id)) {
    const start = uniqueEntities(data.entities).find((entity) => entity.entity_id === data.traversal.start_entity_id);
    return `Traversal from ${start ? start.name : `#${data.traversal.start_entity_id}`}, depth ${data.traversal.max_depth}`;
  }
  if (data.mode === "catalog") return "Catalog page";
  if (kind === "relations-only") return "Relation query";
  return "Entities";
}

async function drawResult(data) {
  const kind = resultKind(data);
  if (kind === "no-path") {
    draw({ entities: [], relations: [] }, { scope: "Shortest path" });
    showEmpty("No path between the two entities within the search depth.");
    return;
  }
  if (kind === "empty") {
    draw({ entities: [], relations: [] }, { scope: "" });
    showEmpty("The tool result holds nothing to draw.");
    return;
  }
  const focusIds = new Set();
  if (data.traversal && Number.isInteger(data.traversal.start_entity_id)) focusIds.add(data.traversal.start_entity_id);
  if (kind === "path") {
    const ids = uniqueEntities(data.entities).map((entity) => entity.entity_id);
    [ids[0], ids[ids.length - 1]].forEach((id) => focusIds.add(id));
  }

  let entities = data.entities;
  let relations = data.relations;
  let sourceTotals = null;
  if (kind === "relations-only") {
    const within = relationsWithinCap(relations);
    setStatus(`Loading the ${plural(within.entityIds.length, "endpoint", "endpoints")} of the relations…`);
    entities = (await loadEntities(within.entityIds)).entities;
    relations = within.relations;
    sourceTotals = { edges: within.total };
  }

  const graph = capGraph(entities, relations, focusIds);
  const totals = { nodes: graph.totals.nodes, edges: Math.max(graph.totals.edges, (sourceTotals && sourceTotals.edges) || 0) };
  const notes = [capNote({ nodes: graph.entities.length, edges: graph.relations.length }, totals)];
  if (data.traversal && data.traversal.truncated) notes.push("The traversal stopped at its entity limit.");
  draw(graph, { scope: scopeOf(data, kind), note: notes.filter(Boolean).join(" "), focusIds });
  if (kind === "path") cy.elements().addClass("path");
  setStatus(kind === "path" ? "Path drawn." : "Tool result drawn.");
}

// Runs one view action: one at a time, errors shown in the status line.
let running = false;
async function run(label, action) {
  if (running) return;
  running = true;
  document.body.classList.add("busy");
  try {
    await action();
  } catch (error) {
    setStatus(`${label} failed: ${(error && error.message) || "unknown error"}`, { error: true });
  } finally {
    running = false;
    document.body.classList.remove("busy");
  }
}

bridge.on("ui/notifications/tool-input", () => setStatus("Waiting for the tool result…"));
bridge.on("ui/notifications/tool-input-partial", () => {});
bridge.on("ui/notifications/tool-result", (result) => {
  if (bridge.busy()) return; // a host echoing the view's own call: not a result to draw
  state.gotToolResult = true;
  if (result && result.isError) {
    const data = bridge.structured(result);
    setStatus(`The tool call failed: ${(data && data.message) || "unknown error"}`, { error: true });
    showEmpty("The tool call failed.");
    return;
  }
  run("Drawing the tool result", () => drawResult(bridge.structured(result)));
});
bridge.on("ui/notifications/tool-cancelled", () => setStatus("The tool call was cancelled."));
bridge.on("ui/notifications/host-context-changed", (params) => host.apply(params));
bridge.on("ui/resource-teardown", () => ({}));
bridge.on("ping", () => ({}));

host.onChange((_context, partial) => {
  $("fullscreen").hidden = !host.canFullscreen();
  setText("fullscreen", host.isFullscreen() ? "Exit fullscreen" : "Fullscreen");
  if ("theme" in partial || "styles" in partial) themeCanvas();
  if ("displayMode" in partial) requestAnimationFrame(() => { cy.resize(); cy.fit(undefined, 30); });
});

$("fit").addEventListener("click", () => cy.fit(undefined, 30));
$("fullscreen").addEventListener("click", () => host.toggleFullscreen().catch(() => setStatus("The host refused the display mode.", { error: true })));

themeCanvas();
try {
  const initialized = await bridge.request("ui/initialize", {
    protocolVersion: PROTOCOL_VERSION,
    appInfo: { name: "graph-mem-graph-view", version: "1.1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
  });
  host.apply((initialized && initialized.hostContext) || {});
  bridge.notify("ui/notifications/initialized", {});
  host.watchSize();
  setStatus("Connected. Waiting for the tool result…");
  setTimeout(() => {
    if (state.gotToolResult || state.entities.size) return;
    setStatus("No tool result reached this view.");
    showEmpty("Nothing to draw yet.");
  }, RESULT_WAIT_MS);
} catch (_error) {
  setStatus("The host refused the view.", { error: true });
}

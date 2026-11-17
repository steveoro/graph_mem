// graph_mem graph view, Graph mode (MCP Apps, 1.88.0).
// Draws the tool result the host pushes (traverse_graph or find_shortest_path) with the Explore
// styles. Every action is the view's own read-tool call; the view never writes and never changes
// the active project: its scope is view state, told to the model through ui/update-model-context.
// A host may mount the view only once per chat (Cursor does), so the view must stand on its own
// without a fresh tool result.

const $ = (id) => document.getElementById(id);
const setText = (id, text) => { $(id).textContent = text; };

const RESULT_WAIT_MS = 1500;
const VIEW_STYLES = [
  { selector: "node", style: { "width": "label", "height": "label" } },
  { selector: "node.picked", style: { "border-width": 4, "border-color": "#2563eb", "border-opacity": 1 } },
  { selector: "node.path", style: { "border-width": 4, "border-color": "#7c3aed", "border-opacity": 1 } },
  { selector: "edge.path", style: { "width": 4, "line-color": "#7c3aed", "target-arrow-color": "#7c3aed" } }
];

const state = {
  scope: "",            // what is drawn, in words ("Traversal from …", "Context project: …")
  entities: new Map(),  // entity_id → entity summary (adapter.js)
  relations: new Map(), // relation_id → relation summary
  focus: new Set(),     // entity ids drawn with the focus border
  gotToolInput: false,  // the host announced the call that opened the view
  gotToolResult: false, // its result (or cancellation) arrived
  pendingResult: null   // a result pushed while an action was running, drawn when it ends
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

// Explore's force layout packs nodes without a relation in overlapping rows, so those lone nodes
// get a grid sized to their labels: alone when nothing is connected, otherwise below the force
// layout's connected part (root entities with one relation between two of them, say).
const GRID_LAYOUT = Object.freeze({ name: "grid", fit: true, padding: 30, avoidOverlap: true, nodeDimensionsIncludeLabels: true, animate: false });
const GRID_GAP = 60;
let layoutRun = 0;

function runLayout() {
  const run = ++layoutRun;
  const lone = cy.nodes().filter((node) => node.degree(false) === 0);
  const connected = cy.elements().not(lone);
  if (lone.nonempty() && connected.empty()) {
    cy.layout(GRID_LAYOUT).run();
    return;
  }
  if (connected.empty()) return;

  const force = connected.layout({ ...LAYOUT_OPTIONS, animate: connected.nodes().length <= 200, fit: lone.empty() });
  if (lone.nonempty()) {
    // Lay the grid out now, so the lone nodes never pile up at the origin, and move it below the
    // connected part once the force layout has placed it.
    const width = Math.max(cy.width(), 400);
    lone.layout({ ...GRID_LAYOUT, fit: false, boundingBox: { x1: 0, y1: 0, w: width, h: width / 2 } }).run();
    force.one("layoutstop", () => {
      if (run !== layoutRun) return; // a newer drawing replaced this one
      const above = connected.boundingBox({ includeLabels: true });
      const grid = lone.boundingBox({ includeLabels: true });
      lone.shift({ x: above.x1 - grid.x1, y: above.y2 + GRID_GAP - grid.y1 });
      cy.fit(undefined, 30);
    });
  }
  force.run();
}

function showEmpty(text) {
  setText("empty-text", text);
  $("empty").hidden = false;
}

function describeScope() {
  const selected = selectedIds();
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
  markSelection();
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

// Clears the drawing for a result with nothing to draw; the status line says why, too (it would
// otherwise still read "Waiting for the tool result…").
function showNothing(scope, text) {
  draw({ entities: [], relations: [] }, { scope });
  showEmpty(text);
  setStatus(text);
}

async function drawResult(data) {
  const kind = resultKind(data);
  if (kind === "no-path") {
    showNothing("Shortest path", "No path between the two entities within the search depth.");
    return;
  }
  if (kind === "empty") {
    showNothing("", "The tool result holds nothing to draw.");
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

// Runs one view action: one at a time, errors shown in the status line. A tool result pushed
// meanwhile waits in state.pendingResult and is drawn when the action ends.
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
  drainPendingResult();
}

// Draws a tool result kept while the view was busy, once no action or view call is running.
function drainPendingResult() {
  if (running || bridge.busy() || !state.pendingResult) return;
  const pending = state.pendingResult;
  state.pendingResult = null;
  showToolResult(pending);
}

function showToolResult(result) {
  if (result && result.isError) {
    const data = bridge.structured(result);
    setStatus(`The tool call failed: ${(data && data.message) || "unknown error"}`, { error: true });
    if (!state.entities.size) showEmpty("The tool call failed.");
    return;
  }
  run("Drawing the tool result", () => drawResult(bridge.structured(result)));
}

bridge.on("ui/notifications/tool-input", () => {
  state.gotToolInput = true;
  setStatus("Waiting for the tool result…");
});
bridge.on("ui/notifications/tool-input-partial", () => {});
// The result of the call that opened the view. While the view is busy with its own action (or a
// call of its own is in flight) the latest one is kept and drawn when the action ends, never dropped.
bridge.on("ui/notifications/tool-result", (result) => {
  state.gotToolResult = true;
  if (running || bridge.busy()) {
    state.pendingResult = result;
    return;
  }
  showToolResult(result);
});
bridge.on("ui/notifications/tool-cancelled", () => {
  state.gotToolResult = true;
  setStatus("The tool call was cancelled.");
  if (!state.entities.size) showEmpty("The tool call was cancelled.");
});
bridge.on("ui/notifications/host-context-changed", (params) => host.apply(params));
bridge.on("ui/resource-teardown", () => ({}));
bridge.on("ping", () => ({}));

host.onChange((_context, partial) => {
  $("fullscreen").hidden = !host.canFullscreen();
  setText("fullscreen", host.isFullscreen() ? "Exit fullscreen" : "Fullscreen");
  if ("theme" in partial || "styles" in partial) themeCanvas();
});

// "Context project" and "Root entities" (decision 3): the view's own loads, so the view is useful
// when no tool result reaches it (a host mounting one view per chat) or the result is empty.
const SUBSETS = {
  context: { label: "Loading the context project", load: loadContextProject },
  roots: { label: "Loading the root entities", load: loadRootEntities }
};

function loadSubset(kind) {
  const subset = SUBSETS[kind];
  return run(subset.label, async () => {
    setStatus(`${subset.label}…`);
    const loaded = await subset.load((done, total) => setStatus(`${subset.label}… ${done.toLocaleString("en")}${Number.isInteger(total) ? ` of ${total.toLocaleString("en")}` : ""}`));
    if (loaded.empty) {
      showNothing("", loaded.empty);
      return;
    }
    const focusIds = new Set(Number.isInteger(loaded.projectId) ? [loaded.projectId] : []);
    const graph = capGraph(loaded.entities, loaded.relations, focusIds);
    const capped = capNote({ nodes: graph.entities.length, edges: graph.relations.length }, graph.totals);
    draw(graph, { scope: loaded.scope, note: [loaded.note, capped].filter(Boolean).join(" "), focusIds });
    setStatus(`${loaded.scope} loaded.`);
  });
}

document.querySelectorAll("button[data-load]").forEach((button) => {
  button.addEventListener("click", () => loadSubset(button.dataset.load));
});

$("fit").addEventListener("click", () => cy.fit(undefined, 30));
// The canvas narrows when the details panel opens (and changes in fullscreen): Cytoscape only
// follows window resizes on its own.
new ResizeObserver(() => {
  cy.resize();
  if (cy.nodes().length) cy.fit(undefined, 30);
}).observe($("graph"));
$("fullscreen").addEventListener("click", () => host.toggleFullscreen().catch(() => setStatus("The host refused the display mode.", { error: true })));

bindInteraction();
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
    // A tool-input means the result is on its way (a long traversal can take a while).
    if (state.gotToolInput || state.gotToolResult || state.entities.size) return;
    setStatus("No tool result reached this view: load a subset.");
    showEmpty("Nothing to draw yet.");
  }, RESULT_WAIT_MS);
} catch (_error) {
  setStatus("The host refused the view.", { error: true });
}

// Graph mode interaction (graph_mem 1.88.0): selection, the details panel, expand, path and
// "Show this project". Read tools only: get_entities (one node's full observations),
// traverse_graph, find_shortest_path. "Show this project" is view state; the scope and the
// selection reach the model only through ui/update-model-context.
// Defines functions only: graph_view.js calls bindInteraction() once cy and state exist.

let selection = []; // up to two entity ids, the latest last

const selectedIds = () => [...selection];

const entityName = (id) => {
  const entity = state.entities.get(id);
  return entity && entity.name ? entity.name : `#${id}`;
};

function markSelection() {
  selection = selection.filter((id) => state.entities.has(id));
  cy.nodes().removeClass("picked");
  selection.forEach((id) => cy.getElementById(String(id)).addClass("picked"));
  setText("selection", selection.length ? `Selected: ${selection.map(entityName).join(", ")}` : "");
  $("path").disabled = selection.length < 2;
}

function selectNode(id) {
  selection = [...selection.filter((selected) => selected !== id), id].slice(-2);
  markSelection();
  describeScope();
  showDetails(id);
}

function listItems(listId, texts) {
  const list = $(listId);
  list.replaceChildren(...texts.map((text) => {
    const item = document.createElement("li");
    item.textContent = text;
    return item;
  }));
}

function relationText(relation, id) {
  const outgoing = relation.from_entity_id === id;
  const other = outgoing ? relation.to_entity_id : relation.from_entity_id;
  return `${outgoing ? "→" : "←"} ${relation.relation_type} ${entityName(other)} (#${other})`;
}

// The project "Show this project" opens: the entity itself when it is a Project, else its
// project when a result said which one (get_entities doesn't carry project_id; a search hit does).
// @param summary {object} optional: the entity's summary when it isn't drawn (a search hit)
function projectOf(id, summary = null) {
  const entity = state.entities.get(id) || summary;
  if (!entity) return null;
  if (entity.entity_type === "Project") return id;
  return Number.isInteger(entity.project_id) ? entity.project_id : null;
}

// One get_entities call for the entity's full observations and its relations.
// @param summary {object} optional: name, entity_type, aliases and project_id of an entity that
//   isn't drawn (a search hit); a drawn entity's own summary wins
let detailsToken = 0;
let panelSummary = null;
async function showDetails(id, summary = null) {
  const token = ++detailsToken;
  panelSummary = state.entities.has(id) ? null : summary;
  const entity = state.entities.get(id) || summary || { entity_type: "", aliases: "" };
  $("panel").hidden = false;
  $("panel").dataset.entityId = String(id);
  setText("panel-title", `${entity.name || entityName(id)} (#${id})`);
  setText("panel-type", entity.entity_type || "untyped");
  setText("panel-aliases", entity.aliases ? `Aliases: ${entity.aliases}` : "");
  const project = projectOf(id, panelSummary);
  const showProject = document.querySelector('button[data-action="show-project"]');
  showProject.hidden = project === null;
  showProject.textContent = project === id ? "Show this project" : "Show its project";
  listItems("panel-observations", []);
  listItems("panel-relations", []);
  setText("panel-status", "Loading the details…");
  try {
    const data = await bridge.callTool("get_entities", { entity_ids: [id], relations: "all" });
    if (token !== detailsToken) return;
    const loaded = (Array.isArray(data.entities) ? data.entities : []).find((item) => item && item.entity_id === id);
    const observations = loaded && Array.isArray(loaded.observations) ? loaded.observations : [];
    listItems("panel-observations", observations.map((observation) => String(observation.content ?? "")));
    listItems("panel-relations", uniqueRelations(data.relations).map((relation) => relationText(relation, id)));
    setText("panel-status", observations.length ? "" : "No active observations.");
  } catch (error) {
    if (token === detailsToken) setText("panel-status", `Loading the details failed: ${(error && error.message) || "unknown error"}`);
  } finally {
    drainPendingResult();
  }
}

function closeDetails() {
  detailsToken += 1;
  $("panel").hidden = true;
}

// Redraws with `entities` and `relations` added to what is drawn (the cap still applies).
function mergeIntoGraph(entities, relations, note) {
  const all = capGraph([...state.entities.values(), ...entities], [...state.relations.values(), ...relations], state.focus);
  const capped = capNote({ nodes: all.entities.length, edges: all.relations.length }, all.totals);
  draw(all, { scope: state.scope, note: [note, capped].filter(Boolean).join(" "), focusIds: state.focus });
}

function expand(id, depth) {
  return run("Expanding", async () => {
    setStatus(`Expanding ${entityName(id)}…`);
    const walk = await bridge.callTool("traverse_graph", { start_entity_id: id, max_depth: depth, include: ["relations", "traversal"] });
    const ids = new Set([id]);
    uniqueRelations(walk.relations).forEach((relation) => ids.add(relation.from_entity_id).add(relation.to_entity_id));
    const known = new Set(state.entities.keys());
    const loaded = await loadEntities([...ids].filter((entityId) => !known.has(entityId)), { knownIds: known });
    const before = state.entities.size;
    mergeIntoGraph(loaded.entities, [...loaded.relations, ...uniqueRelations(walk.relations)],
      walk.traversal && walk.traversal.truncated ? "The expansion stopped at its entity limit." : "");
    setStatus(`Expanded ${entityName(id)} by ${depth}: ${plural(state.entities.size - before, "new entity", "new entities")}.`);
  });
}

function pathBetweenSelected() {
  const [from, to] = selection;
  if (!Number.isInteger(from) || !Number.isInteger(to)) return Promise.resolve();
  return run("Finding the path", async () => {
    setStatus(`Finding the path between ${entityName(from)} and ${entityName(to)}…`);
    const data = await bridge.callTool("find_shortest_path", { from_entity_id: from, to_entity_id: to });
    if (!data.found) {
      setStatus(`No path between ${entityName(from)} and ${entityName(to)} within the search depth.`);
      return;
    }
    const entities = uniqueEntities(data.entities);
    const relations = uniqueRelations(data.relations);
    mergeIntoGraph(entities, relations, "");
    entities.forEach((entity) => cy.getElementById(String(entity.entity_id)).addClass("path"));
    relations.forEach((relation) => cy.getElementById(`r${relation.relation_id}`).addClass("path"));
    setStatus(`Path: ${plural(data.hop_count || 0, "hop", "hops")} between ${entityName(from)} and ${entityName(to)}.`);
  });
}

// @param name {string} optional: the project's name when it isn't drawn (a search hit)
function showProject(projectId, name = entityName(projectId)) {
  return run("Loading the project", async () => {
    setStatus(`Loading ${name}…`);
    const loaded = await loadProject(projectId, null, (done, total) => setStatus(`Loading ${name}… ${done} of ${total}`));
    const focusIds = new Set([projectId]);
    const graph = capGraph(loaded.entities, loaded.relations, focusIds);
    const capped = capNote({ nodes: graph.entities.length, edges: graph.relations.length }, graph.totals);
    draw(graph, { scope: `Project: ${name}`, note: [loaded.note, capped].filter(Boolean).join(" "), focusIds });
    setStatus(`Project ${name} loaded.`);
  });
}

function panelEntityId() {
  const id = Number($("panel").dataset.entityId);
  return Number.isInteger(id) ? id : null;
}

function bindInteraction() {
  cy.on("tap", "node", (event) => selectNode(Number(event.target.data("entity_id"))));
  $("panel-close").addEventListener("click", closeDetails);
  $("path").addEventListener("click", pathBetweenSelected);
  const actions = {
    "expand-1": (id) => expand(id, 1),
    "expand-2": (id) => expand(id, 2),
    "show-project": (id) => {
      const project = projectOf(id, panelSummary);
      const hitName = panelSummary && panelSummary.entity_id === project ? panelSummary.name : undefined;
      if (project !== null) showProject(project, hitName);
    }
  };
  Object.entries(actions).forEach(([action, handler]) => {
    document.querySelector(`button[data-action="${action}"]`).addEventListener("click", () => {
      const id = panelEntityId();
      if (id !== null) handler(id);
    });
  });
}

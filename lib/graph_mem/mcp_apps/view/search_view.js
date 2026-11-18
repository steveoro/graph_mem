// Search mode (graph_mem 1.89.0): a query with the filters search takes alongside one, a
// previous / next pager, a hit's details in the node panel, and "Show as graph". Read tools only:
// search (summary mode), get_entities (the details and the drawing) and get_context (the context
// project, offered in the project filter). A query is required, because search's catalog mode
// takes no filters. Summary pages carry no total, so "Next" is off when a page comes back short.
// Defines functions only: graph_view.js calls bindSearch() once cy and state exist.

const SEARCH = Object.freeze({ perPage: 20, queryShown: 60 });

const searchState = {
  mode: "graph",
  args: null,          // the last search's arguments, without page and per_page
  page: 1,
  hits: [],            // the current page's hit summaries
  projects: new Map()  // project id → name, for the project filter (only projects the view knows)
};

const clip = (text, max) => (text.length > max ? `${text.slice(0, max - 1)}…` : text);

// "Graph" or "Search". The drawing stays as it is while Search mode is shown.
function setMode(mode) {
  searchState.mode = mode === "search" ? "search" : "graph";
  document.body.classList.toggle("mode-search", searchState.mode === "search");
  document.body.classList.toggle("mode-graph", searchState.mode === "graph");
  document.querySelectorAll(".modes button[data-mode]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.mode === searchState.mode));
  });
  if (searchState.mode === "graph") {
    describeScope();
    return;
  }
  refreshProjects();
  describeSearch();
  $("search-query").focus();
}

// A search hit (summary mode's results), keeping the keys the view shows.
function hitSummary(hit) {
  return {
    ...entitySummary(hit),
    description: typeof hit.description === "string" ? hit.description : "",
    relevance_score: typeof hit.relevance_score === "number" ? hit.relevance_score : null,
    matched_fields: Array.isArray(hit.matched_fields) ? hit.matched_fields.filter((field) => typeof field === "string") : []
  };
}

function noteProject(id, name) {
  if (Number.isInteger(id) && !searchState.projects.has(id)) searchState.projects.set(id, name || `#${id}`);
}

function renderProjects() {
  const select = $("search-project");
  const selected = select.value;
  const any = document.createElement("option");
  any.value = "";
  any.textContent = "Any";
  const options = [...searchState.projects].sort((a, b) => a[1].localeCompare(b[1])).map(([id, name]) => {
    const option = document.createElement("option");
    option.value = String(id);
    option.textContent = `${name} (#${id})`;
    return option;
  });
  select.replaceChildren(any, ...options);
  select.value = searchState.projects.has(Number(selected)) ? selected : "";
}

// The project filter offers the Projects already drawn or found, and the context project. It
// never scans the catalog for more. Its get_context runs outside run(), so a tool result pushed
// meanwhile waits in pendingResult: drain it when the call ends.
async function refreshProjects() {
  state.entities.forEach((entity) => { if (entity.entity_type === "Project") noteProject(entity.entity_id, entity.name); });
  renderProjects();
  try {
    const context = await bridge.callTool("get_context", {});
    if (context.status === "context_active") noteProject(context.entity_id, context.entity_name);
    renderProjects();
  } catch (_error) {
    // The filter keeps the projects it already knows.
  } finally {
    drainPendingResult();
  }
}

// The search arguments the form describes; only the filters that narrow anything are sent.
function formArgs() {
  const args = { query: $("search-query").value.trim() };
  const project = $("search-project").value;
  if (project && Number.isInteger(Number(project))) args.project_id = Number(project);
  const types = [...new Set($("search-types").value.split(",").map((type) => type.trim()).filter(Boolean))];
  if (types.length) args.entity_types = types;
  document.querySelectorAll("#search-form input[data-field]").forEach((box) => {
    if (!box.checked) args[box.dataset.field] = false;
  });
  const perspective = $("search-perspective").value;
  if (perspective) args.perspective = perspective;
  return args;
}

// The filters in a few words, for the model context.
function filterText(args) {
  const parts = [];
  if (Number.isInteger(args.project_id)) parts.push(`project ${searchState.projects.get(args.project_id) || `#${args.project_id}`}`);
  if (args.entity_types) parts.push(`types ${args.entity_types.join(", ")}`);
  const off = Object.keys(args).filter((key) => key.startsWith("search_in_")).map((key) => key.slice("search_in_".length));
  if (off.length) parts.push(`not matching ${off.join(", ")}`);
  if (args.perspective) parts.push(`${args.perspective} only`);
  return parts.join("; ");
}

function describeSearch() {
  if (!searchState.args) return;
  const { query, ...filters } = searchState.args;
  const narrowed = filterText(searchState.args);
  host.updateModelContext(
    `graph_mem search view: "${clip(query, SEARCH.queryShown)}"${narrowed ? ` (${narrowed})` : ""}, page ${searchState.page}, ${plural(searchState.hits.length, "hit", "hits")}.`,
    { view: "search", query, filters, page: searchState.page, hit_ids: searchState.hits.map((hit) => hit.entity_id) }
  );
}

function hitItem(hit) {
  const item = document.createElement("li");
  const open = document.createElement("button");
  open.type = "button";
  open.textContent = hit.name || `#${hit.entity_id}`;
  open.addEventListener("click", () => showDetails(hit.entity_id, hit));
  const meta = document.createElement("span");
  meta.className = "muted";
  const project = Number.isInteger(hit.project_id) ? ` · in ${searchState.projects.get(hit.project_id) || `project #${hit.project_id}`}` : "";
  const score = hit.relevance_score === null ? "" : ` · score ${Number(hit.relevance_score.toFixed(3))}`;
  const matched = hit.matched_fields.length ? ` · matched ${hit.matched_fields.join(", ")}` : "";
  meta.textContent = ` ${hit.entity_type || "untyped"} #${hit.entity_id}${project}${score}${matched}`;
  item.append(open, meta);
  if (hit.description) {
    const description = document.createElement("div");
    description.className = "muted";
    description.textContent = hit.description;
    item.append(description);
  }
  return item;
}

function renderHits() {
  $("search-hits").replaceChildren(...searchState.hits.map(hitItem));
  $("search-hits").start = (searchState.page - 1) * SEARCH.perPage + 1;
  setText("search-page", searchState.args ? `Page ${searchState.page}` : "");
  $("search-prev").disabled = !searchState.args || searchState.page <= 1;
  $("search-next").disabled = !searchState.args || searchState.hits.length < SEARCH.perPage;
  $("search-graph").disabled = searchState.hits.length === 0;
}

// One summary page. A ToolError (a bad filter, say) shows in the status line; the hits shown stay.
function runSearch(args, page) {
  return run("Searching", async () => {
    setStatus(`Searching for "${clip(args.query, SEARCH.queryShown)}"…`);
    const data = await bridge.callTool("search", { ...args, page, per_page: SEARCH.perPage });
    const hits = (Array.isArray(data.results) ? data.results : []).filter(isEntity).map(hitSummary);
    hits.filter((hit) => hit.entity_type === "Project").forEach((hit) => noteProject(hit.entity_id, hit.name));
    Object.assign(searchState, { args, page, hits });
    renderProjects();
    renderHits();
    if (hits.length) setStatus(`${plural(hits.length, "hit", "hits")} on page ${page}.`);
    else setStatus(page > 1 ? `No more hits after page ${page - 1}.` : "No hits.");
    describeSearch();
  });
}

// Draws the current page's hits in Graph mode, with the relations between them.
function showHitsAsGraph() {
  const ids = searchState.hits.map((hit) => hit.entity_id);
  if (!ids.length || !searchState.args) return Promise.resolve();
  setMode("graph");
  const scope = `Search: "${clip(searchState.args.query, SEARCH.queryShown)}", page ${searchState.page}`;
  return run("Drawing the hits", async () => {
    setStatus(`Loading ${plural(ids.length, "hit", "hits")}…`);
    const loaded = await loadEntities(ids, { onProgress: (done, total) => setStatus(`Loading the hits… ${done} of ${total}`) });
    if (!loaded.entities.length) {
      showNothing(scope, "None of the hits could be loaded.");
      return;
    }
    draw(capGraph(loaded.entities, loaded.relations), { scope });
    setStatus(`${plural(loaded.entities.length, "hit", "hits")} drawn.`);
  });
}

function bindSearch() {
  document.querySelectorAll("button[data-mode]").forEach((button) => {
    button.addEventListener("click", () => setMode(button.dataset.mode));
  });
  const submit = () => {
    const args = formArgs();
    if (!args.query) {
      setStatus("Type a query first: search takes its filters only with one.");
      return;
    }
    runSearch(args, 1);
  };
  $("search-run").addEventListener("click", submit);
  $("search-form").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && event.target instanceof HTMLInputElement && event.target.type !== "checkbox") submit();
  });
  $("search-prev").addEventListener("click", () => { if (searchState.args && searchState.page > 1) runSearch(searchState.args, searchState.page - 1); });
  $("search-next").addEventListener("click", () => { if (searchState.args) runSearch(searchState.args, searchState.page + 1); });
  $("search-graph").addEventListener("click", showHitsAsGraph);
  // The panel's Expand and "Show this project" change the drawing: show it first (capture phase,
  // before interaction.js's own handlers).
  $("panel").addEventListener("click", (event) => {
    if (event.target instanceof Element && event.target.closest("button[data-action]")) setMode("graph");
  }, true);
}

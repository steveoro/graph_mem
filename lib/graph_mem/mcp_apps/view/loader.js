// Loading entities and edges through graph_mem's read tools (graph_mem 1.88.0): batched
// get_entities, and the two subsets the view loads on its own (decision 3 of the MCP Apps plan).
// get_entities has no id cap and returns every observation, so the view sends at most 100 ids per
// call with observation_limit: 1 and relations: "all" ("internal" keeps only the edges inside
// one call, which would lose the edges between two batches). Edges are deduped by relation_id and
// kept only when both ends are loaded.

const LOAD = Object.freeze({ batch: 100, projectCap: 1000, catalogPage: 100, catalogMaxPages: 20 });

// @param ids {Array<number>} entity ids
// @param onProgress {function(loaded, total)} optional
// @return {Promise<{entities, relations}>} entity summaries and the edges between them
async function loadEntities(ids, onProgress = () => {}) {
  const unique = [...new Set(ids.filter((id) => Number.isInteger(id)))];
  const entities = [];
  const relations = [];
  for (let start = 0; start < unique.length; start += LOAD.batch) {
    const batch = unique.slice(start, start + LOAD.batch);
    const data = await bridge.callTool("get_entities", { entity_ids: batch, relations: "all", observation_limit: 1 });
    entities.push(...uniqueEntities(data.entities));
    relations.push(...uniqueRelations(data.relations));
    onProgress(Math.min(start + LOAD.batch, unique.length), unique.length);
  }
  const loaded = new Set(entities.map((entity) => entity.entity_id));
  return {
    entities,
    relations: uniqueRelations(relations).filter((relation) => loaded.has(relation.from_entity_id) && loaded.has(relation.to_entity_id))
  };
}

// A project and its part_of subtree: traverse_graph walks the incoming part_of edges (relations
// and traversal only, so no observations travel), then batched get_entities loads the members and
// every edge between them. Capped at 1,000 entities (traverse_graph's max).
// @param projectId {number}
// @param total {number|null} the project's entity count when known (get_context's scope_entity_count)
// @return {Promise<{entities, relations, note}>}
async function loadProject(projectId, total = null, onProgress = () => {}) {
  const walk = await bridge.callTool("traverse_graph", {
    start_entity_id: projectId, direction: "incoming", relation_types: ["part_of"], max_depth: 5,
    max_entities: LOAD.projectCap, include: ["relations", "traversal"]
  });
  const ids = [projectId];
  uniqueRelations(walk.relations).forEach((relation) => ids.push(relation.from_entity_id, relation.to_entity_id));
  const memberIds = [...new Set(ids)].slice(0, LOAD.projectCap);
  const graph = await loadEntities(memberIds, onProgress);
  let note = "";
  if (Number.isInteger(total) && total > graph.entities.length) {
    note = `Showing ${graph.entities.length.toLocaleString("en")} of ${plural(total, "entity", "entities")} in the project.`;
  } else if (walk.traversal && walk.traversal.truncated) {
    note = `The project has more than ${plural(LOAD.projectCap, "entity", "entities")}; showing the first ${LOAD.projectCap.toLocaleString("en")}.`;
  }
  return { ...graph, note };
}

// The active project of the agent's connection (get_context), drawn with loadProject.
// @return {Promise<{entities, relations, note, scope, projectId}|{empty: string}>}
async function loadContextProject(onProgress = () => {}) {
  const context = await bridge.callTool("get_context", {});
  if (context.status !== "context_active" || !Number.isInteger(context.entity_id)) {
    return { empty: "No active project. Ask the agent to set one, or load the root entities." };
  }
  const graph = await loadProject(context.entity_id, Number.isInteger(context.scope_entity_count) ? context.scope_entity_count : null, onProgress);
  return { ...graph, scope: `Context project: ${context.entity_name || `#${context.entity_id}`}`, projectId: context.entity_id };
}

// The root entities, as Explore's default view shows them: Projects and untyped entities. search
// can't filter without a query, so this pages the unfiltered catalog (100 per page, at most 20
// pages) and filters here, then loads the roots with batched get_entities. One function, so a
// later search change can replace it.
// @return {Promise<{entities, relations, note, scope}|{empty: string}>}
async function loadRootEntities(onProgress = () => {}) {
  const rootIds = [];
  let scanned = 0;
  let total = null;
  for (let page = 1; page <= LOAD.catalogMaxPages; page += 1) {
    const data = await bridge.callTool("search", { page, per_page: LOAD.catalogPage });
    const rows = Array.isArray(data.entities) ? data.entities : [];
    const pagination = data.pagination || {};
    if (Number.isInteger(pagination.total_entities)) total = pagination.total_entities;
    scanned += rows.length;
    rows.filter(isEntity).forEach((row) => {
      if (!row.entity_type || row.entity_type === "Project") rootIds.push(row.entity_id);
    });
    onProgress(scanned, total);
    const lastPage = Number.isInteger(pagination.total_pages) ? pagination.total_pages : page;
    if (rows.length < LOAD.catalogPage || page >= lastPage) break;
  }
  if (rootIds.length === 0) return { empty: "No Project or untyped entity found." };
  const graph = await loadEntities(rootIds);
  const note = Number.isInteger(total) && total > scanned
    ? `Scanned ${scanned.toLocaleString("en")} of ${plural(total, "entity", "entities")} for roots.` : "";
  return { ...graph, note, scope: "Root entities" };
}

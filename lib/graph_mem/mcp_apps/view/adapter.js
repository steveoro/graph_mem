// Tool results → Cytoscape elements (graph_mem 1.88.0).
// Handles the results the view can get: traverse_graph (expansion, a relation query, any include),
// find_shortest_path, get_entities and search catalog pages. Elements carry the keys the Explore
// GRAPH_STYLES read: data.label, data.type and data.is_focus. Cytoscape's [is_focus="true"]
// compares strictly, so is_focus is the string "true" (a boolean would never match).

const DRAW_CAP = Object.freeze({ nodes: 2000, edges: 5000 });

// What a structured tool result holds: "path", "no-path", "entities" (with or without relations),
// "relations-only" or "empty" (nothing to draw, such as include: ["traversal"]).
function resultKind(data) {
  if (!data || typeof data !== "object") return "empty";
  if (typeof data.found === "boolean") return data.found ? "path" : "no-path";
  if (Array.isArray(data.entities) && data.entities.length > 0) return "entities";
  if (Array.isArray(data.relations) && data.relations.length > 0) return "relations-only";
  return "empty";
}

// The few entity and relation fields the view keeps (results carry observations; the view drops them).
function entitySummary(entity) {
  return {
    entity_id: entity.entity_id,
    name: typeof entity.name === "string" ? entity.name : "",
    entity_type: typeof entity.entity_type === "string" ? entity.entity_type : "",
    project_id: Number.isInteger(entity.project_id) ? entity.project_id : null,
    aliases: typeof entity.aliases === "string" ? entity.aliases : ""
  };
}

function relationSummary(relation) {
  return {
    relation_id: relation.relation_id,
    from_entity_id: relation.from_entity_id,
    to_entity_id: relation.to_entity_id,
    relation_type: typeof relation.relation_type === "string" ? relation.relation_type : ""
  };
}

const isEntity = (entity) => entity && typeof entity === "object" && Number.isInteger(entity.entity_id);
const isRelation = (relation) => relation && typeof relation === "object" && Number.isInteger(relation.relation_id) &&
  Number.isInteger(relation.from_entity_id) && Number.isInteger(relation.to_entity_id);

function uniqueEntities(entities) {
  const byId = new Map();
  (Array.isArray(entities) ? entities : []).filter(isEntity).forEach((entity) => {
    if (!byId.has(entity.entity_id)) byId.set(entity.entity_id, entitySummary(entity));
  });
  return [...byId.values()];
}

function uniqueRelations(relations) {
  const byId = new Map();
  (Array.isArray(relations) ? relations : []).filter(isRelation).forEach((relation) => {
    if (!byId.has(relation.relation_id)) byId.set(relation.relation_id, relationSummary(relation));
  });
  return [...byId.values()];
}

// Applies the draw cap: the focus entities first, then the given order, up to DRAW_CAP.nodes;
// then the relations whose two ends are both kept, up to DRAW_CAP.edges.
// @return {{entities, relations, totals: {nodes, edges}}}
function capGraph(entities, relations, focusIds = new Set()) {
  const all = uniqueEntities(entities);
  const ordered = [...all.filter((entity) => focusIds.has(entity.entity_id)), ...all.filter((entity) => !focusIds.has(entity.entity_id))];
  const kept = ordered.slice(0, DRAW_CAP.nodes);
  const ids = new Set(kept.map((entity) => entity.entity_id));
  const inside = uniqueRelations(relations).filter((relation) => ids.has(relation.from_entity_id) && ids.has(relation.to_entity_id));
  return { entities: kept, relations: inside.slice(0, DRAW_CAP.edges), totals: { nodes: all.length, edges: inside.length } };
}

// For a relations-only result: the first relations until either cap is reached, and the ids of
// their endpoints (to load with get_entities).
// @return {{relations, entityIds, total}}
function relationsWithinCap(relations) {
  const all = uniqueRelations(relations);
  const ids = new Set();
  const kept = [];
  for (const relation of all) {
    if (kept.length >= DRAW_CAP.edges) break;
    const added = [relation.from_entity_id, relation.to_entity_id].filter((id) => !ids.has(id));
    if (ids.size + new Set(added).size > DRAW_CAP.nodes) break;
    added.forEach((id) => ids.add(id));
    kept.push(relation);
  }
  return { relations: kept, entityIds: [...ids], total: all.length };
}

const plural = (count, one, many) => `${count.toLocaleString("en")} ${count === 1 ? one : many}`;

// "Showing N of M entities and E of F relations." when the cap (or a source limit) cut something.
function capNote(shown, totals) {
  const cut = [];
  if (totals.nodes > shown.nodes) cut.push(`${shown.nodes.toLocaleString("en")} of ${plural(totals.nodes, "entity", "entities")}`);
  if (totals.edges > shown.edges) cut.push(`${shown.edges.toLocaleString("en")} of ${plural(totals.edges, "relation", "relations")}`);
  return cut.length ? `Showing ${cut.join(" and ")}.` : "";
}

function nodeElement(entity, focusIds) {
  return {
    group: "nodes",
    data: {
      id: String(entity.entity_id),
      entity_id: entity.entity_id,
      label: entity.name || `#${entity.entity_id}`,
      type: entity.entity_type,
      is_focus: focusIds.has(entity.entity_id) ? "true" : "false"
    }
  };
}

function edgeElement(relation) {
  return {
    group: "edges",
    data: {
      id: `r${relation.relation_id}`,
      relation_id: relation.relation_id,
      source: String(relation.from_entity_id),
      target: String(relation.to_entity_id),
      label: relation.relation_type
    }
  };
}

// @return {Array<object>} Cytoscape elements, nodes first
function toElements(entities, relations, focusIds = new Set()) {
  return [...entities.map((entity) => nodeElement(entity, focusIds)), ...relations.map(edgeElement)];
}

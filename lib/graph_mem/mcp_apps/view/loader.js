// Loading entities and edges through graph_mem's read tools (graph_mem 1.88.0).
// get_entities has no id cap and returns every observation, so the view sends at most 100 ids per
// call with observation_limit: 1 and relations: "all" ("internal" keeps only the edges inside
// one call, which would lose the edges between two batches). Edges are deduped by relation_id and
// kept only when both ends are loaded.

const LOAD = Object.freeze({ batch: 100 });

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

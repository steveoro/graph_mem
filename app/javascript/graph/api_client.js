// Explore's only server call from JavaScript (UI-4b): the graph read. Edits never go through
// here; they are server-rendered forms (and lib/turbo_form.js for Remove relation).
export class GraphApiClient {
  // scope: root | full | project | entity | search. Returns { elements, options[, truncated, total] }.
  async fetchGraphData({ scope = 'root', entityId = null, projectId = null, ids = null, depth = 1 } = {}) {
    const params = new URLSearchParams();

    if (scope === 'search' && ids) {
      params.set('ids', ids);
    } else if (scope === 'project' && projectId) {
      params.set('project_id', projectId);
    } else if (scope === 'entity' && entityId) {
      params.set('entity_id', entityId);
      params.set('depth', depth === 2 ? '2' : '1');
    } else if (scope !== 'full') {
      params.set('root_only', 'true');
    }

    const query = params.toString();
    const response = await fetch('/api/v1/graph_data' + (query ? '?' + query : ''), {
      headers: { Accept: 'application/json' }
    });
    if (!response.ok) throw new Error('HTTP ' + response.status);
    return response.json();
  }
}

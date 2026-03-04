export class GraphApiClient {
  getCSRFToken() {
    const token = document.querySelector('meta[name="csrf-token"]');
    return token ? token.content : null;
  }

  #headers(json = true) {
    const h = { 'X-CSRF-Token': this.getCSRFToken() };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  async fetchGraphData(rootOnly = false, entityId = null, { scopedEntityId = null } = {}) {
    let url = '/api/v1/graph_data';
    const params = new URLSearchParams();

    if (scopedEntityId) {
      params.append('scoped_entity_id', scopedEntityId);
    } else if (entityId) {
      params.append('entity_id', entityId);
    } else if (rootOnly) {
      params.append('root_only', 'true');
    }

    if (params.toString()) url += '?' + params.toString();

    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
    return response.json();
  }

  async fetchObservations(entityId) {
    const response = await fetch(`/api/v1/memory_entities/${entityId}/memory_observations`);
    if (!response.ok) throw new Error(`Failed to fetch observations (HTTP ${response.status})`);
    return response.json();
  }

  async fetchEntity(entityId) {
    const response = await fetch(`/api/v1/memory_entities/${entityId}`);
    if (!response.ok) throw new Error(`Could not fetch entity ${entityId}`);
    return response.json();
  }

  async updateEntity(entityId, data) {
    const response = await fetch(`/api/v1/memory_entities/${entityId}`, {
      method: 'PATCH',
      headers: this.#headers(),
      body: JSON.stringify({ memory_entity: data })
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.message || 'Failed to update entity');
    }
    return response.json();
  }

  async deleteEntity(entityId) {
    const response = await fetch(`/api/v1/memory_entities/${entityId}`, {
      method: 'DELETE',
      headers: this.#headers(false)
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.message || 'Failed to delete entity');
    }
  }

  async mergeEntities(sourceId, targetId) {
    const response = await fetch(`/api/v1/memory_entities/${sourceId}/merge_into/${targetId}`, {
      method: 'POST',
      headers: this.#headers()
    });
    if (response.status !== 204) {
      const errorData = await response.json().catch(() => ({ message: 'Unknown error during merge.' }));
      throw new Error(errorData.error || errorData.message || 'Unknown error');
    }
  }

  async createRelation(fromEntityId, toEntityId, relationType) {
    const response = await fetch('/api/v1/memory_relations', {
      method: 'POST',
      headers: this.#headers(),
      body: JSON.stringify({
        memory_relation: { from_entity_id: fromEntityId, to_entity_id: toEntityId, relation_type: relationType }
      })
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.message || 'Failed to create relation');
    }
    return response.json();
  }

  async updateRelationType(relationId, newType) {
    const response = await fetch('/data_exchange/update_relation', {
      method: 'PATCH',
      headers: this.#headers(),
      body: JSON.stringify({ id: relationId, relation_type: newType })
    });
    return response.json();
  }

  async deleteRelation(relationId) {
    const response = await fetch('/data_exchange/delete_relation', {
      method: 'DELETE',
      headers: this.#headers(),
      body: JSON.stringify({ id: relationId })
    });
    return response.json();
  }

  async deleteAllDuplicateRelations() {
    const response = await fetch('/data_exchange/delete_duplicate_relations', {
      method: 'DELETE',
      headers: this.#headers()
    });
    return response.json();
  }

  async deleteDuplicateObservations(entityId) {
    const response = await fetch(`/api/v1/memory_entities/${entityId}/memory_observations/delete_duplicates`, {
      method: 'DELETE',
      headers: this.#headers()
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to delete duplicates');
    }
    return response.json();
  }

  async addTargetNameAsAlias(sourceId, targetName) {
    const entity = await this.fetchEntity(sourceId);
    const currentAliases = entity.aliases ? entity.aliases.trim() : '';
    const aliasArray = currentAliases ? currentAliases.split(',').map(a => a.trim()) : [];
    const targetNameTrimmed = targetName.trim();

    if (entity.name === targetNameTrimmed || aliasArray.includes(targetNameTrimmed)) return;

    const updatedAliases = currentAliases ? `${currentAliases}, ${targetNameTrimmed}` : targetNameTrimmed;
    await this.updateEntity(sourceId, { aliases: updatedAliases });
  }

  async fetchRootNodes() {
    const response = await fetch('/data_exchange/root_nodes');
    if (!response.ok) return [];
    const data = await response.json();
    return data.nodes || [];
  }

  async fetchOrphans() {
    const response = await fetch('/data_exchange/orphan_nodes');
    if (!response.ok) return [];
    const data = await response.json();
    return data.orphans || [];
  }

  async fetchDuplicateRelations() {
    const response = await fetch('/data_exchange/duplicate_relations');
    if (!response.ok) return { count: 0, duplicates: [] };
    return response.json();
  }

  async moveOrphanNode(nodeId, parentId) {
    const response = await fetch('/data_exchange/move_node', {
      method: 'POST',
      headers: this.#headers(),
      body: JSON.stringify({ node_id: nodeId, parent_id: parentId })
    });
    return response.json();
  }

  async mergeOrphanNode(sourceId, targetId) {
    const response = await fetch('/data_exchange/merge_node', {
      method: 'POST',
      headers: this.#headers(),
      body: JSON.stringify({ source_id: sourceId, target_id: targetId })
    });
    return response.json();
  }

  async deleteOrphanNode(nodeId) {
    const response = await fetch(`/data_exchange/delete_node?node_id=${nodeId}`, {
      method: 'DELETE',
      headers: this.#headers(false)
    });
    return response.json();
  }

  async startAsyncExport(ids) {
    const response = await fetch('/data_exchange/export_async', {
      method: 'POST',
      headers: this.#headers(),
      body: JSON.stringify({ ids })
    });
    return response.json();
  }
}

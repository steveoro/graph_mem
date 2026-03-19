# GraphMem REST API Reference

REST API for the GraphMem knowledge graph memory system. The API mirrors the capabilities of the 21 MCP tools, providing entity, observation, relation management, search, context scoping, bulk operations, and maintenance utilities.

## Base URL

```
http://localhost:3030/api/v1
```

## Swagger / OpenAPI

Interactive documentation is available at `/api-docs` when the server is running. The OpenAPI spec is at `swagger/v1/swagger.yaml`.

---

## Memory Entities

### List Entities (paginated)

`GET /api/v1/memory_entities`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| page | integer | 1 | Page number |
| per_page | integer | 20 | Items per page (max 100) |

**Response:** `200 OK`
```json
{
  "entities": [
    { "id": 1, "name": "MyProject", "entity_type": "Project", "aliases": "mp", "description": "...", "memory_observations_count": 5, "created_at": "...", "updated_at": "..." }
  ],
  "pagination": { "total_entities": 42, "per_page": 20, "current_page": 1, "total_pages": 3 }
}
```

### Show Entity (with observations and relations)

`GET /api/v1/memory_entities/:id`

**Response:** `200 OK` -- includes `observations`, `relations_from`, and `relations_to` arrays.

### Create Entity

`POST /api/v1/memory_entities`

```json
{ "memory_entity": { "name": "New Task", "entity_type": "Task", "aliases": "nt|task1", "description": "..." } }
```

Required: `name`, `entity_type`.

### Update Entity

`PATCH /api/v1/memory_entities/:id`

```json
{ "memory_entity": { "name": "Updated Name", "aliases": "", "description": "new desc" } }
```

### Delete Entity

`DELETE /api/v1/memory_entities/:id` -- `204 No Content`. Cascades to observations and relations.

### Search Entities (hybrid text + vector)

`GET /api/v1/memory_entities/search?q=search+term`

Returns relevance-ranked results with `relevance_score` and `matched_fields`. Context-aware when a project context is active.

### Merge Entity

`POST /api/v1/memory_entities/:id/merge_into/:target_id`

Merges source entity (`:id`) into target (`:target_id`): reassigns observations and relations, then deletes the source. Returns `204 No Content`.

---

## Memory Observations

Observations are nested under entities: `/api/v1/memory_entities/:memory_entity_id/memory_observations`

### List Observations

`GET .../memory_observations` -- `200 OK`

### Create Observation

`POST .../memory_observations`
```json
{ "memory_observation": { "content": "An important fact" } }
```

### Show / Update / Delete Observation

- `GET .../memory_observations/:id`
- `PATCH .../memory_observations/:id` with `{ "memory_observation": { "content": "updated" } }`
- `DELETE .../memory_observations/:id` -- `204 No Content`

### Delete Duplicate Observations

`DELETE .../memory_observations/delete_duplicates`

Removes duplicate observations (by content) for the entity, keeping the oldest.

---

## Memory Relations

### List/Filter Relations

`GET /api/v1/memory_relations`

| Parameter | Type | Description |
|-----------|------|-------------|
| from_entity_id | integer | Filter by source entity |
| to_entity_id | integer | Filter by target entity |
| relation_type | string | Filter by relation type |

### Create Relation

`POST /api/v1/memory_relations`
```json
{ "memory_relation": { "from_entity_id": 1, "to_entity_id": 2, "relation_type": "part_of" } }
```

### Show / Update / Delete

- `GET /api/v1/memory_relations/:id`
- `PATCH /api/v1/memory_relations/:id` with `{ "memory_relation": { "relation_type": "depends_on" } }`
- `DELETE /api/v1/memory_relations/:id` -- `204 No Content`

---

## Context

Manage the active project context. When set, search endpoints prioritize entities related to the active project.

### Get Context

`GET /api/v1/context`

Returns `{ status: "context_active", project_id, project_name, project_type, description }` or `{ status: "no_context" }`.

### Set Context

`POST /api/v1/context`
```json
{ "project_id": 283 }
```

### Clear Context

`DELETE /api/v1/context`

---

## Search

### Subgraph Search

`GET /api/v1/search/subgraph`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| q | string | (required) | Search term |
| search_in_name | boolean | true | Search entity names |
| search_in_type | boolean | true | Search entity types |
| search_in_aliases | boolean | true | Search aliases |
| search_in_observations | boolean | true | Search observation content |
| page | integer | 1 | Page number |
| per_page | integer | 20 | Items per page (max 100) |

Returns entities (with observations) and relations between them, paginated. Context-aware.

### Subgraph by IDs

`POST /api/v1/search/subgraph_by_ids`
```json
{ "entity_ids": [1, 2, 5] }
```

Returns the specified entities with observations and all relations exclusively between them.

---

## Bulk Operations

### Bulk Create

`POST /api/v1/bulk`

Atomic transaction supporting up to 50 total operations. Rolls back entirely on any error.

```json
{
  "entities": [{ "name": "New Entity", "entity_type": "Task", "observations": ["first obs"] }],
  "observations": [{ "entity_id": 1, "text_content": "new observation" }],
  "relations": [{ "from_entity_id": 1, "to_entity_id": 2, "relation_type": "part_of" }]
}
```

---

## Maintenance

### Suggest Merges

`GET /api/v1/maintenance/suggest_merges`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| threshold | float | 0.3 | Max cosine distance (0=identical, 1=unrelated) |
| limit | integer | 20 | Max suggestions |
| entity_type | string | (all) | Filter by entity type |

### Graph Stats

`GET /api/v1/maintenance/stats`

Returns totals (entities, observations, relations, audit_logs), entity type distribution, orphan count, stale count, most connected entities, and recently updated entities.

---

## Status & Utilities

### Health Check

`GET /api/v1/status` -- `{ "status": "ok", "version": "1.2.2" }`

### Current Time

`GET /api/v1/time` -- `{ "current_time": "2026-03-05T12:00:00Z" }`

---

## Graph Data (UI)

`GET /api/v1/graph_data`

| Parameter | Type | Description |
|-----------|------|-------------|
| entity_id | integer | Show subgraph centered on this entity (1-hop) |
| scoped_entity_id | integer | Show scoped subgraph (entity + part_of children) |
| root_only | boolean | Show only Project-type entities |

Returns Cytoscape.js-compatible `{ elements: [...], options: {...} }`.

---

## Error Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created |
| 204 | Deleted (no content) |
| 404 | Not found |
| 422 | Validation error |
| 500 | Server error |

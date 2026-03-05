# MCP Tools Documentation

Detailed reference for the 21 Model Context Protocol (MCP) tools available in GraphMem v1.2.

## Overview

MCP tools in GraphMem are Ruby classes that implement operations on the knowledge graph. Each tool is accessed via JSON-RPC calls from an MCP client. Tools auto-register via `ApplicationTool` inheritance.

## Recommended Session Workflow

Tools are designed to be used in four phases per session:

1. **Orient** -- `get_context` / `search_entities` / `set_context`
2. **Recall** -- `search_entities` / `search_subgraph` / `get_entity` / `get_subgraph_by_ids`
3. **Work** -- Execute the task, consulting the graph as needed
4. **Persist** -- `create_observation` / `create_entity` / `create_relation` / `bulk_update`

## Context Scoping (3 tools)

Context scoping allows search tools to **boost** entities related to the active project. When a context is set via `set_context`, both `search_entities` and `search_subgraph` prioritize in-context entities in their results (cross-project results still appear, but ranked lower).

Context is stored in a thread-local variable (`GraphMemContext`) and persists for the duration of the MCP connection.

#### `set_context`
- **Description:** Sets the active project context. Subsequent searches will prioritize entities related to this project via `part_of` relations.
- **Parameters:**
  - `project_id` (integer, required): The ID of the project entity to scope to.
- **Response:** `{ status, project_id, project_name, project_type }`

#### `get_context`
- **Description:** Returns the currently active project context, if any. Auto-clears if the project entity no longer exists.
- **Parameters:** None
- **Response:** `{ status, project_id, project_name, project_type, description }` or `{ status: "no_context" }`

#### `clear_context`
- **Description:** Clears the active project context. Searches return to global scope.
- **Parameters:** None

## Entity Management (4 tools)

#### `create_entity`
- **Description:** Creates a new entity. Performs auto-deduplication: if a semantically similar entity exists (cosine distance < 0.25), returns a warning with the existing entity instead of creating a duplicate.
- **Parameters:**
  - `name` (string, required): The unique name for the new entity.
  - `entity_type` (string, required): The type classification (auto-canonicalized, e.g., "workspace" becomes "Project").
  - `aliases` (string, optional): Pipe-separated alternative names.
  - `description` (string, optional): Short description of the entity.
  - `observations` (array of strings, optional): Initial observations.
- **Notes:** Entity types are automatically mapped to canonical forms via `EntityTypeMapping`. For example, "project", "workspace", "context", and "repo" all map to "Project".

#### `get_entity`
- **Description:** Retrieves an entity by ID, including observations and relations.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity.

#### `update_entity`
- **Description:** Updates entity name, type, aliases, and/or description.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity.
  - `name` (string, optional): New name (must be unique).
  - `entity_type` (string, optional): New type (auto-canonicalized).
  - `aliases` (string, optional): New aliases (replaces existing). Empty string clears.
  - `description` (string, optional): New description. Empty string clears.

#### `delete_entity`
- **Description:** Deletes an entity and all associated observations and relations.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity.

## Observation Management (2 tools)

#### `create_observation`
- **Description:** Adds an observation to an existing entity. Automatically generates a vector embedding for semantic search.
- **Parameters:**
  - `entity_id` (integer, required): The entity to attach the observation to.
  - `text_content` (string, required): The observation content.

#### `delete_observation`
- **Description:** Deletes an observation by ID.
- **Parameters:**
  - `observation_id` (integer, required): The ID of the observation.

## Relation Management (3 tools)

#### `create_relation`
- **Description:** Creates a typed relationship between two entities.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity ID.
  - `to_entity_id` (integer, required): Target entity ID.
  - `relation_type` (string, required): Relationship type (e.g., "part_of", "depends_on").

#### `delete_relation`
- **Description:** Deletes a relation by ID.
- **Parameters:**
  - `relation_id` (integer, required): The ID of the relation.

#### `find_relations`
- **Description:** Finds relations by optional filters. All filters use AND when combined.
- **Parameters:**
  - `from_entity_id` (integer, optional): Filter by source entity.
  - `to_entity_id` (integer, optional): Filter by target entity.
  - `relation_type` (string, optional): Filter by relation type.

## Search & Query Tools (4 tools)

#### `search_entities`
- **Description:** Hybrid search combining text tokenization with vector semantic similarity. Uses Reciprocal Rank Fusion (RRF) to merge text and vector results. Falls back to text-only when embeddings are unavailable. **Context-aware:** boosts in-context entities when a project context is active.
- **Parameters:**
  - `query` (string, required): The search term. Multiple words are tokenized for matching.
- **Response fields:** `entity_id`, `name`, `entity_type`, `description`, `aliases`, `memory_observations_count`, `relevance_score`, `matched_fields`

#### `list_entities`
- **Description:** Paginated listing of all entities.
- **Parameters:**
  - `page` (integer, optional, default: 1): Page number.
  - `per_page` (integer, optional, default: 20, max: 100): Entities per page.

#### `search_subgraph`
- **Description:** Searches across entity names, types, aliases, and observations. Returns a paginated subgraph with matching entities (including observations) and inter-entity relations. Merges vector search results when available. **Context-aware:** boosts in-context entities to the front of results.
- **Parameters:**
  - `query` (string, required): Search term.
  - `search_in_name` (boolean, optional, default: true)
  - `search_in_type` (boolean, optional, default: true)
  - `search_in_aliases` (boolean, optional, default: true)
  - `search_in_observations` (boolean, optional, default: true)
  - `page` (integer, optional, default: 1)
  - `per_page` (integer, optional, default: 20, max: 100)

#### `get_subgraph_by_ids`
- **Description:** Retrieves a set of entities by their IDs with observations and inter-entity relations.
- **Parameters:**
  - `entity_ids` (array of integers, required): Entity IDs to include.

## Batch & Maintenance Tools (3 tools)

#### `bulk_update`
- **Description:** Performs multiple operations in a single atomic transaction. Maximum 50 operations per call. Rolls back entirely on any error.
- **Parameters:**
  - `entities` (array, optional): Entities to create. Each: `{ name, entity_type, aliases?, description?, observations?[] }`
  - `observations` (array, optional): Observations to add. Each: `{ entity_id, text_content }`
  - `relations` (array, optional): Relations to create. Each: `{ from_entity_id, to_entity_id, relation_type }`

#### `suggest_merges`
- **Description:** Finds potential duplicate entities using vector cosine similarity. Returns pairs of entities that may represent the same concept.
- **Parameters:**
  - `threshold` (float, optional, default: 0.3): Maximum cosine distance (0 = identical, 1 = unrelated).
  - `limit` (integer, optional, default: 20): Maximum suggestions.
  - `entity_type` (string, optional): Filter to a specific entity type.
- **Response:** Array of `{ entity_a, entity_b, cosine_distance, recommendation }`

#### `get_graph_stats`
- **Description:** Returns health metrics and statistics about the knowledge graph: totals, entity type distribution, orphan count, stale entities (not updated in 6+ months), most connected entities, and recent updates.
- **Parameters:** None

## Utility Tools (2 tools)

#### `get_version`
- **Description:** Returns the current version of the GraphMem server.
- **Parameters:** None

#### `get_current_time`
- **Description:** Returns the current server time as an ISO 8601 string.
- **Parameters:** None

## Entity Type Canonicalization

GraphMem automatically normalizes entity types. When creating or updating entities, the `entity_type` field is looked up in the `entity_type_mappings` table. Known variants are rewritten to their canonical form:

| Canonical Type | Accepted Variants |
|---|---|
| Project | project, workspace, context, repo, repository, codebase |
| Task | task, todo |
| Issue | issue, bug, problem |
| Error | error, exception |
| PossibleSolution | solution, workaround, fix |
| Service | service |
| Component | component, widget |
| ... | (see `db/seeds/entity_type_mappings.rb` for full list) |

## Vector Search Architecture

GraphMem uses MariaDB 11.8's native VECTOR columns with the MHNSW algorithm for approximate nearest-neighbor search:

1. **Embedding generation**: On entity create/update, the `EmbeddingService` calls Ollama to generate a 768-dimensional vector from the entity's composite text (type + name + aliases + description).
2. **Storage**: Vectors are stored in `VECTOR(768)` columns with cosine distance indexes.
3. **Search**: `VectorSearchStrategy` embeds the query and finds nearest entities via `VEC_DISTANCE_COSINE`.
4. **Hybrid fusion**: `HybridSearchStrategy` merges text and vector results using Reciprocal Rank Fusion (RRF). When a project context is active, in-context entities receive a score boost.

The embedding service is configurable via environment variables (`OLLAMA_URL`, `EMBEDDING_MODEL`, etc.) and gracefully degrades when unavailable.

## Error Handling

Custom error classes:

- `McpGraphMemErrors::ResourceNotFound` -- requested entity/relation not found
- `McpGraphMemErrors::InternalServerError` -- unexpected server error
- `FastMcp::Tool::InvalidArgumentsError` -- invalid input parameters

## Best Practices

1. **Use `set_context`** at the start of each session to scope searches to the active project.
2. **Search before create** to avoid duplicates (auto-dedup catches some, not all).
3. **Use `bulk_update`** for session-end "save what I learned" operations.
4. **Run `suggest_merges`** periodically to identify and clean up duplicate entities.
5. **Keep observations concise** and factual for better embedding quality.
6. **Clear context** (`clear_context`) when switching between projects.

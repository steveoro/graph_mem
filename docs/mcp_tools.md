# MCP Tools Documentation

This document provides detailed information about the Model Context Protocol (MCP) tools available in GraphMem v1.0.

## Overview

MCP tools in GraphMem are Ruby classes that implement specific operations on the knowledge graph. Each tool is accessed via JSON-RPC calls, managed by an MCP client. Tools auto-register via `ApplicationTool` inheritance.

## Available Tools

### Utility Tools

#### `get_version`
- **Description:** Returns the current version of the GraphMem server.
- **Parameters:** None

#### `get_current_time`
- **Description:** Returns the current server time as an ISO 8601 string.
- **Parameters:** None

### Entity Management

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

### Observation Management

#### `create_observation`
- **Description:** Adds an observation to an existing entity. Automatically generates a vector embedding for semantic search.
- **Parameters:**
  - `entity_id` (integer, required): The entity to attach the observation to.
  - `text_content` (string, required): The observation content.

#### `delete_observation`
- **Description:** Deletes an observation by ID.
- **Parameters:**
  - `observation_id` (integer, required): The ID of the observation.

### Relation Management

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
- **Description:** Finds relations by optional filters.
- **Parameters:**
  - `from_entity_id` (integer, optional): Filter by source entity.
  - `to_entity_id` (integer, optional): Filter by target entity.
  - `relation_type` (string, optional): Filter by relation type.

### Search & Query Tools

#### `search_entities`
- **Description:** Hybrid search combining text tokenization with vector semantic similarity. Uses Reciprocal Rank Fusion to merge text and vector results. Falls back to text-only when embeddings are unavailable.
- **Parameters:**
  - `query` (string, required): The search term. Multiple words are tokenized for matching.
- **Response fields:** `entity_id`, `name`, `entity_type`, `description`, `aliases`, `memory_observations_count`, `relevance_score`, `matched_fields`

#### `list_entities`
- **Description:** Paginated listing of all entities.
- **Parameters:**
  - `page` (integer, optional, default: 1): Page number.
  - `per_page` (integer, optional, default: 20, max: 100): Entities per page.

#### `search_subgraph`
- **Description:** Searches across entity names, types, aliases, and observations. Returns a paginated subgraph with matching entities (including observations) and inter-entity relations. Automatically merges vector search results when available.
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

### Context Scoping

#### `set_context`
- **Description:** Sets the active project context. Useful for scoping subsequent operations to a specific project.
- **Parameters:**
  - `project_id` (integer, required): The ID of the project entity to scope to.
- **Response:** `{ status, project_id, project_name, project_type }`

#### `get_context`
- **Description:** Returns the currently active project context, if any.
- **Parameters:** None
- **Response:** `{ status, project_id, project_name, project_type, description }` or `{ status: "no_context" }`

#### `clear_context`
- **Description:** Clears the active project context.
- **Parameters:** None

### Batch & Maintenance Tools

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

## Entity Type Canonicalization

GraphMem v1.0 introduces automatic entity type normalization. When creating or updating entities, the `entity_type` field is looked up in the `entity_type_mappings` table. Known variants are rewritten to their canonical form:

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

New mappings can be added via `db/seeds/entity_type_mappings.rb` or directly in the `entity_type_mappings` table.

## Vector Search Architecture

GraphMem uses MariaDB 11.8's native VECTOR columns with the MHNSW algorithm for approximate nearest-neighbor search:

1. **Embedding generation**: On entity create/update, the `EmbeddingService` calls Ollama to generate a 768-dimensional vector from the entity's composite text (type + name + aliases + description).
2. **Storage**: Vectors are stored in `VECTOR(768)` columns with cosine distance indexes.
3. **Search**: `VectorSearchStrategy` embeds the query and finds nearest entities via `VEC_DISTANCE_COSINE`.
4. **Hybrid fusion**: `HybridSearchStrategy` merges text and vector results using Reciprocal Rank Fusion (RRF).

The embedding service is configurable via environment variables (`OLLAMA_URL`, `EMBEDDING_MODEL`, etc.) and gracefully degrades when unavailable.

## Error Handling

Custom error classes:

- `McpGraphMemErrors::ResourceNotFound` -- requested entity/relation not found
- `McpGraphMemErrors::InternalServerError` -- unexpected server error
- `FastMcp::Tool::InvalidArgumentsError` -- invalid input parameters

## Best Practices

1. **Search before create** to avoid duplicates (auto-dedup helps but isn't foolproof for text-only search)
2. **Use `set_context`** when working on a specific project to improve relevance
3. **Use `bulk_update`** for session-end "save what I learned" operations
4. **Run `suggest_merges`** periodically to identify and clean up duplicate entities
5. **Keep observations concise** and factual for better embedding quality

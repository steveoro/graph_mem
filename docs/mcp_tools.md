# MCP Tools Documentation

Detailed reference for the 29 Model Context Protocol (MCP) tools available in GraphMem.

## Overview

MCP tools in GraphMem are Ruby classes that implement operations on the knowledge graph. Each tool is accessed via JSON-RPC calls from an MCP client. Tools auto-register via `ApplicationTool` inheritance.

## Standard Compatibility

All tools accept both graph_mem's native snake_case/ID-based parameters and the `@modelcontextprotocol/server-memory` camelCase/name-based conventions. A `ParameterNormalizer` layer automatically converts incoming parameters before validation:

- **camelCase keys** are converted to snake_case (e.g. `entityType` becomes `entity_type`)
- **Entity names** (strings) are resolved to integer entity IDs where an ID is expected
- **Field aliases** are normalized (`content` to `text_content`, `from`/`to` to `from_entity_id`/`to_entity_id`)
- **`operations` array** is supported by `bulk_update` as an alternative to three separate arrays

## Recommended Session Workflow

Tools are designed to be used in four phases per session:

1. **Orient** -- `get_context` / `search_entities` / `set_context`
2. **Recall** -- `search_entities` / `search_subgraph` / `get_entity` / `get_subgraph_by_ids`
3. **Work** -- Execute the task, consulting the graph as needed
4. **Persist** -- `create_observation` / `create_entity` / `create_relation` / `bulk_update`

## Context Scoping (3 tools)

Context scoping allows search tools to **boost** entities related to the active project. When a context is set via `set_context`, both `search_entities` and `search_subgraph` prioritize in-context entities in their results (cross-project results still appear, but ranked lower).

Context is stored per MCP client in the `agent_contexts` table, keyed by the `X-MCP-Client` request header. Agents without the header share the `"default"` bucket.

#### `set_context`
- **Description:** Sets the active project context. Subsequent searches will prioritize entities related to this project via `part_of` relations. Accepts entity_id (integer) or entity name (string).
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity to set as context. Also accepts entity name (string).
- **Response:** `{ status, entity_id, entity_name, entity_type }`

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
- **Description:** Retrieves an entity by ID, including observations and relations. Accepts entity_id (integer) or entity name (string).
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations.
  - `include_ranked` (boolean, optional, default: false): Sort observations by trust score descending.

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
  - `reason` (string, optional): Reason for the deletion (e.g., "duplicate" or "API/operator"). Recorded in the audit log.

## Observation Management (3 tools)

#### `create_observation`
- **Description:** Adds an observation to an existing entity. Automatically generates a vector embedding for semantic search. Accepts entity_id (integer) or entity name (string). Observation text accepted via `text_content`, `content`, or `contents`.
- **Parameters:**
  - `entity_id` (integer, required): The entity to attach the observation to. Also accepts entity name (string).
  - `text_content` (string, required): The observation content. Also accepted as `content`.
  - `confidence` (number, optional): Confidence score from 0.0 to 1.0.
  - `source` (string, optional): Source or provenance identifier.
  - `valid_from` / `valid_until` (ISO 8601 strings, optional): Validity window.
  - `tags` (array of strings, optional): Structured tags.
- **Embedding refresh:** Changes to content, source, or tags regenerate the observation embedding; confidence and validity-only changes do not.

#### `update_observation`
- **Description:** Updates an active observation in place or creates a replacement version while retaining the original as superseded. Inactive observations cannot be edited.
- **Parameters:**
  - `observation_id` (integer, required): The active observation to update.
  - `text_content` (string, optional): Replacement content.
  - `confidence`, `source`, `valid_from`, `valid_until`, `tags` (optional): Structured metadata updates.
  - `supersede` (boolean, optional, default: false): Create a new active observation and link the original to it with status `superseded`.
  - `reason` (string, optional): Reason for supersession.
- **Lifecycle:** Active observations appear in reads, traversal, relationship discovery, and observation search by default. `get_entity(include_obsolete: true)` and REST/resource `include_obsolete=true` expose retained history.

#### `delete_observation`
- **Description:** Marks an observation `obsolete` by ID instead of deleting it. Repeating the operation on an inactive observation is safe.
- **Parameters:**
  - `observation_id` (integer, required): The ID of the observation.
  - `reason` (string, optional): Reason for obsolescence.

#### `rank_observations`
- **Description:** Returns an entity's observations sorted by trust score, with the most reliable observation first. Each observation now exposes a `trust_score` field.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations in the ranking.
  - `limit` (integer, optional): Maximum number of observations to return.

#### `detect_contradictions`
- **Description:** Scans an entity's active observations (and observations from 1-hop related entities) for pairs that are semantically similar but have opposite polarity. Candidate contradictions are returned and stored as a `contradictions` `MaintenanceReport` for operator review.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `max_distance` (number, optional, default: 0.35): Maximum cosine distance threshold (smaller = stricter).
  - `max_results` (integer, optional, default: 20): Maximum candidate pairs to return.

## Relation Management (3 tools)

#### `create_relation`
- **Description:** Creates a typed relationship between two entities. Accepts entity IDs (integer) or entity names (string) for from/to endpoints.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity ID. Also accepts entity name (string) via `from_entity_id`, `from_entity`, or `from`.
  - `to_entity_id` (integer, required): Target entity ID. Also accepts entity name (string) via `to_entity_id`, `to_entity`, or `to`.
  - `relation_type` (string, required): Relationship type (e.g., "part_of", "depends_on").
  - `weight` (number, optional): Non-negative relation weight.
  - `confidence` (number, optional): Confidence score from 0.0 to 1.0.
  - `properties` (object, optional): Arbitrary structured relation properties.
- **Notes:** Known relation-type variants are mapped to canonical values via `RelationTypeMapping`.

#### `delete_relation`
- **Description:** Deletes a relation by ID.
- **Parameters:**
  - `relation_id` (integer, required): The ID of the relation.
  - `reason` (string, optional): Reason for the deletion. Recorded in the audit log.

#### `find_relations`
- **Description:** Finds relations by optional filters. All filters use AND when combined.
- **Parameters:**
  - `from_entity_id` (integer, optional): Filter by source entity.
  - `to_entity_id` (integer, optional): Filter by target entity.
  - `relation_type` (string, optional): Filter by relation type; known variants are canonicalized.

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

## Graph Traversal (2 tools)

These tools perform multi-hop graph traversal. Unlike `find_relations` (which is single-hop), they walk the graph breadth-first from a starting entity. `direction` is one of `outgoing` (source -> target), `incoming` (target <- source), or `both` (default).

#### `traverse_graph`
- **Description:** Performs a bounded, multi-hop breadth-first traversal from an entity. Returns the reachable entities (with observations) and the relations connecting them.
- **Parameters:**
  - `start_entity_id` (integer, required): The entity to start from. Also accepts entity name (string).
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to expand.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
  - `max_entities` (integer, optional, default: 100, max: 1000): Maximum number of entities to return.
- **Response:** `{ entities: [...], relations: [...], traversal: { start_entity_id, max_depth, direction, visited_depth, truncated } }`. `truncated` is `true` when the `max_entities` cap stopped expansion.

#### `find_shortest_path`
- **Description:** Finds the shortest path (by hop count) between two entities using bounded breadth-first search.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity. Also accepts entity name (string).
  - `to_entity_id` (integer, required): Target entity. Also accepts entity name (string).
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to search.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
- **Response:** `{ found, hop_count, direction, entities: [...], relations: [...] }`. When no path exists within `max_depth`, `found` is `false`, `hop_count` is `null`, and `entities`/`relations` are empty.

## Batch & Maintenance Tools (6 tools)

#### `bulk_update`
- **Description:** Performs multiple operations in a single atomic transaction. Maximum 50 operations per call. Rolls back entirely on any error. Accepts three separate arrays or an `operations` array with type-discriminated items. Entity references accept both entity_id (integer) and entity name (string).
- **Parameters (canonical format):**
  - `entities` (array, optional): Entities to create. Each: `{ name, entity_type, aliases?, description?, observations?[] }`
  - `observations` (array, optional): Observations to add. Each: `{ entity_id, text_content }`
  - `relations` (array, optional): Relations to create. Each: `{ from_entity_id, to_entity_id, relation_type }`
- **Parameters (operations format):**
  - `operations` (array, optional): Type-discriminated items. Each has a `type` field (`create_entity`, `create_observation`, `create_relation`) plus the relevant fields for that operation type.

#### `suggest_merges`
- **Description:** Finds potential duplicate entities using vector cosine similarity. Returns pairs of entities that may represent the same concept.
- **Parameters:**
  - `threshold` (float, optional, default: 0.3): Maximum cosine distance (0 = identical, 1 = unrelated).
  - `limit` (integer, optional, default: 20): Maximum suggestions.
  - `entity_type` (string, optional): Filter to a specific entity type.
- **Response:** Array of `{ entity_a, entity_b, cosine_distance, recommendation }`

#### `merge_entities`
- **Description:** Merges a source entity into a target entity using `NodeOperationsStrategy`. Transfers observations, re-parents relations, adds the source name to target aliases, and deletes the source.
- **Parameters:**
  - `source_entity_id` (integer, required): Entity to merge from (deleted).
  - `target_entity_id` (integer, required): Entity to merge into (kept).

#### `dream_state_status`
- **Description:** Reports the background dream-state compaction run: `dream_state` (idle/running/paused/completed/failed), `phase`, `cursor_entity_id`, `stats`, and timestamps.
- **Parameters:** None

#### `get_maintenance_reports`
- **Description:** Retrieves recent maintenance and dream-state compaction reports, including the `compaction_review` queue of merge/orphan suggestions awaiting manual review. Pair with `merge_entities` to action queued duplicates.
- **Parameters:**
  - `report_type` (string, optional): One of `orphans`, `duplicates`, `compaction_review`. Omit to get the latest report of each type.
  - `limit` (integer, optional, default: 5, max: 30): Maximum number of reports to return (applies when `report_type` is given).
- **Response:** `{ reports: [{ id, report_type, created_at, data }], total }`

#### `get_graph_stats`
- **Description:** Returns health metrics and statistics about the knowledge graph: totals, entity type distribution, orphan count, most connected entities, and recent updates.
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

The embedding service is configurable via **System Settings → Embeddings** (AppSettings) or environment variables (`OLLAMA_URL`, `EMBEDDING_MODEL`, etc.). Resolution priority: AppSettings → ENV → defaults. It gracefully degrades when unavailable.

## Error Handling

Custom error classes:

- `McpGraphMemErrors::ResourceNotFound` -- requested entity/relation not found
- `McpGraphMemErrors::InternalServerError` -- unexpected server error
- `FastMcp::Tool::InvalidArgumentsError` -- invalid input parameters

## Tool Overlap Guide

Some tools overlap by design; pick by intent:

| Goal | Prefer | Alternative |
|---|---|---|
| Find entities by keyword/semantic match | `search_entities` | `search_subgraph` (when you also need observation text and relations in one payload) |
| Load known entities by ID | `get_subgraph_by_ids` | `get_entity` (single entity with full detail) |
| Explore multi-hop neighborhoods | `traverse_graph` | `find_relations` (single-hop edges only) |
| Find how two entities connect | `find_shortest_path` | `traverse_graph` (full neighborhood) |
| Review duplicate entities | `suggest_merges` | `get_maintenance_reports` (the dream-state `compaction_review` queue) |
| Inspect background compaction state | `dream_state_status` | `get_maintenance_reports` (queued review items) |
| Execute a merge | `merge_entities` | Web cleanup UI / REST API |

## Dream-State Background Compaction

Solid Queue runs `DreamStateCompactionJob` on a schedule (`config/recurring.yml`). The job:

1. **Orphans phase** -- matches orphan nodes to `Project` roots; auto-parents high-confidence token matches
2. **Tree-walk phase** -- walks each project subtree; deduplicates identical observations; auto-merges entities with cosine distance &lt; 0.10
3. **Review queue** -- writes lower-confidence items to `maintenance_reports` (`compaction_review`), readable via `get_maintenance_reports`

Mutating and heavy search tools cooperatively **pause** an active compaction run (`CompactionValve`) so live MCP traffic takes priority. Paused runs resume from `cursor_entity_id` on the next trigger.

To close the loop on the review queue: call `get_maintenance_reports(report_type: "compaction_review")`, inspect the suggested merges/parents, and apply the good ones with `merge_entities`.

## Best Practices

1. **Set `X-MCP-Client`** in your MCP config when multiple agents share one GraphMem instance.
2. **Use `set_context`** at the start of each session to scope searches to the active project.
3. **Search before create** to avoid duplicates (auto-dedup catches some, not all).
4. **Use `bulk_update`** for session-end "save what I learned" operations.
5. **Run `suggest_merges`** or check `dream_state_status` for compaction progress and review queues.
6. **Keep observations concise** and factual for better embedding quality.
7. **Clear context** (`clear_context`) when switching between projects.

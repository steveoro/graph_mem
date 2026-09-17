# MCP Tools Documentation

Detailed reference for GraphMem's 22 advertised Model Context Protocol (MCP) tools and eighteen
hidden compatibility aliases.

## Overview

MCP tools in GraphMem are Ruby classes that implement operations on the knowledge graph. Each tool is accessed via JSON-RPC calls from an MCP client. Tools auto-register via `ApplicationTool` inheritance.

## Connection Profiles

GraphMem currently registers 40 callable tool classes and filters the advertised catalog by
connection URL:

- `/mcp` — 12 canonical context, read, and mutation tools
- `/mcp/readonly` — 9 canonical context and read tools
- `/mcp/maintenance` — all 22 canonical tools
- `/mcp/sse` and `/mcp/messages` — legacy transport using the default profile

Profiles govern call eligibility; calling a tool outside the selected profile returns `Tool not
found`. The eighteen compatibility aliases remain callable in their profiles but are omitted from
`tools/list`, allowing old clients to migrate without imposing their schemas on new sessions.
Profiles are selected when connecting and are not authorization boundaries.
Every tool also publishes the standard MCP `readOnlyHint`, `destructiveHint`,
`idempotentHint`, and `openWorldHint` annotations.

## Standard Compatibility

All tools accept both graph_mem's native snake_case/ID-based parameters and the `@modelcontextprotocol/server-memory` camelCase/name-based conventions. A `ParameterNormalizer` layer automatically converts incoming parameters before validation:

- **camelCase keys** are converted to snake_case (e.g. `entityType` becomes `entity_type`)
- **Entity names** (strings) are resolved to integer entity IDs where an ID is expected
- **Field aliases** are normalized (`content` to `text_content`, `from`/`to` to `from_entity_id`/`to_entity_id`)
- **`operations` arrays** drive `graph_write`, `graph_edit`, and `graph_delete`

## Recommended Session Workflow

Tools are designed to be used in four phases per session:

1. **Orient** -- `get_context` / `search` / `set_context`
2. **Recall** -- `search` / `get_entities` / `traverse_graph`
3. **Work** -- Execute the task, consulting the graph as needed
4. **Persist** -- `graph_write` / `graph_edit` / `graph_delete`

The same workflow is available through MCP prompts: `orient`, `recall` (with a
required `topic`), and `persist`.

## Successful Tool Metadata

Every successful tool result includes `version` and, where useful,
`next_move`. Calls made without an active project also include a compact
`context: { status: "none", next_move: ... }` banner. FastMCP `_meta` mirrors
`graphMemVersion` and `contextStatus`.

## Context Scoping (2 advertised tools)

Context scoping allows search tools to **boost** entities related to the active project. The recursive `part_of` subtree is bounded; when the cap is reached, context-aware responses expose `scope_truncated: true` and continue with the partial scope. When a context is set via `set_context`, `search` prioritizes in-context query matches (cross-project results still appear, but ranked lower).

Context is stored per MCP client in the `agent_contexts` table, keyed by the `X-MCP-Client` request header. Agents without the header share the `"default"` bucket.

#### `set_context`
- **Description:** Set this MCP client's active project so `search` boosts in-context matches without hard-filtering results. Pass required `entity_id` as an integer/name, or null to clear context.
- **Parameters:**
  - `entity_id` (integer, string, or null; required): Project ID/name, or null for global scope.
- **Response:** `{ status, entity_id, entity_name, entity_type }`, plus `warning` and `next_move` when this client id appears to be shared by more than one agent (see [Shared client ids](#shared-client-ids))

#### `get_context`
- **Description:** Read this MCP client's active project context (entity and scope fields, or status no_context); auto-clears if the project entity is gone. Use `set_context` with null to clear it.
- **Parameters:** None
- **Response:** `{ status, entity_id, entity_name, entity_type, description, context_set_at, scope_entity_count, scope_truncated, scope_max_entities }` or `{ status: "no_context" }`, plus `warning` and `next_move` when this client id appears to be shared (see [Shared client ids](#shared-client-ids))

#### Shared client ids

Context is stored per `X-MCP-Client` value, so two agents sending the same value share one
`agent_contexts` row and silently rescope each other whenever either calls `set_context`.

GraphMem detects this two ways and adds `warning` plus `next_move` to the `set_context` and
`get_context` responses:

- **Context change conflict** — `set_context` overwrites a *different* project that was set under
  the same client id within the last 5 minutes. Works on every transport.
- **Concurrent session** — a different `Mcp-Session-Id` called a tool under the same client id
  within the same window. Only available on the Streamable HTTP endpoint; the legacy `/mcp/sse`
  endpoint has no per-connection id.

The fix is always the same: give each agent its own `X-MCP-Client` header value.

#### `clear_context` (compatibility alias)
- **Description:** Hidden alias for `set_context(entity_id: null)`.
- **Parameters:** None

## Graph Mutation (3 tools)

#### `graph_write`
- **Description:** Atomically create up to 50 entities, observations, and relations through type-discriminated `operations`; the former three-array bulk format is also accepted.
- **Operation types:** `create_entity`, `create_observation`, `create_relation`.
- **Duplicate policy:** Any possible entity or relation duplicate prevents the
  entire batch and returns `{ status: "possible_duplicate", kind,
  operation_index, submitted, candidates, next_move }`.
- **Soft vocabularies:** `entity_type` and `relation_type` schemas publish
  canonical `examples`. Novel values remain valid; likely misspellings add a
  non-blocking `type_hint` to the created result.

#### `graph_edit`
- **Description:** Atomically update entities and observations, including observation supersession.
- **Operation types:** `update_entity`, `update_observation`.

#### `graph_delete`
- **Description:** Atomically delete entities/relations, obsolete observations, or merge entities. Project-root protection and per-operation audit reasons remain enforced.
- **Operation types:** `delete_entity`, `delete_observation`, `delete_relation`, `merge_entities`.

All three tools accept at most 50 logical operations and return `{ mode: "batch", status,
results, summary }`. Any failed operation rolls back the full batch.

## Legacy Entity Mutation Aliases

#### `create_entity`
- **Description:** Create a single new entity node. Pass required `name` (string) and `entity_type` (string); optional `observations` (array of strings), `aliases` (pipe-separated string), `description` (string). Alias `entityType` maps to `entity_type`. Types are canonicalized; cosine distance < 0.25 returns a warning instead of creating. Do not use until you have searched for an existing node; use `search` first. Do not use to add facts to a known entity; use `create_observation` instead. Do not use to change metadata on an existing node; use `update_entity` instead. Do not use for an atomic batch of up to 50 creates; use `bulk_update` instead.
- **Parameters:**
  - `name` (string, required): The unique name for the new entity.
  - `entity_type` (string, required): The type classification (auto-canonicalized, e.g., "workspace" becomes "Project").
  - `aliases` (string, optional): Pipe-separated alternative names.
  - `description` (string, optional): Short description of the entity.
  - `observations` (array of strings, optional): Initial observations.
- **Notes:** Entity types are automatically mapped to canonical forms via `EntityTypeMapping`. For example, "project", "workspace", "context", and "repo" all map to "Project".

#### `get_entities`
- **Description:** Retrieve one or more known entities with observations and an explicit relation projection. One unique ID defaults `relations` to `all`; multiple IDs default to `internal`.
- **Parameters:**
  - `entity_ids` (array, required): Entity IDs or resolvable names, returned in input order.
  - `relations` (string, optional): `all` incident edges or only `internal` edges.
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations.
  - `include_ranked` (boolean, optional, default: false): Sort observations by trust score descending.
  - `query` (string, optional): Rank observations by query relevance before trust.
  - `observation_limit` (integer, optional): Return at most this many observations per entity.
- **Response:** `{ entities, relations, missing_entity_ids, relation_scope }`.

#### `update_entity`
- **Description:** Update metadata of an existing entity (not observations). Pass required `entity_id` (integer); optional `name` (unique string), `entity_type` (canonicalized string), `aliases` (replaces existing; empty string clears), `description` (empty string clears). Do not use to add or edit facts; use `create_observation` or `update_observation` instead. Do not use to create a node; use `create_entity` instead. Do not use to read; use `get_entities` instead. Do not use to delete; use `delete_entity` instead. Do not use to combine two entities; use `merge_entities` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity.
  - `name` (string, optional): New name (must be unique).
  - `entity_type` (string, optional): New type (auto-canonicalized).
  - `aliases` (string, optional): New aliases (replaces existing). Empty string clears.
  - `description` (string, optional): New description. Empty string clears.

#### `delete_entity`
- **Description:** Destroy one entity and cascade-delete its observations and relations. Pass required `entity_id` (integer); optional `reason` (string, audit log). Do not use when the entity is a duplicate of another; use `merge_entities` instead. Do not use to obsolete a single fact; use `delete_observation` instead. Do not use to remove a single edge; use `delete_relation` instead. Do not use to change metadata without deleting; use `update_entity` instead. Do not use to leave this client's project scope; use `clear_context` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity.
  - `reason` (string, optional): Reason for the deletion (e.g., "duplicate" or "API/operator"). Recorded in the audit log.

## Observation Management (5 tools)

#### `create_observation`
- **Description:** Add a new fact to an existing entity and generate an embedding. Pass required `entity_id` (integer; also accepts entity name) and `text_content` (string); optional `confidence` (float 0-1), `source` (string), `valid_from` (ISO 8601 string), `valid_until` (ISO 8601 string), `tags` (array of strings). Aliases `content`/`contents` map to `text_content`. Do not use to edit or supersede an existing observation; use `update_observation` instead. Do not use to mark a fact obsolete; use `delete_observation` instead. Do not use to create a new node; use `create_entity` instead. Do not use for a batch of up to 50 creates; use `bulk_update` instead.
- **Parameters:**
  - `entity_id` (integer, required): The entity to attach the observation to. Also accepts entity name (string).
  - `text_content` (string, required): The observation content. Also accepted as `content`.
  - `confidence` (number, optional): Confidence score from 0.0 to 1.0.
  - `source` (string, optional): Source or provenance identifier.
  - `valid_from` / `valid_until` (ISO 8601 strings, optional): Validity window.
  - `tags` (array of strings, optional): Structured tags.
- **Embedding refresh:** Changes to content, source, or tags regenerate the observation embedding; confidence and validity-only changes do not.

#### `update_observation`
- **Description:** Edit an active observation in place or, with supersede true, create a replacement and mark the original superseded. Pass required `observation_id` (integer); optional `text_content`, `confidence`, `source`, `valid_from`, `valid_until`, `tags`, `supersede` (bool, default false), `reason`. Inactive observations cannot be edited. Do not use to add a new fact; use `create_observation` instead. Do not use to obsolete a fact without replacement; use `delete_observation` instead. Do not use to change entity metadata; use `update_entity` instead.
- **Parameters:**
  - `observation_id` (integer, required): The active observation to update.
  - `text_content` (string, optional): Replacement content.
  - `confidence`, `source`, `valid_from`, `valid_until`, `tags` (optional): Structured metadata updates.
  - `supersede` (boolean, optional, default: false): Create a new active observation and link the original to it with status `superseded`.
  - `reason` (string, optional): Reason for supersession.
- **Lifecycle:** Active observations appear in reads, traversal, relationship discovery, and observation search by default. `get_entities(entity_ids: [...], include_obsolete: true)` and REST/resource `include_obsolete=true` expose retained history.

#### `delete_observation`
- **Description:** Mark one observation obsolete so it is excluded from default reads and search; does not delete entities or relations. Pass required `observation_id` (integer); optional `reason` (string). Repeating on an inactive observation is safe. Do not use to replace a fact while retaining history; use `update_observation` with supersede true instead. Do not use to add a fact; use `create_observation` instead. Do not use to destroy an entity; use `delete_entity` instead.
- **Parameters:**
  - `observation_id` (integer, required): The ID of the observation.
  - `reason` (string, optional): Reason for obsolescence.

#### `rank_observations`
- **Description:** Return one known entity's observations sorted by trust_score (most reliable first). Pass required `entity_id` (integer; also accepts entity name); optional `include_obsolete` (bool, default false), `limit` (integer, default all), `query` (string; relevance then trust). Do not use when you also need relations or entity metadata; use `get_entities` instead. Do not use for opposing observation pairs; use `detect_contradictions` instead. Do not use to find observations across entities by keyword; use `search` instead. Do not use for a topic answer; use `summarize` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `include_obsolete` (boolean, optional, default: false): Include obsolete and superseded observations in the ranking.
  - `limit` (integer, optional): Maximum number of observations to return.
  - `query` (string, optional): Rank by query relevance before trust.

#### `detect_contradictions`
- **Description:** Scan an entity's active observations and 1-hop related observations for semantically similar pairs with opposite polarity; returns candidates and stores a contradictions MaintenanceReport. Pass required `entity_id` (integer; also accepts entity name); optional `max_distance` (float, default 0.35), `max_results` (integer, default 20). Does not merge or delete. Do not use for trust ranking; use `rank_observations` instead. Do not use for duplicate entities; use `suggest_merges` instead. Do not use to read stored reports; use `get_maintenance_reports` instead. Do not use to resolve a conflicting fact; use `update_observation` or `delete_observation` instead.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity. Also accepts entity name (string).
  - `max_distance` (number, optional, default: 0.35): Maximum cosine distance threshold (smaller = stricter).
  - `max_results` (integer, optional, default: 20): Maximum candidate pairs to return.

## Relation Management (2 tools)

#### `create_relation`
- **Description:** Add one directed edge between two existing entities. Pass required `from_entity_id` (integer or name; aliases `from_entity`, `from`), `to_entity_id` (integer or name; aliases `to_entity`, `to`), and `relation_type` (string, canonicalized); optional `weight` (float >=0), `confidence` (float 0-1), `properties` (hash). Do not use to create nodes; use `create_entity` instead. Do not use to batch-create relations; use `bulk_update` instead. Do not use to query existing 1-hop edges; use `traverse_graph` instead. Do not use for a multi-hop neighborhood; use `traverse_graph` instead. Do not use to remove an edge; use `delete_relation` instead.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity ID. Also accepts entity name (string) via `from_entity_id`, `from_entity`, or `from`.
  - `to_entity_id` (integer, required): Target entity ID. Also accepts entity name (string) via `to_entity_id`, `to_entity`, or `to`.
  - `relation_type` (string, required): Relationship type (e.g., "part_of", "depends_on").
  - `weight` (number, optional): Non-negative relation weight.
  - `confidence` (number, optional): Confidence score from 0.0 to 1.0.
  - `properties` (object, optional): Arbitrary structured relation properties.
- **Notes:** Known relation-type variants are mapped to canonical values via `RelationTypeMapping`.

#### `delete_relation`
- **Description:** Delete one graph edge by id without deleting either entity. Pass required `relation_id` (integer); optional `reason` (string, audit log). Do not use if you lack a relation_id; use `traverse_graph` first. Do not use to remove an entity and its relations; use `delete_entity` instead. Do not use for queued duplicate-relation cleanup; use `apply_maintenance_review` instead. Do not use to add an edge; use `create_relation` instead.
- **Parameters:**
  - `relation_id` (integer, required): The ID of the relation.
  - `reason` (string, optional): Reason for the deletion. Recorded in the audit log.

## Search & Query Tools (3 tools)

#### `search`
- **Description:** Select summary, projected subgraph, or catalog mode from the presence of `query` and `include`, always returning a hash with `mode`.
- **Parameters:**
  - `query` (string, optional): Omit for catalog mode; provide for summary or subgraph mode.
  - `include` (array, optional): `observations` and/or `relations`; either selects subgraph mode.
  - `page` (integer, optional, default: 1): Page number.
  - `per_page` (integer, optional, default: 20, max: 100): Results per page.
  - `limit` (integer, optional): Legacy alias for `per_page`; ignored when `per_page` is present.
  - `search_in_name`, `search_in_type`, `search_in_aliases`, `search_in_observations` (boolean, optional): Subgraph search fields.
- **Responses:**
  - Summary: `{ mode: "summary", results, pagination, retrieval }`
  - Subgraph: `{ mode: "subgraph", entities, pagination, retrieval, relations? }`; observations are included on entities only when requested.
  - Catalog: `{ mode: "catalog", entities, pagination }`

#### `get_entities`

See [Entity Management](#entity-management-4-tools).

#### Compatibility aliases

`search_entities`, `search_subgraph`, `list_entities`, `get_entity`,
`get_subgraph_by_ids`, `find_relations`, `create_entity`, `create_observation`,
`create_relation`, `bulk_update`, `update_entity`, `update_observation`,
`delete_entity`, `delete_observation`, `delete_relation`, `merge_entities`,
`clear_context`, and `get_version`
remain callable with their prior schemas and response shapes. They are
deprecated and omitted from `tools/list`; new clients should not discover or
select them.

#### `summarize`
- **Description:** Summarize what the knowledge graph knows about a topic with deterministic source-backed evidence (optional LLM synthesis). Pass required `query` (string); optional `entity_id` (integer), `max_results` (integer, default 10), `max_observations` (integer, default 20), `observations_per_entity` (integer; 0 disables cap), `max_depth` (integer, default 0), `include_sources` (bool, default true), `scope` (string: context or global), `style` (string: concise or detailed). Do not use for match listings; use `search` instead. Do not use to inspect one known entity; use `get_entities` instead. Do not use for a structural neighborhood; use `traverse_graph` instead. Do not use for numeric health metrics; use `get_graph_stats` instead.
- **Parameters:**
  - `query` (string, required): The topic or question to summarize.
  - `entity_id` (integer, optional): Scope summarization to a single entity.
  - `max_results` (integer, optional, default: 10): Maximum entities to retrieve before ranking observations.
  - `max_observations` (integer, optional, default: 20): Maximum observations to include.
  - `max_depth` (integer, optional, default: 0): Optional graph traversal depth from matched entities.
  - `include_sources` (boolean, optional, default: true): Include source entity and observation IDs.
  - `scope` (string, optional, default: `context` when a project context is active, otherwise `global`): `context` hard-filters retrieval to the active project's recursive `part_of` subtree; `global` searches the full graph.
  - `style` (string, optional, default: `concise`): `concise` or `detailed`.
- **Response fields:** `query`, `summary`, `generation_mode`, `generated_by`, `fallback_reason`, `scope`, `entity_count`, `observation_count`, `observations`, `sources`, `retrieval`
- **Retrieval diagnostics:** `scope_truncated` and `scope_max_entities` signal that an active-project subtree is partial rather than complete.

## Graph Traversal (2 tools)

These tools perform structural graph queries. `direction` is one of `outgoing`
(source -> target), `incoming` (target <- source), or `both` (default).

#### `traverse_graph`
- **Description:** Perform bounded BFS when `start_entity_id` is supplied, or query edges directly using endpoint/type filters. With no start or filters, returns all relations.
- **Parameters:**
  - `start_entity_id` (integer, optional): The entity to start BFS from. Also accepts entity name.
  - `from_entity_id`, `to_entity_id` (integer, optional): Direct edge filters.
  - `relation_type` (string, optional): Singular relation-type filter.
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to expand.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
  - `max_entities` (integer, optional, default: 100, max: 1000): Maximum number of entities to return.
  - `include` (array, optional): Any of `entities`, `relations`, and `traversal`.
- **Response:** BFS defaults to `{ entities, relations, traversal }`; relation-query mode defaults to `{ relations }`.

#### `find_shortest_path`
- **Description:** Find the shortest hop-count path between two entities. Pass required `from_entity_id` and `to_entity_id` (integer; also accepts entity name); optional `max_depth` (integer, default 2, max 5), `direction` (both|outgoing|incoming, default both), `relation_types` (array of strings). Returns ordered path entities and relations, or found false when none exists within max_depth. Do not use for a full neighborhood from one start; use `traverse_graph` instead. Do not use for 1-hop filters; use `traverse_graph` instead. Do not use for keyword lookup; use `search` instead.
- **Parameters:**
  - `from_entity_id` (integer, required): Source entity. Also accepts entity name (string).
  - `to_entity_id` (integer, required): Target entity. Also accepts entity name (string).
  - `max_depth` (integer, optional, default: 2, max: 5): Maximum number of hops to search.
  - `direction` (string, optional, default: `both`): One of `both`, `outgoing`, `incoming`.
  - `relation_types` (array of strings, optional): Restrict traversal to these relation types (canonicalized).
- **Response:** `{ found, hop_count, direction, entities: [...], relations: [...] }`. When no path exists within `max_depth`, `found` is `false`, `hop_count` is `null`, and `entities`/`relations` are empty.

## Batch & Maintenance Tools (9 tools)

#### `bulk_update`
- **Description:** Atomically batch-create entities, observations, and relations (max 50 operations; rolls back on error). Pass optional `entities`, `observations`, `relations` arrays, or `operations` (type-discriminated items with type create_entity, create_observation, or create_relation). At least one operation is required. Create-only. Do not use for a single create; use `create_entity`, `create_observation`, or `create_relation` instead. Do not use to update, delete, or merge; use `update_entity`, `update_observation`, `delete_entity`, `delete_observation`, `delete_relation`, or `merge_entities` instead.
- **Parameters (canonical format):**
  - `entities` (array, optional): Entities to create. Each: `{ name, entity_type, aliases?, description?, observations?[] }`
  - `observations` (array, optional): Observations to add. Each: `{ entity_id, text_content }`
  - `relations` (array, optional): Relations to create. Each: `{ from_entity_id, to_entity_id, relation_type }`
- **Parameters (operations format):**
  - `operations` (array, optional): Type-discriminated items. Each has a `type` field (`create_entity`, `create_observation`, `create_relation`) plus the relevant fields for that operation type.

#### `suggest_merges`
- **Description:** Live vector scan of duplicate entities; returns pairs and does not merge. Pass optional `threshold` (float, default 0.3 cosine distance), `limit` (integer, default 20), `entity_type` (string). Do not use to execute a merge; use `merge_entities` instead. Do not use for queued dream-state review rows; use `list_maintenance_review` instead. Do not use for observation polarity conflicts; use `detect_contradictions` instead. Do not use for compaction job status; use `dream_state_status` instead.
- **Parameters:**
  - `threshold` (float, optional, default: 0.3): Maximum cosine distance (0 = identical, 1 = unrelated).
  - `limit` (integer, optional, default: 20): Maximum suggestions.
  - `entity_type` (string, optional): Filter to a specific entity type.
- **Response:** Array of `{ entity_a, entity_b, cosine_distance, recommendation }`

#### `merge_entities`
- **Description:** Merge a source entity into a target: transfer observations, re-parent relations, add the source name to target aliases, then delete the source. Pass required `source_entity_id` and `target_entity_id` (integers). Do not use to find merge candidates; use `suggest_merges` instead. Do not use to apply a queued review by item_id; use `apply_maintenance_review` instead. Do not use to destroy an entity without transferring knowledge; use `delete_entity` instead.
- **Parameters:**
  - `source_entity_id` (integer, required): Entity to merge from (deleted).
  - `target_entity_id` (integer, required): Entity to merge into (kept).

#### `dream_state_status`
- **Description:** Report the live dream-state compaction job (status, phase, cursor, stats, timestamps). Takes no arguments. Do not use for stored report documents; use `get_maintenance_reports` instead. Do not use for individual review-queue rows; use `list_maintenance_review` instead. Do not use for graph health totals; use `get_graph_stats` instead. Do not use for an on-demand duplicate scan; use `suggest_merges` instead.
- **Parameters:** None

#### `get_maintenance_reports`
- **Description:** Read stored maintenance report documents, not paginated review rows. Pass optional `report_type` (orphans, duplicates, compaction_review, embedding_maintenance, contradictions, or scan_review; omit for the latest of each type) and `limit` (integer, default 5, max 30). Do not use for paginated item_id rows; use `list_maintenance_review` instead. Do not use to apply or dismiss a row; use `apply_maintenance_review` or `dismiss_maintenance_review` instead. Do not use for live compaction job status; use `dream_state_status` instead. Do not use for a live duplicate scan; use `suggest_merges` instead.
- **Parameters:**
  - `report_type` (string, optional): One of `orphans`, `duplicates`, `compaction_review`, `embedding_maintenance`, `contradictions`, `scan_review`. Omit to get the latest report of each type.
  - `limit` (integer, optional, default: 5, max: 30): Maximum number of reports to return (applies when `report_type` is given).
- **Response:** `{ reports: [{ id, report_type, created_at, data }], total }`

#### `apply_maintenance_review`
- **Description:** Apply a queued maintenance-review row (merge, relationship proposal, orphan parent, or relation integrity). Pass required `item_id` (string UUID); optional `report_type` (string, default compaction_review), `dry_run` (bool, default false), `action_params` (hash). Do not use without a queue item_id; use `list_maintenance_review` first. Do not use to skip, ignore, or restore without applying; use `dismiss_maintenance_review` instead. Do not use to merge two known entity ids outside the queue; use `merge_entities` instead.
- **Parameters:**
  - `item_id` (string, required): Maintenance report row UUID.
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the row.
  - `dry_run` (boolean, optional, default: false): When true, validate and preview without applying.
  - `action_params` (object, optional): Optional overrides for merge/relation/orphan endpoints.
- **Response:** Apply result hash (`success`, `message`, and kind-specific fields such as `deleted_relation_ids`), or a dry-run preview with `kind` and `payload`.

#### `list_maintenance_review`
- **Description:** List paginated maintenance-review queue rows (including item_id) for later apply or dismiss. Pass optional `report_type` (string, default compaction_review), `status` (active, dismissed, approved, or ignored; default active), `kind` (string, e.g. entity_merge or orphan_parent), `page` (integer, default 1). per_page is not an input. Do not use for whole report documents; use `get_maintenance_reports` instead. Do not use to apply a row; use `apply_maintenance_review` instead. Do not use to dismiss, ignore, or restore a row; use `dismiss_maintenance_review` instead. Do not use to merge two known entity ids; use `merge_entities` instead.
- **Parameters:**
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the rows.
  - `status` (string, optional, default: `active`): Row status filter: `active`, `dismissed`, `approved`, `ignored`.
  - `kind` (string, optional): Row kind filter, e.g. `entity_merge` or `orphan_parent`.
  - `page` (integer, optional, default: 1): 1-based page. Response `per_page` is fixed at 50.
- **Response:** `{ report_type, status, kind, page, per_page, total_count, total_pages, items: [{ item_id, kind, status, payload, ... }] }`

#### `dismiss_maintenance_review`
- **Description:** Dismiss, ignore, or restore a maintenance-review queue row without applying the suggestion. Pass required `item_id` (string UUID) and `action` (dismiss, ignore, or restore); optional `report_type` (string, default compaction_review), `reason` (string). Do not use to execute the suggestion; use `apply_maintenance_review` instead. Do not use to look up a row; use `list_maintenance_review` instead. Do not use to merge entities; use `merge_entities` instead.
- **Parameters:**
  - `item_id` (string, required): Maintenance report row UUID.
  - `action` (string, required): One of `dismiss`, `ignore`, `restore`.
  - `report_type` (string, optional, default: `compaction_review`): Report type that owns the row.
  - `reason` (string, optional): Optional dismissal reason.
- **Response:** Updated review-row status payload.

#### `get_graph_stats`
- **Description:** Return live knowledge-graph health metrics (totals, entity_type_distribution, orphan_count, most_connected, recent updates). Takes no arguments. Do not use for stored report documents; use `get_maintenance_reports` instead. Do not use to page actual entities; use `search` instead. Do not use for a topic summary; use `summarize` instead. Do not use for compaction job status; use `dream_state_status` instead. Do not use for software version; use `get_version` instead.
- **Parameters:** None

## Utility Tools (2 tools)

#### `get_version`
- **Description:** Return the GraphMem server software version as `{version: string}`. Takes no arguments. Do not use for wall-clock time; use `get_current_time` instead. Do not use for graph health metrics; use `get_graph_stats` instead. Do not use for compaction job status; use `dream_state_status` instead.
- **Parameters:** None

#### `get_current_time`
- **Description:** Return the current server time as an ISO 8601 string. Takes no arguments. Do not use for software version; use `get_version` instead. Do not use for graph health metrics; use `get_graph_stats` instead. Do not use to set observation validity windows; use `create_observation` or `update_observation` instead.
- **Parameters:** None

## Project Source Scan (2 tools)

#### `scan_project`
- **Description:** Enqueue an asynchronous filesystem scan that reconciles the knowledge graph with a project root; returns a scan_id and does not wait. Pass required `project_root` (string); optional `project_name` (string), `aliases` (comma- or pipe-separated string), `mode` (initial, rescan, or validate; default initial), `dry_run` (bool), `file_globs` (array of strings), `scan_id` (string, resume a paused validation batch). Do not use to poll completion; use `scan_project_status` instead. Do not use to create a single node by hand; use `create_entity` instead. Do not use to scope searches to a project already in the graph; use `set_context` instead.
- **Parameters:**
  - `project_root` (string, required): Absolute or relative path to the project root directory.
  - `project_name` (string, optional): Preferred project name. Defaults to the directory name or the LLM-extracted name.
  - `aliases` (string, optional): Comma- or pipe-separated aliases for the project root entity.
  - `mode` (string, optional): `initial`, `rescan`, or `validate`. Default: `initial`.
  - `dry_run` (boolean, optional): When `true`, preview changes without writing to the graph.
  - `file_globs` (array of strings, optional): Optional file globs to scan, relative to `project_root`.
  - `scan_id` (string, optional): Existing scan operation_id to resume a paused validation batch. If omitted, a new scan is started.
- **Response:** `{ scan_id, status: "queued", project_root, mode, dry_run }`

#### `scan_project_status`
- **Description:** Poll one asynchronous project scan for status, phase, progress, counters, fallback flags, and scan_review items. Pass required `scan_id` (string from `scan_project`). Do not use to start or resume a scan; use `scan_project` instead. Do not use for compaction-job status; use `dream_state_status` instead. Do not use for stored scan_review documents; use `get_maintenance_reports` instead.
- **Parameters:**
  - `scan_id` (string, required): The scan ID returned by `scan_project`.
- **Response:** `{ scan_id, status, phase, message, progress, counters, details, fallback, fallback_reason, scan_review_items, started_at, finished_at, error }`

## Entity Type Canonicalization

GraphMem automatically normalizes entity types. When creating or updating entities, the `entity_type` field is looked up in the `entity_type_mappings` table. Known variants are rewritten to their canonical form.

Data-exchange import matching and execution share the same canonicalization via `ImportEntityResolver`: an existing entity is reused only on exact name **and** canonical type. A same-name node of another type is not a match (no name-only fallback), so observations and relations stay on the correctly typed entity.

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

MCP `tools/call` failures return `isError: true` with a **single JSON object** as the text content. There is no `Error:` prefix and no Ruby backtrace in the payload. Tools still raise typed exceptions from `call`; FastMCP serializes them at the protocol boundary.

```json
{
  "error": true,
  "category": "not_found",
  "retriable": false,
  "next_move": "Call `search` to verify the identifier, then retry with a known id.",
  "message": "Entity with ID=123 not found.",
  "tool": "get_entities"
}
```

`next_move` is an imperative instruction for the calling agent. It names a sibling tool in backticks when that tool can produce a valid retry input.

| Category | `retriable` | Typical next move |
|---|---|---|
| `not_found` | false | Call `search`, then retry with a known id |
| `validation` | false | Correct the argument format required by the tool schema and retry |
| `permission` | false | Escalate to a human; this client is not authorized |
| `timeout` | true | Retry the tool once, then inform the user of the delay |
| `rate_limit` | true | Wait and retry with backoff (reserved until a limiter exists) |
| `system_error` | false | Escalate to a human; do not retry blindly |

Exception mapping:

- `McpGraphMemErrors::ResourceNotFound` → `not_found`
- `FastMcp::Tool::InvalidArgumentsError` and Dry-schema failures → `validation`, except entity-name misses (`Entity not found by name`) → `not_found`
- `McpGraphMemErrors::OperationFailed` → `system_error` unless the call site sets `category: "validation"` for a caller-correctable policy
- `McpGraphMemErrors::InternalServerError` and unknown `StandardError` → `system_error` (generic message; original exception is logged server-side)
- `Timeout::Error` / `Net::OpenTimeout` / `Net::ReadTimeout` → `timeout`
- Unauthorized tool calls → `permission`

Empty states that are **not** errors:

- `get_context` `{ status: "no_context" }` is a successful empty state
- A missing `scan_project_status` scan **is** an error (`ResourceNotFound`), not `{ status: "not_found" }`

## Tool Overlap Guide

Some tools overlap by design; pick by intent:

| Goal | Prefer | Alternative |
|---|---|---|
| Find entities by keyword/semantic match | `search` | `search` (when you also need observation text and relations in one payload) |
| Page every entity with no query | `search` | `search` (when you have a query) |
| Load known entities by ID | `get_entities` | `get_entities` (single entity with full detail) |
| Explore multi-hop neighborhoods | `traverse_graph` | `traverse_graph` (single-hop edges only) |
| Find how two entities connect | `find_shortest_path` | `traverse_graph` (full neighborhood) |
| Review duplicate entities (live scan) | `suggest_merges` | `list_maintenance_review` (dream-state queue rows) |
| Inspect stored maintenance reports | `get_maintenance_reports` | `list_maintenance_review` (paginated item_id rows) |
| Inspect background compaction state | `dream_state_status` | `get_graph_stats` (live graph totals, not job status) |
| Apply a queued review | `apply_maintenance_review` | `merge_entities` (known source/target ids) |
| Skip a queued review | `dismiss_maintenance_review` | `apply_maintenance_review` (to execute it) |
| Execute a merge of known ids | `merge_entities` | `apply_maintenance_review` (queued merge) |
| Summarize what the graph knows about a topic | `summarize` | `search` + manual reading |
| Poll a project filesystem scan | `scan_project_status` | `scan_project` (to start or resume) |

## Dream-State Background Compaction

Solid Queue runs `DreamStateCompactionJob` on a schedule (`config/recurring.yml`). The job:

1. **Orphans phase** -- matches orphan nodes to `Project` roots; auto-parents high-confidence token matches
2. **Tree-walk phase** -- walks each project subtree; deduplicates identical observations; auto-merges entities with cosine distance &lt; 0.10
3. **Review queue** -- writes lower-confidence items to `maintenance_reports` (`compaction_review`), readable via `get_maintenance_reports`

Mutating and heavy search tools cooperatively **pause** an active compaction run (`CompactionValve`) so live MCP traffic takes priority. Paused runs resume from `cursor_entity_id` on the next trigger.

To close the loop on the review queue: call `list_maintenance_review`, inspect the suggested merges/parents, and apply the good ones with `apply_maintenance_review` (or `merge_entities` when both entity ids are already known).

## Best Practices

1. **Set `X-MCP-Client`** in your MCP config when multiple agents share one GraphMem instance.
2. **Use `set_context`** at the start of each session to scope searches to the active project.
3. **Search before create** to avoid duplicates (auto-dedup catches some, not all).
4. **Use `bulk_update`** for session-end "save what I learned" operations.
5. **Run `suggest_merges`** or check `dream_state_status` for compaction progress and review queues.
6. **Keep observations concise** and factual for better embedding quality.
7. **Clear context** (`clear_context`) when switching between projects.

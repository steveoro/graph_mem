<img src="../app/assets/images/logo.svg" alt="GraphMem logo" width="64" height="64" align="right">

# GraphMem Architecture

This document provides an overview of GraphMem's architecture, explaining how the various components work together to provide a complete graph-based memory system accessed through the Model Context Protocol (MCP) and a REST API.

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  MCP Clients (Cursor, etc.)          REST / Web UI Clients      │
│         │                                    │                  │
│  JSON-RPC (HTTP/stdio)                  HTTP/JSON               │
│         │                                    │                  │
│  ┌──────▼──────────┐              ┌──────────▼───────────┐      │
│  │  MCP::Server    │              │  Rails Controllers   │      │
│  │  (22 MCP Tools) │              │  (api/v1/*)          │      │
│  └────────┬────────┘              └──────────┬───────────┘      │
│           │                                  │                  │
│  ┌────────▼──────────────────────────────────▼───────────┐      │
│  │             Application Logic Layer                   │      │
│  │  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐  │      │
│  │  │ Search       │  │ Context     │  │ Embedding    │  │      │
│  │  │ Strategies   │  │ Scoping     │  │ Service      │  │      │
│  │  └──────────────┘  └─────────────┘  └──────────────┘  │      │
│  └───────────────────────────┬───────────────────────────┘      │
│                              │                                  │
│  ┌───────────────────────────▼───────────────────────────┐      │
│  │             Data Access Layer (ActiveRecord)          │      │
│  │  MemoryEntity │ MemoryObservation │ MemoryRelation    │      │
│  └───────────────────────────┬───────────────────────────┘      │
│                              │                                  │
│  ┌───────────────────────────▼───────────────────────────┐      │
│  │          MariaDB 11.8 (VECTOR columns, MHNSW)         │      │
│  └───────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
        Ollama (external) ──► EmbeddingService (768-dim vectors)
        Ollama (external) ──► Llm::Router ─► Llm::OllamaProvider ─► SummaryGenerationClient (optional text synthesis)
```

GraphMem follows a layered architecture that separates concerns between:

1. **MCP Interface Layer** - 22 tools and 3 prompts over JSON-RPC (Streamable HTTP and stdio)
2. **REST API Layer** - Traditional RESTful endpoints mirroring MCP capabilities
3. **Application Logic Layer** - Search strategies, context scoping, embedding service
4. **Data Access Layer** - ActiveRecord models with vector extensions
5. **Storage Layer** - MariaDB with native VECTOR support

## Component Breakdown

### 1. MCP Interface Layer (22 advertised tools)

Tools are Ruby classes in `app/tools/` that inherit from `ApplicationTool`,
written in the `arguments do … end` dry-schema DSL of `GraphMem::McpSchema::ToolApi`
(`lib/graph_mem/mcp_schema/`, vendored MIT code; source and licence in `NOTICE.md`). Prompts
(`orient`, `recall`, `persist`) and resource templates use the sibling `PromptApi` and
`ResourceApi`. `McpToolRegistry` loads all three kinds, and `McpProfile` selects what each
connection profile serves (`persist` declares only the default and maintenance profiles, so the
readonly profile neither lists nor renders it).

The protocol itself is served by the official MCP Ruby SDK (`mcp` gem, pinned to 1.11.0), through
the adapter in `lib/graph_mem/official_mcp/`. The tool classes don't depend on the gem: the
adapter wraps them.
The decisions taken when moving from fast-mcp to the gem (D1–D14: session cap, allowed hosts and
origins, body caps, argument validation, removed aliases and `/mcp/sse`, exact gem pin) are listed
with graph_mem's answers in [the migration guide](guides/migrating-fast-mcp-to-mcp-gem.md) §2.

#### Official MCP SDK feature map

| Feature | `mcp` gem 1.11.0 | GraphMem |
|---|---|---|
| JSON-RPC dispatch, `initialize` negotiation (2024-11-05 … 2025-11-25), `server/discover` and the 2026-07-28 per-request lifecycle | `MCP::Server` | — |
| Tool, prompt and resource-template classes | `MCP::Tool`, `MCP::Prompt`, `MCP::ResourceTemplate` | generated from `ApplicationTool` / `ApplicationPrompt` / `ApplicationResource` by `ToolWrapper` and `PromptWrapper`; resources come from providers (`TemplateResourceProvider` for the templates, `StaticResourceProvider` for the MCP Apps `ui://` views), which `ResourceCatalog` lists and reads |
| Tool `title` | `MCP::Tool.title` (the gem's client keeps it since 1.9.0) | `ApplicationTool.title` on every tool (≤ 40 characters), passed on by `ToolWrapper`; prompts and resources have none |
| One server per profile, with `instructions` and `capabilities` | `MCP::Server.new(instructions:, capabilities:)` | `ServerFactory.for(profile)`: the profile's tools and prompts, `McpInstructions`, and explicit capabilities from `ServerFactory.capabilities(apps_enabled:, skills_enabled:)` (no `subscribe` or `listChanged`; one `extensions` hash with the MCP Apps capability while `mcp_apps_enabled` is on and the Skills capability while `mcp_skills_enabled` is on, when `skills:` gets `McpSkills.for(profile)` and `ServerFactory.read` serves `skill://` files with `MCP::Skill.read_file` before the resource providers) |
| Argument validation | `validate_tool_call_arguments` (turned off) | the tool validates after `ParameterNormalizer` (aliases for required keys) |
| Error formatting | `-32603` for unhandled errors and, with the request id, for a reply that can't be encoded as JSON (since 1.8.2); `exception_reporter` | `ToolWrapper` turns every tool error into the `ToolError` envelope as an `isError` result; gem-side errors go to `Rails.error` |
| Request `_meta` | a `_meta` that isn't an object (string, array, number) is refused with `-32602` "Invalid params: _meta must be an object" before any handler runs, on both lifecycles; `null` reads as absent (1.9.0) | — (graph_mem never reads request `_meta`) |
| Invalid UTF-8 method name | refused with `-32600` "Invalid Request" and the request id before dispatch, on stdio and HTTP (1.10.0, #672; `-32603` before) | — |
| `resources/read` params | params that aren't an object with a string `uri` are refused with `-32602` "Invalid params" ("Missing or invalid uri") and the request id before the read handler runs, on stdio and HTTP (1.11.0, #687; without params `-32603` before) | `ServerFactory.read` only ever gets a string `uri` |
| Integer request ids | an integer id beyond 128 bits is refused with `-32600` and no id, before dispatch: HTTP 400 on Streamable HTTP (1.11.0, #688; answered with the id echoed before) | — |
| Streamable HTTP transport (`/mcp`, `/mcp/readonly`, `/mcp/maintenance`) | `StreamableHTTPTransport`: sessions, JSON responses, SSE streams, body and session caps, `MCP-Protocol-Version` check, DNS-rebinding protection (`Host` and `Origin`) | `Transports` (one per profile, options from `GRAPH_MEM_MCP_*`), `Router` (path → profile; other `/mcp/*` paths are 404) |
| Per-request context (`X-MCP-Client`, profile, session id) | `env["mcp.auth_info"]` reaches the tool as `server_context[:auth_info]` | `RequestContext` carries it in an `MCP::Server::OAuth::AccessToken`'s claims |
| Access control (token, IP allowlist) | — | `AccessGate` applies `McpAccessPolicy` before anything else ([mcp_access_control.md](mcp_access_control.md)) |
| stdio transport | `StdioTransport`: line cap, one message per line | `OfficialMcp::StdioTransport` writes to the saved real stdout; `bin/mcp_stdio_runner.rb` points `$stdout` at stderr |
| Resource subscriptions | per-session subscriptions | not advertised (`subscribe: false`): GraphMem never sends `resources/updated` |

Tool categories:
- **Context** (2): `set_context`, `get_context`
- **Read/query** (6): `search`, `get_entities`, `traverse_graph`,
  `find_shortest_path`, `summarize`, `rank_observations`
- **Mutation** (3): `graph_write`, `graph_edit`, `graph_delete`
- **Maintenance** (10): merge suggestions, review queue, compaction status,
  contradiction detection, graph statistics, and project scans
- **Utility** (1): `get_current_time`

### 2. REST API Layer

Controllers in `app/controllers/api/v1/` provide REST equivalents for all MCP operations:

| Controller | Endpoints |
|---|---|
| `MemoryEntitiesController` | CRUD, search, merge; a delete moves the entity's `part_of` children under its parent, and a refusal is a `422` (1.93.1) |
| `MemoryObservationsController` | CRUD, delete_duplicates |
| `MemoryRelationsController` | CRUD with filters; a create, or a type change, into or out of `part_of` takes the membership lock and syncs the child's project (1.93.0) |
| `ContextController` | GET/POST/DELETE context |
| `SearchController` | subgraph search, subgraph_by_ids |
| `BulkController` | atomic bulk operations; a `part_of` relation takes the membership lock and syncs its child (1.93.0) |
| `MaintenanceController` | suggest_merges, stats |
| `StatusController` | health check, time |
| `GraphDataController` | Cytoscape-format graph data for web UI |
| `GraphTraversalController` | multi-hop traverse, shortest_path |

### 3. Application Logic Layer

#### Graph Traversal (`app/services/graph_traversal_service.rb`)

`GraphTraversalService` performs bounded breadth-first expansion and hop-count shortest-path searches. It queries one frontier at a time, supports incoming/outgoing/bidirectional traversal, canonical relation-type filters, cycle protection, deterministic ordering, and result caps. MCP tools, REST endpoints, and `MemoryGraphResource` share this implementation.

#### Search service (`app/services/graph_search.rb`, `app/services/search_filter.rb`)

- **GraphSearch** - The MCP `search` tool's logic (catalog, summary and subgraph modes, paging, temporal bounds, `max_tokens`), extracted from `SearchTool#call` in 1.60.0. The tool, and the operator/guest Search page through `GraphSearch::Page`, call it with the same arguments, so they return the same entities in the same order. The page passes `context_scope: nil` and `ambient_context: false` (agents' context never reorders it) and, for its Text and Semantic modes, `semantic: false` or `text: false`; none of these are tool arguments. `GraphSearch::Page` adds per-row snippets (`GraphSearch::Snippets`: one query, no embedding call), project names and relation counts; `EntityPanel` backs the entity panel (read-only for the guest; the operator's edit forms since 1.61.0, see "Change sets and undo").
- **SearchFilter** - One frozen value object for `project_id` (a Project root and its members), `entity_types` and the `search_in_*` fields, validated once per request by `GraphSearch`, `GET /api/v1/memory_entities/search` and the page. Every channel applies it before ranking: `EntitySearchStrategy` (`fields:`, `scope:`), both `VectorSearchStrategy` queries and `TemporalSearchStrategy` (`scope:`), and `SubgraphSearchService` (`filter:`). The vector queries are exact scans, so the `WHERE` loses no recall. A default filter is passed as `nil`, which runs the unfiltered code path.

#### Search Strategies (`app/strategies/`)

- **EntitySearchStrategy** - Text-based search with token matching and relevance scoring
- **VectorSearchStrategy** - Semantic search using MariaDB VECTOR cosine distance, with a quality gate that filters results above a maximum cosine distance threshold. Supports an optional `entity_type` filter to restrict results to a specific type (used by `graph_write`'s duplicate check on `create_entity` and other type-aware callers)
- **HybridSearchStrategy** - Combines text and vector via weighted Reciprocal Rank Fusion (RRF), then applies post-fusion relevance boosts: exact name matching, entity type priority, structural importance (relation count), and graduated context boosting
- **SearchRelevanceBooster** - Shared module providing boost constants and a `rank_entity_ids` method used by both `HybridSearchStrategy` and `SubgraphSearchService` (`search` in subgraph mode)

#### Context Scoping (`app/models/graph_mem_context.rb`)

Persisted per-client storage for the active project context. MCP clients identify
themselves with the `X-MCP-Client` header; `ApplicationTool` normalizes HTTP
header key variants before `GraphMemContext` stores the scope in the
`agent_contexts` table. Agents without a client header share the `"default"`
bucket for backward compatibility. When set:
- `ProjectSubtree` (`app/services/project_subtree.rb`) resolves the recursive `part_of` subtree for a project root (and ancestor-project lookup for background jobs). The walk is capped at `GraphMemContext::MAX_SCOPED_ENTITIES` (default 1_000).
- `GraphMemContext.scoped_entity_scope` returns `{ entity_ids, truncated, max_entities }`; when the cap is hit, truncation is logged and callers continue with the partial set.
- `GraphMemContext.scoped_entity_ids` remains the backward-compatible ID array (`nil` when no context is active).
- Context/search/summarize responses expose `scope_truncated` and `scope_max_entities` wherever scope counts are reported.
- `HybridSearchStrategy` applies a graduated context boost (stronger for the root project entity, lighter for its children)
- `search` in subgraph mode (`SubgraphSearchService`) ranks results using `SearchRelevanceBooster` with context-aware scoring
- `AgentContextsSnapshot` exposes active clients, current projects, and recent tool activity to Home and System › Telemetry

#### Project membership (1.93.1, 1.93.2, 1.93.3)

`memory_entities.project_id` is derived, not chosen: an entity belongs to the Project its single `part_of` parent chain reaches, or to none (global). `ProjectMembership` (`app/services/project_membership.rb`) computes it (`sync!`, `reassign!`, `member_ids`), and names are unique per project scope, so a move can collide (`ProjectMembership::Collision`). Every writer that creates, retypes or removes an edge that reads as `part_of` in SQL (`part_of` and a stored `Part_Of`), or deletes an entity that has `part_of` children, follows one rule: take the membership lock before the transaction (the advisory-first rule), check the create-time rules for a new parent edge (one parent, no cycle), and sync each affected child in the same transaction, so a collision rolls the write back. `RelationMembershipWrite` (`app/services/relation_membership_write.rb` and `relation_membership_write/`) is the shared helper of the REST and data-exchange paths (`update!`, `destroy!`, `destroy_entity!`).

- **Entity delete** (`RelationMembershipWrite::EntityDelete`, 1.93.1) is the one delete every path uses: REST `DELETE /api/v1/memory_entities/:id`, `graph_delete` `delete_entity`, a `delete_entity` review row and the data-exchange `delete_node` (without cascade). The entity's `part_of` children move one level up, under the deleted entity's own parent, with their subtrees; they keep their project, so no name can collide. When it had no parent they become global, and a name already taken at global scope refuses the delete with nothing changed (REST `422`, a validation error from `graph_delete`, a failure reason on the review row, `422` on data exchange). A child parked under it by a `reference_stub` edge is not an owned child and is not moved. `EntityDelete#plan` says where the children go, read-only: the review preview and the `delete_node` message use it. The delete always takes the membership lock first, children or not, and reads the children under it, so a child attached while the delete starts is still moved. An entity delete is still never undoable (`hard_delete`).
- **Merge** (`NodeOperationsStrategy#merge_into`, for operator and agent merges alike): the target keeps its own relationships and its parent; every `part_of` child of the source moves to the target. The source's own parent edge is dropped when the target already has a parent, or when re-pointing it would make a cycle (`target_takes_parent?`); the dropped edge is in the merge snapshot. When the target has no parent it takes the source's, and the target and its subtree move into that parent's project before the source's children follow. Undo restores both edges and syncs the target back to its own scope. A name collision in a new scope refuses the merge (nothing is merged): `422` on REST `merge_into` and in Explore, a failure reason on a review row. See [Change sets and undo](#change-sets-and-undo-ui-4a-1570).
- **Repair relation duplicates** (`RelationIntegrityRepairer` with `review_ambiguous: false`, the operator's button) takes the membership lock before one transaction, deletes the extra parents and the newer edge of each reverse pair, and syncs each child to the parent it keeps. A collision rolls the whole repair back ("refused, nothing deleted"). The unattended callers (`GraphIntegrityService`, `review_ambiguous: true`) delete no `part_of` edge: they queue `relation_integrity` review rows.
- **Scans and imports.** A scan hangs every entity the model left without a parent on the project root (`ProjectScanner::Containment`, see Project scans below). An import follows the `part_of` edges to decide where a new node goes (`ImportEntityResolver.contained_child?`): only a node a child-to-parent `part_of` chain links to the import's root Project is created in the import's project. Every other declared node (a `depends_on` child and everything below it, and any root node after the first) is created global when absent. Every declared node, linked or not, is matched by name in the import's project first, then globally, so a node an earlier import put in the project (which the membership repair attaches to the project's root) is found again on re-import instead of copied; one the project doesn't hold merges into an existing same-named global entity instead of getting a project-scoped copy. The preview (`ImportMatchingStrategy`) looks up in the same order, so it matches what the import writes.
- **The scanner's `part_of` edges** (1.93.2, `ProjectScanner::MembershipSync`). A `part_of` the model emits moves its child, with the child's subtree, into the parent's project, and that needs the membership lock, which comes before any transaction and is never held across an LLM or network call. The reconcile's transaction runs inline LLM word batches and embedding calls between its writes, and those calls depend on rows written inside the transaction, so the lock can be taken neither around it nor inside it. `reconcile_relation` therefore creates the edge in the transaction without a sync and remembers it; after the commit the scan takes the lock once and syncs each child, one transaction per child. A scan whose model emits no `part_of` takes no lock (the containment edges need none). If a child's move collides (its name, or a member's, is taken in the parent's project), the child stays under the scanned project: the model's edge is deleted (audited, with its own deletion reason) and a containment edge to the root takes its place, and the scan's errors read "Project scope conflict for X: …; kept under <root>". A lock that stays busy leaves the stamps the scan wrote and records "Project scope not synced for N part_of edge(s): …; run bin/rails graph_mem:backfill_project_ids". Measured on a synthetic scan profile: two lock acquisitions, none inside a transaction, the longest hold 8.8 ms.
- **The guided scan** (1.93.2, `ProjectScanSkill#ensure_part_of`) runs outside any transaction, so it takes the lock first and then creates the edge and syncs the child in one savepoint: a collision rolls the edge back and is recorded in the scan's errors.
- **Scan validation** (1.93.2, `ProjectScanValidator`) deletes a `part_of` from an entity of the scanned project to another Project root through `RelationMembershipWrite.destroy!` (lock, delete, sync), so the child leaves that project. A name collision where the child would land keeps the edge and records "Failed to delete relation N: cannot move …" in the validator's errors.
- **Rake tasks** (1.93.2, run by hand). `data:merge_entity` calls `NodeOperationsStrategy#merge_into` (actor `rake:merge_entity`): the merge rule above, an undo snapshot and one undoable `merge` change set, and it now refuses what `merge_into` refuses, which is entities of different types, a Project root and a name collision (it used to merge across types). `tools:create_relation` goes through `GraphWriteService.execute_one`, so the type is canonicalized, a `part_of` passes the one-parent and no-cycle rules and syncs its child under the lock, and an existing relation is reported as a duplicate. `data:migrate_json` and `data:append_json` run under the membership lock, taken before anything is written, with inline embeddings suppressed (the lock is never held across the embedding service); they end with `ProjectIdBackfill` (which prints its report) and enqueue an embedding backfill. A name collision in that backfill aborts with its conflict hint: its stamps roll back and the rows the file added stay.
- **Dream state** (1.93.2). The `orphans` phase (an orphan's auto-parent) and the `tree_walk` phase (an auto-merge) take the lock before their transactions: `DreamStateCompactor.with_membership_lock(phase)` wraps each entity's transaction, and `DreamStateCompactionJob` wraps `run.with_lock`, whose own transaction encloses the whole batch. Inline embeddings are suppressed inside it, so an auto-merge's survivor is re-embedded by the embedding backfill the compactor enqueues afterwards. A lock that stays busy re-enqueues the job a minute later (`LOCK_RETRY_WAIT`) and doesn't fail the run. See [dream_state.md](dream_state.md#the-membership-lock).
- **The integrity sweep** (1.93.2, `GraphIntegrityService#repair_dangling_relations`) deletes the relations whose endpoint row is gone (possible only with foreign key checks off). A `part_of` whose child survives goes through `RelationMembershipWrite.destroy!`, so the child and its subtree leave the gone parent's project. A name collision keeps the edge for the next sweep and logs a warning, and `dangling_relations_removed` counts only the relations actually deleted.
- **The code map's skeleton** (`ProjectScanner::SkeletonWriter#ensure_parent`) needs no sync: every entity it handles was found or created in the root's scope, the parent is the root, and the edge is created only when the entity has no parent yet, so the project the edge implies is the one already stored.
- **The lock is never held across an embedding call** (1.93.3). Before 1.93.3 a merge re-embedded its survivor at commit time, still under the lock (REST `merge_into`, `graph_delete` `merge_entities`, Explore, a review row, `data:merge_entity`), and `graph_write`, `POST /api/v1/bulk` with a `part_of`, a review `fact_supersede` apply and Find & supersede embedded what they created inline, inside the lock and its transaction. `ProjectMembership.with_membership_lock` now runs its block in `EmbeddingService.defer_inline_embeddings`: while it is open, the embedding callbacks of `MemoryEntity` and `MemoryObservation` (on create and on a change of the embedded text) hand their record to `EmbeddingService.defer_inline_embedding`, which adds its class and id to a per-thread list (`ActiveSupport::IsolatedExecutionState`) instead of calling the service. When the **outermost** lock block exits, after its `RELEASE_LOCK` and so after the transactions inside it have committed or rolled back, and on every exit including an exception, `EmbeddingService.embed_missing` embeds the list: each record is re-read, a row that was rolled back is gone and skipped, and a row that already has an embedding stamp is skipped. A failed embedding logs `EmbeddingService: deferred embedding of X#id failed: …` and leaves the row unstamped for the embedding backfill, as a failed inline embedding always did. A nested lock block (the lock is reentrant) adds to the outer list and flushes nothing. Suppressed embeddings (imports, dream state, the JSON rake tasks and undo, which use `suppress_inline_embeddings`) are not deferred, and enqueue the embedding backfill or embed after their lock as before. An interactive write is still embedded before the call returns.
  - **Paths fixed** (found by the spec guard, which failed 99 examples in 34 files on the earlier code; see [development.md](development.md#embedding-lock-guard)): `merge_into` (REST `merge_into`, `graph_delete` `merge_entities`, the Explore merge, a review `entity_merge` row, the data-exchange `merge_node`, `data:merge_entity`); `graph_write` (`GraphWriteService#call` and `execute_one`: entity creates, their observations and `create_observation`; also the MCP `graph_write` tool and `tools:create_relation`); a review `fact_supersede` apply; Find & supersede (`FactSupersede::Bulk`); and REST `POST /api/v1/bulk` with a `part_of`.
  - **Measured lock hold** (test database, a simulated 50 ms per embedding call, median of the runs): a `graph_write` create of one entity and two facts 178.6 ms before, 15.9 ms after; a `merge_into` 63.6 ms before, 11.4 ms after; an import of 20 paraphrased facts 1,089.9 ms before, 39.2 ms after.
- **An import embeds its de-duplication texts before the lock** (1.93.3, `ImportExecutionStrategy::DuplicateVectors`). The import's semantic observation de-duplication (`ImportObservationDuplicateDetector`, used by the headless JSON import and, after the commit, by the SQL import's follow-up; see [data_exchange.md](data_exchange.md#what-happens-after-an-import)) used to embed each incoming fact inside the lock and the import's transaction. `ImportExecutionStrategy#execute` now calls `precompute!` on the detector before it takes the lock, with the distinct observation texts it will need: those of nodes that can land on an existing entity (the entity a merge decision names, or one with the node's name) that has active facts the detector would compare semantically (`compares_semantically?`: all of them embedded, or, for a project scan's detector, at least one), outside excluded subtrees, minus the texts that entity already holds exactly (a pre-read; it is racy and only saves calls). `precompute!` embeds every one of them, one embedding call per distinct text (the service has no batch call). A failed call (or an empty vector) raises `ImportObservationDuplicateDetector::UnavailableError` with the message the detector raised under the lock before ("Embedding service is unavailable: …", "Embedding service returned an empty vector."), and `#execute` rescues it as before: the import fails with "Semantic observation de-duplication unavailable: …", the progress row is failed, and nothing is written, since the lock and the transaction haven't started. Under the lock, `find_duplicate` only looks the vector up and never makes an embedding call (also when it runs under the lock without a precompute): exact matches are found as before, and a text without a vector, which only the pre-read's race can leave (an entity or a fact changed between the read and the lock), is matched exactly only. When any fact fell back, the import logs one line after the lock, `ImportExecutionStrategy: Semantic observation de-duplication matched N fact(s) exactly only: N whose text was not embedded before the import` (see [troubleshooting](troubleshooting.md#problem-an-import-matched-facts-exactly-only)). Missing vector columns still fail the import, as before. The import preview (`ImportMatchingStrategy`) takes no lock and is unchanged. Measured on the test database with a simulated 50 ms per embedding call, an import of 20 paraphrased facts held the lock 1,089.9 ms before and 39.2 ms after (median).
- **Drift report.** `ProjectIdBackfill.drift` reads, with the backfill's own walk and no write, where the stored stamps and the edges disagree: `wrong_project`, `stamped_without_path`, `path_without_stamp` (stamps the backfill repairs), `reached_by_two_roots` and `several_parents` (edges it only reports), each with the offending entity ids. `bin/rails graph_mem:backfill_project_ids[dry_run]` prints it before the run, the repair migration logs it before and after, and the spec suite's drift guard fails an example that leaves any of it behind (see [development.md](development.md#membership-drift-guard)). The backfill repairs a stamp with no path toward the stamp when it can: when every entity up its owned `part_of` chain carries the same stamp and the top has no parent, the top gets one `part_of` to that project's root (marked `properties.source: "project_id_backfill"`, in one `maintenance.membership_repair` change set, actor `maintenance:project_id_backfill`); otherwise the stamp is cleared, as before. Undoing the change set deletes the edges and syncs each top back out (the tree goes global, as the clear would have made it).

#### Relation types (`app/models/memory_relation.rb`, `app/services/relation_type_sweep.rb`, 1.93.0)

A relation's type is normalized when it is set, in one place: `MemoryRelation.canonical_relation_type` runs in a `before_validation` on create and on an update that changes the type. It folds the type (trim, lower case, a run of spaces and hyphens becomes one underscore), then looks it up in this order: a `relation_type_mappings` row (`RelationTypeMapping.canonicalize`, memoized per process for 60 seconds), else `GraphVocabulary::RELATION_TYPE_MAPPINGS` in code, else the folded type itself (a novel type stays allowed). A table row is an operator's choice and wins over the code. The table is no longer seeded (`db/seeds.rb` keeps the entity type seed); an install seeded earlier keeps its rows. An update that doesn't change the type keeps the stored spelling, so an entity merge re-pointing an edge can't turn a variant into `part_of` behind the single-parent and cycle checks. `keep_stored_type` lets an undo re-insert a deleted relation with its stored type as it was.

`RelationTypeSweep` canonicalizes the types already stored, in batches of 200 relations by id. It is one service with three callers: the dream-state phase `relation_types` (`DreamStateCompactor::RelationTypesPhase`, the first phase, one batch per job, its cursor in the run's stats), `bin/rails graph_mem:canonicalize_relations` (`DRY_RUN=1`, `VERBOSE=1`) and `RelationTypeSweepJob` (System › Background jobs). Per relation it ends in one outcome: `unchanged`, `case_only` (updated in place), `retyped` (in place), `merged` (into a twin of the canonical type on the same endpoints, which keeps the higher `weight` and `confidence`; the variant's `properties` go under `merged_from` when the twin has its own) or `queued`. A variant of `part_of` is never written: an update skips the create-time checks and the membership sync, so it becomes a `relation_retype` review row, applied by hand under the membership lock (`CompactionReviewApplier::RelationRetype`). The sweep itself never takes that lock. `UnmappedRelationTypes` lists the stored types nothing maps, and `RelationTypeDecision` writes the operator's **map**, **accept** and **remove** rows; neither retypes a relation. The run's report is a `MaintenanceReport` of the internal type `relation_type_sweep`, listed in `MaintenanceReport::INTERNAL_REPORT_TYPES` and kept out of `REPORT_TYPES` so the MCP `get_maintenance_reports` schema doesn't change. See [dream_state.md](dream_state.md#phase-1-relation_types).

#### Libraries: `depends_on` and the global scope (Dream State R1b)

A library a project only uses is not part of it. Membership stays derived from `part_of` alone, so moving a library out of a project's scope is a change of edge: `library part_of Project` becomes `Project depends_on library` (`depends_on` runs from the dependent to its dependency, as everywhere in the repo), the library and its own `part_of` subtree become global, and a library two projects use is one global node with a `depends_on` from each.

- **Which entities.** `DependencyLikeTypes` reads the `dependency_like_types` setting (default `Framework, Gem, Tool, SoftwareLibrary, TestFramework`) and matches an entity type by its canonical type (`EntityTypeMapping`), case-insensitively; a Project never matches.
- **The swap is a review row.** The dream-state phase `dependency_edges` (`DreamStateCompactor::DependencyEdgesPhase`, after `relation_types`) queues a `relation_retype` row with `operation: "swap"` per dependency-like `part_of` a Project, with `DependencyEvidence` (the project's facts that name the library with a use phrase). `CompactionReviewApplier::RelationRetypeDependency` applies it under the membership lock, in one savepoint: delete the `part_of`, create the `depends_on` through `MemoryRelation.create!`, `ProjectMembership.sync!`. A global name the library holds refuses it and queues an `entity_merge` of the global namesake into the library (same type only), plus one per same-named, same-type pair across their `part_of` subtrees (1.96.0); a child's global name refuses it, naming the child. The generic audit undo reverses it. `operation: "add"` (phase `orphans`) creates `Project depends_on` a dependency-like orphan instead of parenting it.
- **The orphan rule.** `OrphanMatchingStrategy#orphan_nodes` (dream state, Explore, `GET /data_exchange/orphan_nodes`) leaves out an entity a Project `depends_on`, so a swapped library isn't parented back by name. `get_graph_stats`' `orphan_count` is another notion (no facts and no edges) and is unchanged.
- **The policy.** `ReviewPolicies::AutoApplyRelationRetype` (off by default) applies `swap` rows only, when no fact of the project names the library with an ownership phrase (`OWNERSHIP_PHRASES`).
- **Scans.** A scanned item of a dependency-like type whose name a global entity of a dependency-like type holds resolves to that entity (`ProjectScanner::GlobalDependencies`): no project copy, no `part_of`, the root's `depends_on` added when missing, its facts written with a source naming the project and covered by that project's validation only (`ProjectScanValidator::Scope`). See [summarization](summarization.md#project-scans).
- **Actor.** Dream state's edges carry `compaction:<run id>` in their audit rows (the orphan auto-parent is a `compaction.auto_parent` change set).
- **The SQL export follows `depends_on` one hop.** `SqlExport::Scope` adds, for each exported Project (roots and nested ones), the global non-Project targets of its own `depends_on` with their `part_of` subtrees (`ProjectMembership.member_ids`), in the global scope, so a Project's script still carries its libraries as rows after their swap. A `depends_on` to a Project or to another project's member stays a reference, a library's own `depends_on` is not followed, and an edge from outside into an entity held only through the hop (another project's `depends_on`) is left out. The template didn't change, so the format stays v1. `SqlExport::Writer` leaves the inert `source-fact` tag out of an active fact on a global non-Project entity, which the import's checks would refuse. The export picker's roots (`SqlExport::Roots`) count only `part_of` as a child edge, so a global library is a root of its own. See [data_exchange.md](data_exchange.md#staging-tables).
- **Removal-style evidence (R1c).** The second pass of `dependency_edges` (`DreamStateCompactor::RemovalEvidencePass`) reads each Project root's `depends_on` and each `part_of` into a Project root from a dependency-like entity, and `RemovalEvidence` finds the project's active facts that name the edge's entity with a removal phrase (`RemovalEvidence::PHRASES`; keyword path or text, no LLM). Each (relation, fact) becomes an informational `relation_review` row (`CompactionReviewApplier::RelationReview`): `ReviewRowClassifier::INFORMATIONAL_KINDS` keeps it out of every apply path (the Review page offers Dismiss and Snooze, `CompactionReviewService.apply` answers a validation error before any lock or change set, and the MCP tool maps it to `category: "validation"`). The relation lifecycle (R2) gives it an apply.

#### Embedding configuration (`app/services/embedding_config.rb`)

Resolves URL, model, provider, and dimensions with priority **AppSettings → ENV → defaults**. Used by `EmbeddingService`, rake tasks, and the operator embeddings UI. Operators can edit values under **System › Settings › Embeddings**; workers pick up changes after save via `EmbeddingService.reset_instance!`.

#### Summarization configuration (`app/services/summarization_config.rb`)

Resolves URL, model, provider, timeout, and output token limits with the same **AppSettings → ENV → defaults** priority. Used by `SummaryGenerationClient` and `SummarizerService`. Operators configure values under **System › Settings › Summaries**; saving resets `SummaryGenerationClient` so subsequent summarize requests use the new settings.

#### LLM layer (`app/services/llm/`, 1.67.0)

Every LLM call goes through `Llm::Router.generate(task, prompt, style:, options:, inline:)`, with one of three tasks: `:summary` (`SummarizerService`), `:scan` (`ProjectScanner::ChunkedExtraction`, one call per part) and `:judge` (`FactSupersede::Judge`, by default through `Llm::Router.client(:judge)`; `FactSupersede::Proposals` passes an `inline: true` client when `detect_contradictions` calls it). `Llm::Router.usable?(task)` replaces the call sites' `SummarizationConfig.llm_usable?` checks. `Llm::Registry` maps provider names to providers. The only provider is `Llm::OllamaProvider` (`ollama`, both transports), which calls `SummaryGenerationClient.generate` at class level and returns its Hash, to which the Router adds `provider:`. The three prompt builders return an `Llm::Prompt` (`trusted` and `data` segments) rendered as a String. `Llm::UsageLog` writes one `[llm]` info line per call (sizes, latency and outcome only). An architecture spec (Prism over the Ruby files of `app/` and `lib/`) checks that only the provider calls `SummaryGenerationClient` (the only other files that name it are its own and the settings reset), and that no code there starts a process (`lib/tasks/db_utils.rake` excepted); `SubprocessGuard` checks the same at runtime, views included. See [summarization](summarization.md#llm-providers).

#### Anonymizer and cloud gate (`app/services/llm/`, 1.68.0)

The Router walks `CHAIN`. A local provider gets `prompt.to_s`, exactly as before. A provider with `cloud?` true (none until PR4) goes through `Llm::CloudCall`, which works through these steps:
1. The prompt must be a scoped `Llm::Prompt`: the three call sites hand over `SummarizerService#build_llm_prompt`, `ExtractionPrompt.build` (one `Llm::Scope.for_scan` per `ChunkedExtraction`, so a scan keeps one mapping) and `Judge#prompt`.
2. `Llm::CloudGate` checks `memory_entities.cloud_allowed` on every project in scope (one query per call), and for a scan that its folder is the project's `cloud_root`, compared byte for byte in Ruby (the column's collation ignores case). That column is recorded when Cloud is turned on, from the project's last completed scan, and only if it is still the folder the confirm showed.
3. The scope's `Llm::Anonymizer::Session` (`Dictionary`, `Detectors`, `Tokens`) masks the data segments.
4. The answer is restored before the caller sees it.

A refusal returns `ok: false` without a provider call, and the Router tries the next provider. `cloud_allowed` and `cloud_root` (Project roots only, `cloud_allowed` default false, both excepted from `as_json`) are set only by `Projects::CloudAccessController`. See [summarization](summarization.md#anonymization-and-cloud-access).

#### Host bridge (`script/llm_bridge/`, 1.69.0, outside the app)

A separate Python 3 process (standard library only) on the operator's workstation, not in the container and never started or loaded by Rails. It listens on `127.0.0.1` with a token file (`docker-compose.yml` uses host networking, so the app reaches the host's loopback). It runs one agent CLI per request through a profile (`claude`, `devin`): a 0700 temp dir, an environment built from scratch, every tool, MCP server and config file switched off, and output caps. It returns the raw answer with a failure class. A profile is served only while its lockdown gate (`lockdown_test.sh`, run by the operator) says PASS for the CLI binary, version and wrapper found now; a run that uses a tool trips it until a new PASS. Since 1.70.0 the app reaches it over HTTP only: `Llm::BridgeClient` (`LLM_BRIDGE_URL`, the literal `http://127.0.0.1:<port>`, and `LLM_BRIDGE_TOKEN_FILE`) under `Llm::AgentCliProvider`, a cloud provider, so prompts are already masked by `Llm::CloudCall`, and only when a task's chain setting names `agent_cli` (default `ollama` everywhere). `Llm::BridgeProbe` shows its health in Settings › Summaries. Since 1.71.0 a chain can name both profiles with backup models (`Llm::Chain`, `Llm::ChainRun`); daily budgets (`Llm::Budget`) and per-day usage counters (`Llm::Usage`, the usage card) live in `Rails.cache`, and one cloud-using job runs at a time (a shared Solid Queue concurrency key). Adopter guide: [`docs/agent_cli_backends.md`](agent_cli_backends.md). `spec/llm_bridge_isolation_spec.rb` checks that only those files name it and that none reads its files or starts a process. See [`script/llm_bridge/README.md`](../script/llm_bridge/README.md).

#### Project scans (`app/services/project_scanner.rb`, `app/services/project_scanner/`)

`ProjectScanner` discovers the files (`ProjectScanFileFilter`: inside the root, denylist, `EXCLUDED_FILE_GLOBS`), extracts knowledge and reconciles it with the graph, then `ProjectScanValidator` checks the existing subtree in resumable batches. The LLM extraction (1.66.0): `ChunkPlanner` splits the files into parts sized from `summary_num_ctx` (`TokenEstimate`), `ChunkedExtraction` sends one request per part (`ExtractionPrompt`) and splits a failed part once, and `ExtractionMerger` merges the answers by entity before reconcile. Reconcile runs in two passes (entities and observations, then relations). Only a **complete** scan (every part succeeded, every file sent) runs `mark_missing_entities`, dismisses conflicting compaction reviews and hands the validator the scan text; a **partial** one creates and updates but never obsoletes or queues a delete. `details["extraction"]` records the parts and files, and `reconciled: true` lets a resumed paused batch skip the model and reconcile. The validator's state lives under `details["validation_state"]`. Without the LLM (or when the window is too small) `DeterministicExtraction` lists the manifests and top-level directories, as before. Containment (1.93.1, `ProjectScanner::Containment`): every entity the scan reconciles is stamped into the scanned project, so after the relations pass each one still without a `part_of` parent gets one to the project root, as the code map's skeleton does. The edge is marked `properties.source: "project_scan:<scan_id>:containment"` with `properties.scan_id`, goes through the model (audited) inside the scan's transaction, counts in `relations_created`, takes no membership lock (the stamp is already the root), and is skipped on a dry run. A parent the model emitted is kept, and (1.93.2) is synced after the reconcile commits, under the membership lock (see Project membership above): when its move collides, a containment edge to the root replaces it. The rescan's validation therefore reaches those entities too. See [summarization](summarization.md#project-scans).

#### SQL exchange (`app/services/sql_export/`, `app/services/sql_import/`, 1.94.0)

graph_mem-sql is the export and import format (it replaced the JSON export and upload in 1.94.0): one self-contained SQL script that syncs a project between machines. The format, the merge rules and the operator recipe are in [data_exchange.md](data_exchange.md); this is where the parts live.

- **Export.** `SqlExport::Scope` (root ids to entity, observation and relation sets plus the references across the boundary; it reuses `ProjectMembership.member_ids`) feeds `SqlExport::Writer`, which streams the header, the template's fixed part and the staging `INSERT`s (values through `connection.quote`). `ExportJob` calls it (one progress step per staging table; it writes no other format), `graph_mem:export_sql` and `GET /data_exchange/export` call it directly.
- **The template.** The fixed sections are the numbered files in `lib/graph_mem/sql_exchange/v1/` (preamble and staging tables, guards, entities, observations, relations, checks, record, report). `SqlExport::Template` renders them, holds the pinned `sql_mode`, the staging columns and `MAX_SCHEMA`, and splits them with `GraphMem::SqlStatements` (the DELIMITER-aware splitter `ScanProfile::StructureLoader` also uses). A migration that touches the three graph tables adds a version directory.
- **Import.** `SqlImport::Validator` refuses any file that is not this app's template around literal-only staging `INSERT`s. `SqlImport::Executor` runs the statements on one connection inside `ProjectMembership.with_membership_lock` and an `ActiveRecord::Base.transaction` (a dry run raises `ActiveRecord::Rollback`), after `CompactionValve.request_pause_if_running!`, and canonicalizes the staged relation types with the target's mappings (`SqlExport::Template.relation_type`) before the merge; it never embeds. `SqlImport::Flow` is the in-app path (upload, validate, dry run, preview, execute, `finish`), shared by Projects › Imports (`ImportFlow` detects a script by its first line) and `graph_mem:import_sql`.
- **Follow-up.** `SqlImportFollowUpJob` runs `SqlImport::FollowUp` after the commit: embedding backfill, trust scores (`ObservationTrustRecompute`), keyword paths and fact supersede, review rows (`SqlImport::ReviewSeeds`: entity merges, reworded duplicates), the contradiction hook (`SqlImport::FollowUp.contradiction_entity_ids`, read by `StaleMemoryScanner`), then compaction or, with full maintenance chosen, `ScheduledRunJob.start!(trigger: "sql_import")`. `SqlImport::Touched` reads the rows the import wrote from its `import` operation row.
- **Record.** Every run writes `audit_logs` rows (actor `sql_import`) and one completed `import` `OperationProgress` row in the same transaction; no `ChangeSet`, so there is no one-click undo.
- **`ObservationTrustRecompute`** is the one bulk trust-score recompute: the headless JSON import (`ImportExecutionStrategy`), the SQL import's follow-up and the `MemoryRelation` hook call it instead of each keeping a copy. It writes with `update_column`, so `updated_at` stays the content timestamp the import's newer-wins rule compares.

#### Embedding Service (`app/services/embedding_service.rb`)

Calls Ollama (or an OpenAI-compatible endpoint) to generate vectors from entity composite text. Uses `EmbeddingConfig.resolved_config`. Gracefully degrades when unavailable.

The models embed inline when a row is created and when its embedded text changes, and three class-level switches decide when that call is made:
- `suppress_inline_embeddings { … }` (bulk paths: imports, dream state, the JSON rake tasks, undo) skips the call; the embedding backfill embeds the rows later.
- `defer_inline_embeddings { … }` (1.93.3) collects the records instead. `ProjectMembership.with_membership_lock` opens it, so inside the membership lock the models' callbacks call `defer_inline_embedding(record)` (true when it was deferred, false when the caller embeds now), and the outermost block embeds the list when it exits. See [Project membership](#project-membership-1931-1932-1933).
- `embed_missing(keys)` embeds the rows of `[class, id]` pairs that still exist and have no `embedded_at` stamp, one call each, and logs a failure instead of raising. The deferral and `ChangeSetUndo` (its re-embed after the lock, at most 50) share it.

`ProjectMembership.membership_lock_held?` tells whether this thread is inside a lock block; the spec suite's embedding lock guard reads it ([development.md](development.md#embedding-lock-guard)).

**Unembedded rows (`embedded_at`).** With the vector indexes installed (`embeddings:add_indexes`; the committed `db/structure.sql` has them), the embedding columns are `NOT NULL` and a `BEFORE INSERT` trigger stores the zero vector in a row that has no embedding yet. MariaDB's cosine distance to the zero vector is NaN: the client reads it as 0, a `<` comparison on it is false (`>=` is true) and arithmetic on it raises ERROR 1690 (`spec/db/zero_vector_distance_spec.rb`). So `embedded_at`, never the vector column, decides whether a row is embedded: the `with_embedding` / `missing_embedding` scopes, and every guard that skips an unembedded row before a distance query (the summarizer's contradiction marks, `ContradictionDetector`, `EntityMergeEvidence`, `suggest_merges` and its REST copy, and the contradiction auto-resolve policy's distance check). An edited row also has `embedded_at` NULL while it keeps its old vector until it is re-embedded, so these guards skip it too. `ObservationRelevanceRanker` gives an unembedded observation no vector score (it is scored on its tokens alone) instead of the false similarity of 1.0 the placeholder's 0 gave it before 1.93.5, which ranked it first in `summarize`, `rank_observations`, `get_entities` and `traverse_graph`.

### 4. Data Access Layer

#### Core Models

- **MemoryEntity** - Graph node with name, entity_type, aliases, description, and VECTOR(768) embedding
- **MemoryObservation** - Versioned text facts plus confidence, provenance, validity, tags, and `active`/`obsolete`/`superseded` lifecycle state, with its own VECTOR(768) embedding and (1.77.0) a keyword path: `keywords`, the project root's name, the name of the entity that holds the fact, then each project entity the fact mentions in the order it names them (`FactKeywords` / `FactKeywords::TermIndex`, deterministic: entity names and aliases, no LLM; a short name several entities share is left out). `keywords_at` NULL means pending: `FactKeywordsJob` computes pending facts after writes (one delayed run per burst, discarded while one is queued or running) and nightly, `graph_mem:fact_keywords:refresh [PROJECT=]` recomputes on demand (after renames, merges or alias changes; a fact that moves to another entity is re-pended on its own). The path is never embedded and isn't in the REST or MCP output yet; Explore shows a fact's mentions
- **MemoryRelation** - Directed edge with a canonicalized relation_type (normalized when set; see "Relation types"), weight, confidence, and structured properties
- **EntityTypeMapping** - Canonicalization rules for entity types
- **RelationTypeMapping** - An operator's canonicalization rules for relation types; the code vocabulary answers for what the table doesn't hold
- **AuditLog** - Change tracking for entities
- **MaintenanceReport** - Results from maintenance operations (the internal `relation_type_sweep` run report is one of them)
- **AgentContext** - Per-MCP-client project scope and last activity, keyed by `client_id`

### 5. Storage Layer

MariaDB 11.8 with:
- Native `VECTOR(768)` columns for entity and observation embeddings
- `MHNSW` approximate nearest-neighbor indexes for cosine distance search
- Counter caches (`memory_observations_count`) for performance

Observation lifecycle transitions retain historical rows. User deletion marks a row obsolete, while supersession creates a new active row and links the old row to its replacement. Normal reads and search filter to active observations; explicit `include_obsolete` access exposes history. Maintenance duplicate cleanup remains a physical deletion path.
- Foreign key constraints for referential integrity

## Data Flow

A typical MCP request flows through:

1. MCP client sends a JSON-RPC request over Streamable HTTP or stdio; over HTTP, `AccessGate`, `RequestContext` and `Router` run first
2. The profile's `MCP::Server` routes it to the tool's `ToolWrapper` class, which calls the `ApplicationTool` subclass
3. `ApplicationTool` resolves the caller's MCP client ID from request headers and records activity in `agent_contexts`
4. `ApplicationTool#call_with_schema_validation!` normalizes incoming parameters via `ParameterNormalizer` (camelCase to snake_case, entity name to ID resolution, and canonical graph mutation operations)
5. Tool validates normalized parameters (via Dry::Schema `arguments` block)
6. Tool executes business logic using ActiveRecord models and search strategies
7. `ToolSuccessResponse` adds version, `next_move`, context, and `_meta`
8. Schema-enabled tools emit matching `structuredContent` and JSON text
9. `ToolWrapper` returns the result (or the `ToolError` envelope) to the gem, which answers on the request's transport

### Parameter Normalization

`ParameterNormalizer` (`app/tools/concerns/parameter_normalizer.rb`) ensures compatibility with both graph_mem's native snake_case/ID-based conventions and the `@modelcontextprotocol/server-memory` camelCase/name-based conventions. This runs at step 3 before schema validation, handling:

- **camelCase to snake_case key conversion** (recursive, for nested hashes in arrays)
- **Standard field aliases** (`content` to `text_content`, `entity_name` to `entity_id` via DB lookup)
- **Entity name resolution** (string entity names resolved to integer IDs via `MemoryEntity.find_by`)
- **Mutation operation parsing** (`graph_write`, `graph_edit`, and
  `graph_delete` type discriminators; `graph_write` also accepts the legacy
  three-array form)

REST API requests follow a similar path through Rails controllers instead of MCP tools, sharing the same models, strategies, and services.

## Web UI

GraphMem includes a web UI (served by Rails) for browsing and managing the knowledge graph:

- **Graph visualization** using Cytoscape.js (data from `GraphDataController`)
- **Entity browser** with search, create, edit, delete
- **Projects & Data** (`/projects`, UI-6, operator only; `Projects::BaseController`): the projects list (`ProjectsOverview`: last scan, last import and scan-review groups per Project root in a fixed number of queries), scans, imports, exports and Background jobs. `ProjectScanLauncher` is the one place a web form starts or steers a scan: the path goes through `ScanRootPolicy.resolve` first, then a normal scan through `ProjectScanJob.enqueue` or a guided one through its pending `OperationProgress` and `ProjectScanSkillJob`. `ImportFlow` runs the web import: it takes a graph_mem-sql script (validate, dry-run preview, execute; a JSON file is refused, since the JSON upload and its review were retired in 1.94.0) on the SQL exchange services below. The histories come from `OperationProgress`: scans (`project_scan`, `project_scan_skill`), exports (`ExportJob`, which takes over the pending row the page writes) and imports, whose `details` hold the file name, producer, project and the report summary (rake imports have none and show as "imported from the command line").
- **Data Exchange** (`DataExchangeController`): the sync export (a graph_mem-sql script; `format=json` answers 400, since the JSON export was retired in 1.94.0; see [data_exchange.md](data_exchange.md)) and the other endpoints (root list, entity search, cleanup and relation actions); imports run on Projects › Imports (graph_mem-sql scripts only). The JSON import engine (`ImportMatchingStrategy`, `ImportExecutionStrategy`) is kept only for `graphify:import` and `rails_ast:import`, which run it headless. Its matching and execution share `ImportEntityResolver` (`graph_write` and the project scans use it too): lookups use exact name plus canonical entity type (for example `workspace` → `Project`) **within the project scope** — entity names are unique per `project_scope` (`memory_entities.project_id`, NULL = shared global namespace), so the same name can exist once per project. The first Project-typed tree root claims the import's scope; unresolvable *reference* endpoints become global stubs that the first repo to declare them claims into its project (two or more declarers leave the stub global and queue `AMBIGUOUS`/`repoint` proposals). Same-name entities of a different type in the same scope are not treated as matches; the import creates a new entity path instead of attaching observations or relations to the wrong typed node.
  - Import payloads may also carry a top-level `relations` array of name+type-addressed edges (`from_name`/`from_type`/`to_name`/`to_type`/`relation_type` + optional `weight`, `confidence`, `properties`). `ImportExecutionStrategy` applies them as a second pass inside the same transaction, after the entity tree exists; unresolved endpoints are counted in `ImportReport.relations_unresolved` instead of failing.
  - **Graphify ingest**: `GraphifyImporter` (`app/services/graphify_importer.rb`) translates a Graphify `graph.json` (node-link format) into this payload deterministically — Project → File → Class/Module → Method/Constant containment becomes `part_of` tree links, every entity gets a `"Defined at <file><line>"` provenance observation with `source: "graphify"`, and non-tree code edges (`calls`, `inherits`, `mixes_in`, `imports_from` → `depends_on`) flow through `relations` with their `EXTRACTED`/`INFERRED` provenance kept in `properties`. `AMBIGUOUS` edges are withheld and queued as `relationship_proposal` items in the `scan_review` queue — never auto-applied. Rake tasks: `graphify:translate GRAPH=… PROJECT=… [OUT=…]` writes the translated payload, to inspect it; `graphify:import GRAPH=… PROJECT=…` runs the whole flow headless (match → auto-accept → execute with `OperationProgress`). Re-runs are idempotent: entities match by name+type, duplicate provenance observations short-circuit, and relations dedupe via `(from, to, type)` uniqueness.

    Re-imports are incremental rescans: the translated payload carries `rescan: true`, and when the root already has graphify-sourced descendants the executor diffs stored provenance against the payload — a `graph.json` is the FULL repo scan by contract, so absence means removed code. Vanished entities get their provenance observations obsoleted and drifted `Defined at` lines `supersede!`d (the merge dedups the replacement), while vanished entities/edges are queued as `delete_entity`/`delete_relation` items in `scan_review` — nothing is auto-deleted. Same-tree moves (stored parent still inside the subtree) stay importable and become `reparent_entity` items; pending delete proposals for items a scan brought back are auto-dismissed so a stale proposal can't delete live data. `GraphifyRescan` owns the diffing; `RESCAN=0` opts out. Dismissed proposals stay dismissed for the current scan's findings, but a *manually* dismissed (or ignored) proposal can return on a later rescan while the finding still holds — suppression (`MaintenanceReportSuppression`) is the permanent route, and `apply` refuses rows that are not active/ignored.

  - **Rails AST extractor**: `RailsAstExtractor` (`app/services/rails_ast_extractor.rb`) produces the same node-link `graph.json` shape for a Rails app's own code — deterministic Prism-only, two passes (index declarations, then emit) so associations resolve order-independently. It covers every Ruby dir under `app/` (but `assets`, `javascript`, `views`), `lib/` (but `tasks`, `generators`, `templates`, `assets`) and `config/routes.rb` (1.74.0; before: `app/models` and `app/controllers` only). Each constant is typed by its **Rails role** (`RailsAstExtractor::Roles`, 1.74.0): a file's main constant takes its directory's role (models → Model, controllers → Controller, helpers → Helper, jobs → Job, mailers → Mailer, decorators, validators, strategies, commands, services, components, `app/api` → APIEndpoint; a module there is a namespace, Module, except in helpers), a `concerns/` module or one that does `extend ActiveSupport::Concern` is a Concern, and any other class takes the role of the first Rails base on its superclass chain (ApplicationRecord/ActiveRecord::Base → Model, …), else Class or Module. File nodes are one per path and import named by their path. Associations (`belongs_to`/`has_many`/`has_one`/HABTM; `class_name:` wins, else lexical→top-level→basename resolution — `EXTRACTED`/`INFERRED`, multi-namespace basename ties are `AMBIGUOUS` → scan_review), `include`/`extend`/`prepend` → `mixes_in`, `scope`/`enum` → Method nodes, `delegate` → `delegates_to`, and `resources`/`resource`/verb macros → `Route` entities (`GET /x/:id`) `part_of` routes.rb with `routes_to` edges to `Controller#action`. Payloads declare `"producer": "rails_ast_extractor"`, which stamps that name on provenance observations, relation `properties.source`, and the `rescan` marker — re-imports diff only that producer's facts, so a rails_ast rescan never flags graphify facts and vice versa. Edges from in-subtree sources to foreign-project endpoints are allowed and tagged `properties.cross_repo = true` (counted in `ImportReport.relations_cross_repo`) so `belongs_to`-style edges can bridge repos. Rake: `rails_ast:extract REPO=… [PROJECT=…] [OUT=…]` writes `graph.json`, to inspect it (the web upload takes SQL scripts only); `rails_ast:import REPO=… [PROJECT=…]` runs extract → match → execute headless (`RESCAN=0` opts out of the rescan pass).
  - **Rails code map** (1.75.0): `RailsCodeMap` (`app/services/rails_code_map.rb` + `rails_code_map/{detector,gems,zeitwerk_paths,views,edges,map}.rb`) is the project scan's pure view of the same extractor: one entry per file's main constant (qualified name, role type, aliases, `Defined at` fact), View/Layout entries per `app/views` folder and layout, a Route entry for `config/routes.rb`, edges between entries only (AMBIGUOUS edges skipped; engine routes resolved through `isolate_namespace`), and the declared gems. `ProjectScanner` writes it as the project's skeleton (`ProjectScanner::SkeletonWriter`, source `rails_code_map`, inside the reconcile transaction, with inline embeddings deferred to one backfill), lists each part's entries in its prompt and maps each part's answer onto it (`ProjectScanner::CodeMapGuide`). See [Summarization › Project scans](summarization.md#project-scans).
- **Home** (status only, lazy Turbo Frame widgets from `HomeSnapshot`) with MCP client/project context status from `AgentContextsSnapshot`
- **System** (`/system`, UI-7, operator only; `System::BaseController`): Health, Settings, Backups, Access, Activity, Audit log, Telemetry, Embeddings, Background jobs and Queue (Mission Control at `/system/queue`, base controller `System::QueueDashboardController`).
  - `SettingsSchema` (`app/services/settings_schema.rb`) is the one list of every `AppSettings` field: its group, its page (Settings, Backups or Access), its type, its range (read from AppSettings' `validates:` through `validators_on`), its label and help (`system.settings.fields.*`) and its validator (`SettingsSchema::Validators`). The pages render from it (`system/settings/_field`); `SettingsGroupUpdate` saves only the posted group's writable keys, answers `422` with nothing saved on any error, then writes the review-policy and MCP audit rows, refreshes MCP access and resets the embedding/summary clients. `LEGACY_KEYS` (`project_scan_roots`) is in no group and never written.
  - `SystemHealth` reuses `HomeSnapshot::Health`'s checks (`pill_for`, one embedding probe, timed; `embedding_status` and `scan_status` run once per page) and adds vector readiness, the queue backlog, the backup folder (writable, or creatable by `db:dump`; no disk-free figure), each scan root's mount mode, the version and pending migrations. `/system/health.json` carries words only: no path, URL or host name. When the vector search, scan mounts or migrations check raises (the database is down), it reads "can't check" instead of failing the page (a raw snapshot that raises reads "unavailable"); the error class and message go to the log as `[SystemHealth] …`, never into the JSON.
  - **Typed confirmation** (`TypedConfirmation`): backup restore (the file name), Regenerate all (`REGENERATE`), Drop indexes (`DROP`) and audit-log prune (the expired row count) compare `params[:confirmation]` on the server and answer `422` with no side effect on a mismatch. `typed_confirm_controller.js` only enables the button.
  - System › Access shows the operator credentials (`GraphMem::OperatorCredentials`, shared with the sign-in), the guest, the MCP token and the session lifetimes as configured / not configured, never a value.
  - Styles: the `ui-*` components plus `app/assets/tailwind/system.css`; `dashboard.css` is gone (1.63.0).
  - **Run all scheduled jobs now (1.81.0)**, for a machine that is off at the scheduled times: one switch on System › Background jobs runs every job of this environment's `config/recurring.yml` once (two backups count as one), in `ScheduledRun::ORDER`: backup, garbage collection, compaction, embedding backfill, fact keywords, the stale-memory and contradiction scan, review policies, the two clean-ups, export cleanup. An entry missing from `ORDER` runs last (a spec flags it). `ScheduledRunJob` is a step machine on an `OperationProgress` row (`scheduled_run`): steps run inline one at a time; a failing one is recorded and the run goes on; a step whose own setting is off is skipped; compaction is waited on (the job re-enqueues itself every minute until the compaction run ends).
    - **The switch:** Run → Stop → (Stopping…) → Resume or Start over; it never re-enables itself, so no second run starts while one is running or paused. A press made for another state (a stale tab) changes nothing.
    - **Stop** pauses compaction through its own pause, stops `FactKeywordsJob` and the embedding backfill between batches (`CooperativeStop`, a thread-scoped flag set only inside a scheduled run, so the same jobs never stop early on their schedule), and otherwise pauses after the current job. Resume re-runs a stopped step: their work lives in the database (pending paths, missing vectors, the compaction cursor).
    - **No timer:** after a power cut Solid Queue marks the running job failed (it doesn't run it again), so no live job is left for the row (`ScheduledRunJob.live_job?`: an unfinished, not failed `ScheduledRunJob` whose arguments carry the run's id). The card then says so and offers **Pause now**; Resume continues at the stored step. A job that raises outside a step pauses the run itself ("Interrupted: …"). A compaction run left `running` with no `DreamStateCompactionJob` behind it (two polls in a row) is started again, or paused by the run on Stop.
    - **One job per run:** Run takes a named lock (`GET_LOCK`), Resume and Stop work under the row lock, and the job's own writes too, so neither side overwrites the other's `details`. Each start or resume sets a new `token`, passed to the run's jobs; a job with another token (a retried old one) does nothing. The stop check reads past the query cache.
    - **Catch-up (1.86.0):** `ScheduledRunCatchUpJob` (`config/recurring.yml`, production only, every 15 minutes; never a step of the run: `ScheduledRun::EXCLUDED`), because Solid Queue skips a recurring slot it missed and a machine that is off at night never runs the night jobs. It acts only when the setting `scheduled_run_catch_up_enabled` is on (System › Settings, default on) and the oldest live Solid Queue supervisor (`SolidQueue::Process`, kind `Supervisor(…)`, still beating within `process_alive_threshold`; read from the queue database through `config.solid_queue.connects_to`) is at least `BOOT_GRACE` (20 min) old. Then: **a run cut off** (running, no Solid Queue job left for it, `ScheduledRunJob.live_job?`) is resumed at its stored step (`stop!(row, live: false)` pauses the orphan, then `resume!`), with one `resumed an interrupted run at step N` info line; one cut off while stopping is only paused (the operator asked it to stop); a run with a live job or one the operator paused is left alone (never auto-resumed). **Otherwise** a new run starts (`ScheduledRunJob.start!(trigger: "catch-up")`, one `started …` info line with the reasons) only when the nightly slot was missed: no scheduled run and no `CompactionRun` started at or after `due_since`, the previous fire time of the compaction entry's schedule (Fugit, in `SolidQueue.time_zone` as Solid Queue reads it; 20 h ago when no schedule can be read). A host that is off at night is therefore overdue on every boot, at the same time each day; one that stayed up ran the 3:00 compaction itself. A compaction run running with a `DreamStateCompactionJob` behind it also blocks. A paused one does not: the MCP write valve (`CompactionValve`) pauses it on writes, and on a host that is off at night only the run's compaction step (`CompactionRunner`) resumes it. Skips log a debug line. The run's `details["trigger"]` is `"manual"` (the button) or `"catch-up"`; the card then says "Started automatically (catch-up)".
    - **Status line:** the current step, when the run and the step started, the last progress (live through `OperationProgressChannel`), and the newest audit-log entry since the run started.
    - **Step progress (1.84.0):** one bar under the step label. `FactKeywordsJob` (keyword paths, then LLM words) and the embedding backfill report done/total next to their stop checks (`StepProgress`, thread-scoped like `CooperativeStop`); `ScheduledRunJob#record_progress` stores it on the step (at most every 2 s, only for the current run's job) and drops it when the step ends. Compaction and garbage collection are read from their own progress rows (`MaintenanceDashboardSnapshot#step_progress`); the other steps show the browser's indeterminate bar. Inside a scheduled run the LLM words have no per-run batch cap (Stop ends them between batches).
  - **Live Background jobs page (1.84.0):** `live_refresh_controller.js` polls `GET /system/jobs/cards`, a Turbo Stream `update … method="morph"` of `#jobs-cards` built from `MaintenanceDashboardSnapshot.cards` (no graph totals): every 3 s while a job runs, every 30 s otherwise, paused in a hidden tab and at once on coming back, an open `<details>` kept open. A poll never counts as session activity (`System::JobsController#refresh_session!`); one past the idle limit gets the sign-in page and the page goes there. The cable (`OperationProgressChannel`) still updates the scheduled run's status between polls. The cards share one bar (`system/jobs/_progress`). The Relation types card (1.93.0, `MaintenanceDashboardSnapshot#relation_types_snapshot`) shows the last sweep of any source and the unmapped-type count (cached for a minute: `UnmappedRelationTypes.cached_count`); `System::RelationTypesController` serves its dry run, the sweep, the report and the unmapped-types page under `/system/jobs/relation_types`.
- **Swagger UI** at `/api-docs` for REST API exploration

### Browser access, roles and CSP (UI-1, 1.56.0)

- **Shell.** Every page renders inside `layouts/application` (a sidebar from `ui/_sidebar`, toasts, a page-header slot); sign-in uses `layouts/auth`. Shell helpers live in `UiHelper`, the `ui-*` classes in `app/assets/tailwind/application.css`.
- **Roles.** `SessionAuthentication` resolves the session's role: `operator` (full access) or `guest` (read-only, disabled until a guest password is configured; `GraphMem::GuestCredentials`). `ApplicationController#authenticate!` handles sign-in and per-role expiry; `RoleAuthorization#authorize_role!` is deny-by-default: guests may run only actions a controller lists with `allow_guest` (Search, Explore, the Home redirect, Sign out) and get `403` elsewhere. `ApiAuthentication::GUEST_READ_ACTIONS` is the API's guest allowlist. `spec/requests/role_matrix_spec.rb` walks every route to pin this. `/mcp*` (Rack middleware) and ActionCable never accept a guest.
- **CSP.** Enforced (`config/initializers/content_security_policy.rb`): nonce-based `script-src`, `style-src 'self' 'unsafe-inline'`, `base-uri`/`form-action 'self'`, `frame-ancestors`/`object-src 'none'`, violations reported to `/csp-reports`. `/api-docs` keeps rswag's own policy.

## Change sets and undo (UI-4a, 1.57.0)

A **change set** (`change_sets`, `ChangeSet`) groups the writes of one user-visible change so the operator can undo them together. Audit rows point at it through `audit_logs.change_set_id`.

- **Who and why (1.65.0).** Every audit row and change set has:
  - **`actor`**, what the server knows: `mcp:<tool>` for MCP calls (set by `ApplicationTool#call_with_schema_validation!` around the tool's own `#call`), `operator:<user>@<ip>` / `guest:…` for the web UI, and `api:<X-MCP-Client>` (else `<ip|local>:<controller>`) for REST, all from `ApplicationController#set_current_actor`. Policies, compaction and jobs set their own (`policy:<name>`, `compaction:<run_id>`).
  - **`actor_claim`**, MCP only: what the client and its model say about themselves. That is the `X-MCP-Client` (unless "default"), the MCP session's `initialize` `clientInfo` (`<name>/<version>`, from the gem's `MCP::ServerContext#client_info`) and, on rows of records with a `source`, the `<client>/<model>` part of a `"<client>/<model>: <task>"` source. `ActorClaim` parses and sanitizes it (one line, no control characters, 255 at most). It is self-reported: shown as "claimed: …", never used to authorize, credit (`resolver_for` reads `actor`), filter or decide a policy.
  - **`reason`**, the first present of: a delete's `Current.deletion_reason`; an update's new `obsolescence_reason` (supersede, retire, soft delete); the `<task>` part of the record's source, on a create, an update that set the source, or an MCP call (an operator's edit or a job's update of an agent-written record isn't that agent's task); else none. Entities and relations have no source. Claims and derived reasons have control and format characters (bidi, zero-width) removed.
  - **Trust order:** the channel and tool (a server fact), then `X-MCP-Client` (client configuration), then `clientInfo` (client software), then the `source` prefix (model-written).
  - **Backfill:** `rake audit:backfill_actors` (dry run unless `APPLY=1`) gives the `graph.*` sets that MCP wrote before 1.65.0, and their rows, `mcp:graph_*`, plus a `backfilled · <who>` claim and a reason from the stored source. Other nil-actor sets are left: MCP and jobs can't be told apart.

- **What records a set.** `ChangeSet.record(kind:)` wraps each entry point:
  - `graph_write` / `graph_edit` / `graph_delete` (MCP and services): `graph.write`, `graph.edit`, `graph.delete`;
  - the review actions (`CompactionReviewService` apply, dismiss, restore, ignore, snooze and the bulk variants): `review.*`; group actions on the Review page (`ReviewGroupActions`): `review.group_apply`, `review.group_dismiss`, `review.group_snooze`;
  - the review policies (`ReviewPolicyRunner`, actor `policy:<name>`): `policy.<name>`, one set per batch of 200 rows;
  - every merge path (`NodeOperationsStrategy#merge_into`): `merge`, or the caller's kind: `maintenance.merge_node`, `compaction.auto_merge` (actor `compaction:<run_id>`, one set per merge), `api.write` (every non-GET `/api/v1` request), `explore.merge`;
  - dream state's orphan auto-parent (Dream State R1b): `compaction.auto_parent` (actor `compaction:<run_id>`, one set per orphan, the audit strategy). The auto-merge and the auto-parent set `Current.actor` too, so their audit rows carry the run's actor, not only the set;
  - Explore's edits (UI-4b, 1.61.0, `ExploreEdits`, actor `operator:<user>@<ip>`), one set per edit: `explore.entity_edit`, `explore.observation_add`, `explore.observation_edit` (a supersede), `explore.observation_retire`, `explore.relation_add`, `explore.relation_remove`, `explore.move` and `explore.merge`. Explore's own rules (project roots: rename only, and they can't move) live in `ExploreEdits`, not in `GraphEditService` or the strategy, so the MCP tools are unchanged. Propose deletion writes no set: it seeds a `delete_entity` review row (`source: "operator"`).
  - The `part_of` edges the project_id backfill adds (`ProjectIdBackfill`, actor `maintenance:project_id_backfill`): `maintenance.membership_repair`, one set per run that writes, undoable (the audit strategy).
  - A set opened inside another one joins it: a merge in a `graph_delete` batch or a review apply belongs to the outer set.
  - The relation type sweep (`RelationTypeSweep`, actor `compaction:<run_id>`, `job:relation_type_sweep`, `rake:canonicalize_relations` or `operator:<user>@<ip>`): `dream.relation_types`, one set per batch that writes. It is never undoable (below).
  - Imports, scans, observation dedupe and garbage collection are not recorded (their audit rows keep `change_set_id` NULL).
- **Lazy rows, no new locks.** `ChangeSet.record` opens no transaction and takes no lock. It only sets `Current.change_set`. The row is inserted by the first write that needs it, inside that write's transaction, so a set without changes never exists and a rolled-back write takes its set (and its snapshot entries) with it.
- **Snapshot.** One versioned JSON column holds what the audit trail lacks:
  - `merges`: one step per merge, from `EntityMergeSnapshot`: every source column, its vector as `HEX(embedding)`, the target's aliases before and after, the moved observation ids, and the source's edges (re-pointed or destroyed);
  - `review_rows`: the review fields before and after;
  - `suppressions_created` / `suppressions_deleted`;
  - `redo_merges`: on the undo of a merge, the merges to re-run.
- **Strategies and windows.**

  | Strategy | Set | Window |
  |---|---|---|
  | `merge` | merges only | 7 days |
  | `audit` | everything else | 30 days |
  | `none` | not undoable | — |

  A set becomes `none` with a reason: `mixed_merge` (merges plus other writes), `hard_delete` (an entity or observation deleted outside a merge), `audit_incomplete` (an audit row failed) or `snapshot_too_large` (over 4 MB; the merge still runs). Relation deletes and observation obsolete marks stay undoable. A kind listed in `ChangeSet::NOT_UNDOABLE_KINDS` starts as `none` with its reason: `dream.relation_types` is `relation_canonicalization` (a restored variant would be canonicalized again on save, and a merged row would collide with its twin). The sweep's report lists each change to reverse one by hand; System › Activity and the refusal say why the set can't be undone.
- **Undo.** `ChangeSetUndo.call(uuid, actor:)`, from the console or `POST /changes/:uuid/undo` (operator only).
  - **Audit sets** invert their audit rows newest first:
    - a create is destroyed;
    - an update gets its `from` values back;
    - a deleted relation is re-inserted with its original id and its stored type as it was (not canonicalized again, so undoing a `relation_retype` apply doesn't put a second copy of the new edge back; the next sweep canonicalizes it).
  - **Merge sets** re-insert the source with its original id and vector bytes, move its observations and edges back (a destroyed edge with its stored type), and remove only the aliases the merge added.
  - **Review rows and suppressions** are written back when the row is still in its "after" status; rows changed or pruned since are skipped and listed.
  - **Refusals are all-or-nothing.** A record changed since (the message names the actor and time), a name or id taken, a moved observation or edge, or a deleted target (naming the change to undo first) rolls everything back.
  - **The undo is itself a set** (`undo`), and undoing it is a `redo`, undoable in turn. Undoing a create deletes rows, so that undo is `hard_delete` and can't be redone.
- **Lock order and embeddings.** The undo takes the membership lock, then suppresses inline embeds, then opens the transaction, then takes row locks: the advisory-first rule, so it serializes with merges, imports, the backfill and review applies. The restored source keeps its old vector and `embedded_at`; text the undo changed (the target's aliases, restored names) is re-embedded after the lock is released with `EmbeddingService.embed_missing` (at most 50 inline, the rest by the daily backfill). Trust scores are recomputed, never restored.
- **Explore merges and the preview digest.** `EntityMergePreview.new(source_id, target_id).call` reads, without writing, what `merge_into_once` / `merge_locked!` would do: the observations that move (any status), the relations re-pointed and dropped (target duplicates and A↔B edges), the aliases gained (`NodeOperationsStrategy#merged_aliases`, shared with the merge), the `part_of` children re-parented, what happens to the source's own parent edge (`parent_edge`: `:taken` by a target that has no parent, or `:dropped` because the target keeps its own) and the entities that change project (the target and its subtree too, when it takes the source's parent), plus a SHA-256 `digest` of those id lists and the target's aliases. `EntityMergeService.call(source_id:, target_id:, digest:, actor:)` merges with `change_set_kind: "explore.merge"` and a `before_merge:` callable that `merge_into_once` runs on the locked rows, after its checks and before anything is written: when the preview recomputed there has another digest, the merge returns `status: :conflict` ("The graph changed since the preview, review it again.") and writes nothing. `before_merge:` defaults to `nil`, so every other merge path is unchanged.
- **The 10-minute toast.** Explore's undo toasts carry `until` (10 minutes); `toast_controller.js` then swaps **Undo** for "Undo it later from Home › Recent activity". The undo itself is still bounded by the strategy's window above.
- **Retention.** `ChangeSetPruneJob` (daily, 5:30 AM GMT) clears snapshots older than 30 days and deletes sets older than 90 days that no audit row references.

## Review queue: classification, limits and policies (UI-5a)

The review rows (`maintenance_report_rows`) that dream-state compaction, the stale scan, project scans and imports seed, shown on the Review & Fix page (`/review`, UI-5b).

- **Columns.** `group_key`, `anchor_entity_id`, `project_id`, `confidence` (0-1), `priority` (0-100), `expires_at` (a snooze's end), `resolved_by` (`operator`, `agent`, `policy:<name>`, `generator`) and `change_set_id` (the set that last changed the row, for undo). Status `expired` joins `active`, `ignored`, `approved`, `dismissed`. Suppressions gain `expires_at` (NULL = permanent) and `source` (`dismissed`, `snoozed`, `expired`, `policy`); an expired suppression no longer blocks its signature.
- **Classification.** `ReviewRowClassifier` runs at seed time: the group key and anchor per kind (pairs collapse both directions; observation kinds key on the owner), a confidence per kind and `priority = 100 × (0.6 impact + 0.4 confidence) × age boost` (+ a bump for well-connected anchors; Project roots weigh more; errors never sort below 40). `ReviewRowClassifier.backfill!` (also `bin/rails review:backfill`) classifies older rows. It also orders symmetric `relates_to` signatures, so A→B and B→A are one suggestion.
- **Limits at the source.** Per kind and run: `RUN_CAPS` (relationship 200, merge 100, orphan 100, contradiction 100, fact supersede 100, relation review 100; counted across one run's flushes through its reports, which pruning keeps while they hold a pending row (1.85.0); best score, then closest distance, then priority kept). The backlog ceiling (`review_backlog_ceiling` active rows of a kind, default 300) is soft: the room left under it is filled with the best items, and beyond it an item comes in only when it beats the lowest active priority (nothing is evicted). The report's data records `skipped_run_cap` / `skipped_backlog_full`. The queue pages in SQL (root-first rows, then priority); a text search scans at most 2,000 rows.
- **What can be applied in bulk.** Only `relationship_proposal` and `stale_memory` (`SAFE_BULK_KINDS`). Merges, deletes, moves and reparents (`DESTRUCTIVE_KINDS`, which also holds `relation_retype`, 1.93.0: its apply creates or removes a `part_of` edge, a membership move) and contradictions and fact supersedes (`CHOICE_KINDS`) are applied one by one; bulk apply skips them. `relation_review` (R1c, `INFORMATIONAL_KINDS`) is never applied at all.
- **Snooze.** `CompactionReviewService.snooze` (and `ignore`, which now snoozes for 30 days): status `ignored` until `expires_at`, with a matching "snoozed" suppression. Dismissing a snoozed signature makes the suppression permanent; undo brings the snooze back.
- **Contradictions.** The scheduled stale scan seeds one `contradiction` row per pair its contradiction pass finds (signature `contradiction|<low>-<high>`, either order). Since 1.85.0 its no-mention fallback pairs go to fact supersede instead (`FactSupersede::ContradictionFallback`, `docs/contradiction_detection.md`). Applying needs `keep_observation_id`: that observation is kept and the other is marked obsolete, a `review.apply` set (30 days) undone like any obsolete mark. MCP/API `detect_contradictions` in its default mode still seeds nothing (its `outdated_by_fact` mode seeds `fact_supersede` rows, below).
- **Policies.** `ReviewPolicyJob` runs `ReviewPolicyRunner` nightly at 5:00 GMT and after a compaction run, stale scan or project scan that seeded rows (never two at once). Each policy reads its `AppSettings` toggle uncached, acts on at most 500 rows per run, in batches of 200, each batch one undoable `policy.<name>` set:

  | Policy | Default | Does |
  |---|---|---|
  | `snooze_expiry` | always | snoozed rows whose snooze ended → active, snoozed suppression removed |
  | `dangling` | on | rows pointing at something gone, or whose effect already holds (R1c: a `relation_review` row whose relation is gone, or whose fact is gone or inactive) → dismissed (no suppression) |
  | `no_shared_subject` | on (needs `fact_keywords_enabled`) | 1.78.0: `contradiction` rows the detector would no longer pair (`ContradictionDetector.still_pairable?` since 1.85.0: dated events, another project's mention, two roots, no shared subject), and `fact_supersede` rows for unrelated facts (no term match; judged rows too since 1.80.0; since 1.96.1 also two facts on one entity whose LLM words share nothing, with their own reason), and since 1.82.0 unjudged rows that aren't the same fact with a different detail (a judged row is never dismissed just for being related), by their keyword paths → dismissed (no suppression). `bin/rails graph_mem:fact_keywords:review_report` counts them first, read-only |
  | `no_longer_flagged` | on | stale_memory rows the scanner no longer flags → dismissed (no suppression) |
  | `still_qualifies` | on | 1.85.0: `entity_merge`, `relationship_proposal` and `orphan_parent` rows the dream-state producers would no longer queue under their current evidence rules (R1b: an `orphan_parent` row whose entity a Project now `depends_on`, or whose type is dependency-like, too) → dismissed (no suppression) |
  | `expire_low_confidence` | on, 30 days | confidence < 0.4, untouched for N days → expired + 90-day suppression |
  | `auto_apply_expired_validity` | off | stale_memory `valid_until_elapsed` → applied (max 100) |
  | `auto_apply_relationships` | off | high-band proposals ≥ 0.90 confidence, never `part_of` → applied (max 50) |
  | `auto_apply_fact_supersede` | off | `fact_supersede` rows judged superseded ≥ 0.90, unguarded, scoped, operator-confirmed fact → applied (max 100) |
  | `auto_apply_contradiction` | **on** (key-value class) | 1.92.0: `contradiction` rows that are a plain value change (one `Key: value` line each, same key, one changed value, same unit; same entity, source and perspective; a clear newer side) → the older fact superseded by the newer (max 100). Free text only with `auto_apply_contradiction_free_text` |
  | `auto_apply_relation_retype` | off | Dream State R1b: `relation_retype` rows of operation `swap` (never `retype` or `add`) whose library is still dependency-like and whose project has no fact naming it with an ownership phrase → applied (max 100); a global name collision is skipped, a busy membership lock ends the step |

  Hard rule: a policy never applies a destructive or choice kind, whatever the settings say; `auto_apply_fact_supersede`, `auto_apply_contradiction` and `auto_apply_relation_retype` lift it for their own kind only (the last for `swap` rows only). Each run writes a `review_policy_run` report with the counts, the change-set uuids and the apply/dismiss rates per kind and score.

### The Review & Fix page (UI-5b, 1.58.0)

- **`ReviewController`** (operator only) serves `/review`: Needs attention, By kind, By project, Errors, Scan review, Resolved and Policies, plus row actions (`/review/rows/:uuid/…`), group actions (`/review/group/…`), "Run policies now", "Import suggest-merges" and `GET /review/live` (1.86.2: the rail counts, the policy-run state and, on Policies, the run list as Turbo Streams for `live_refresh_controller.js`; a poll never extends the session). `ReviewResponses` maps results to 200 (303 for HTML), 404 (the row is gone; a frame GET gets the message in its frame), 409 (a group changed since its preview), 422 (refused) and 503 (membership lock busy or a transient DB lock error), with **Undo** in the toast when the action's change set can be undone and the reason when it can't.
- **Ranking.** `ReviewDigest` groups active compaction and scan review rows by `group_key` (an unclassified row is a group of one) and ranks by priority alone, in SQL with a constant query count: the 10 groups at or above `review_attention_threshold` are the default view, and the nav badge counts them. `CompactionReviewService.items` (MCP `list_maintenance_review`) keeps its root-first order (Decision 13).
- **Preview.** `CompactionReviewApplier.preview(row, action_params)` runs apply's lookups without writing and returns the effects, warnings and the undo window ("not undoable: hard delete" for an entity delete). The confirm cards, the detail pane and MCP `apply_maintenance_review dry_run` use it.
- **Group actions.** `ReviewGroupActions` previews, then applies, dismisses or snoozes a group's pending rows (highest priority first, at most 100) in one change set. Apply only takes active (not snoozed) `SAFE_BULK_KINDS` rows and needs the preview's token: if the eligible rows changed meanwhile it answers a conflict and writes nothing. Dismiss and snooze take any kind, pending rows only; a snooze never replaces a permanent suppression. Each row's action commits on its own: the action succeeds (with Undo) when at least one row was written, and its message counts the failed rows. A busy lock before the first write answers 503; after it, the run stops and the message says how many rows are left.
- **Settings › Review policies** edits the policy toggles and limits; values outside `AppSettings::REVIEW_NUMBERS` are refused with 422, and each change writes an `AuditLog` row on the `AppSettings` record.

## Source facts and fact supersede (1.64.0)

An authoritative statement, such as an updated README line, can retire the older observations of
**its own project** that it contradicts. Old is not wrong: nothing here filters or scores by age,
and nothing acts across projects. Step list: `docs/plans/done/fact-supersede-plan.md`.

- **Source facts.** An active observation tagged `source-fact` (`SourceFact::SOURCE_FACT_TAG`) on
  an entity inside a project, or on the Project root; a tagged row outside any project is invalid.
  Optional `replaces:<term>` tags are search hints. The operator marks one in Explore
  (`explore.fact_mark`, undoable); agents write the tag with `graph_write` / `graph_edit`. A fact
  is **operator-confirmed** when the latest audit row that added the tag has an `operator:` actor.
  Source facts count as high-trust sources in `ObservationTrustRanker`.
- **`memory_observations.outdated_by_id`** (nullable, FK `ON DELETE SET NULL`): the fact that
  retired or superseded the row, set by `mark_obsolete!(outdated_by:)` / `supersede!(…, outdated_by:)`
  and allowed only on inactive rows, never on itself, and only for a fact of the same project.
  The panel shows "Outdated by: <fact>"; undo restores it from the audit row.
- **Candidates** (`FactSupersede::Candidates`, no LLM call): the fact's project's observations
  (members and root; the fact and other facts excluded), found by one `VEC_DISTANCE_COSINE`
  query within `fact_supersede_max_distance` (0.45) and an escaped `LIKE` per term (at most 5).
  A polarity flip adds 0.1. With fact keywords on (1.78.0), the two keyword paths are compared
  (`FactKeywords::Relatedness`, pending ones computed first). Since 1.82.0 only a candidate about
  the **same subject** that the fact covers is boosted (0.1, or 0.2 when it states a different
  detail); a merely related one isn't (1.78.0 boosted every related one). Kept in memory, not in
  the row's `signals`. Two facts are
  **related** when they share a mention or one mentions the other's own entity, and **unrelated**
  when both mention entities with none in common or (1.80.0) when they are held by two different
  entities the paths don't connect ("siblings": `gadget_mcp › Rework` and `gadget_mcp › Server Rules`).
  Never siblings: two entities a relation joins directly, a fact held by its project root (or by
  an entity with no project), and a path computed before its entity was renamed.
  **The same-fact ladder (1.82.0):** being related is not being the same fact, and only the same
  subject may make a fact obsolete. A fact's subjects are its own entity and its mentions; two facts
  have the **same subject** when both mention entities and one's subjects contain the other's
  (`covers`: `:both`, `:first`, `:second`). Their **details** (`FactKeywords::Details`: versions,
  numbers with a unit, dates; deterministic; the first text is the newer) are `:none`, `:same`,
  `:dropped` (only the older states one: a vaguer restatement, deduped by a scan, never a different
  detail) or `:different`. **The same fact
  with a different detail** ("Developed using Rails 8.0" / "Updated using Rails 8.1", Rails an
  entity) is the same subject, the fact covering the candidate, and different details. A fact held by
  the project root (an entity with no project doesn't count) covers a member's fact whose mentions it
  contains (never the reverse). **LLM words (1.83.0):** a fact that mentions no entity gets 1–3
  words naming what it is about, never a value (`FactKeywords::LlmWords`, the summary LLM chain in
  batches of 20, scoped like summaries; stored in `memory_observations.llm_keywords`, never merged
  with the path nor embedded, `llm_keywords_at` NULL = pending). Two such facts on one entity
  compare by their words (case and plurals folded): one containing the other's is the same subject
  (with `covers`), some shared is related, none is unrelated (`Comparison#words_unrelated?`, apart
  from `hard_unrelated?`, which is for entity mentions only). Such a pair gets no contradiction pair;
  1.83.0 still judged it for fact supersede, and since 1.96.1 (Steve, 2026-11-27: none of 67 such
  rows was right) fact supersede skips it like a path-unrelated one, on any one entity: never judged
  nor proposed unless a search term matched, and `no_shared_subject` dismisses its row, judged or
  not, with the reason "the facts' LLM words share nothing (one entity, no mentions)". A scan asks at most 3 word batches inside its reconcile (none after one the LLM
  didn't answer); `FactKeywordsJob` asks one project per call and walks past a batch that stamps
  nothing. `FactKeywordsJob` computes pending
  words after the paths (25 batches per run; 1.84.0: no cap inside a scheduled run, which stops
  between batches), a scan
  computes its own facts' words before its dedupe (a subset of the stored words is a duplicate), and
  `graph_mem:fact_keywords:llm_refresh` / `llm_report` refresh and count them. Setting
  `llm_keywords_enabled` (on; needs `fact_keywords_enabled`).
  Related entities without a project come back as **unscoped**: shown
  with a warning, applied by hand only (without `outdated_by`), never auto-applied.
- **Legacy guard** (`FactSupersede::LegacyGuard`, again at apply): `keep` (never proposed) when the
  text names another project by name or alias; `context` (proposed, never auto-applied, the
  judge is told) for a version, an environment or branch word the fact doesn't name, or an
  `experience` row.
- **Judge** (`FactSupersede::Judge`): one Ollama call per 8 candidates through
  `Llm::Router` (task `:judge`, `options: { num_ctx:, num_predict:, format: "json" }`). The
  prompt says the fact is authoritative for this project only and that age is not evidence; the
  statements are passed as JSON data. The answer is parsed strictly; anything missing, repeated
  or invalid leaves the candidate `unjudged`. `context` candidates are capped at 0.7. Since 1.82.0
  each statement carries its `subject` level (`same`, `related` or `unclear`), and the rules say
  "superseded" requires the same thing with a different detail: a statement about a related topic
  is "still_valid".
- **Proposals** (`FactSupersede::Proposals`): `FactSupersedeJob` (queued by the observation's
  `after_commit` for a new fact, a fact's new text or a new tag, when `fact_supersede_enabled`;
  one job per fact via Solid Queue's `limits_concurrency`) seeds `fact_supersede` rows
  ("Outdated by a fact") for `superseded` and `unjudged` verdicts only. A pair the keyword paths
  call unrelated and no search term found is neither judged nor proposed (1.80.0; before, only its
  `unjudged` row was skipped), and since 1.96.1 so is a pair on one entity whose LLM words share
  nothing (`Candidates#candidate_subject` reads `Comparison#words_unrelated?`). An `unjudged` row is proposed only for the same fact with a different
  detail, or a search-term match (1.82.0; before, for anything not unrelated). Signature
  `fact:<fact>|obs:<observation>`, so a dismissal suppresses that pair alone; run cap 100. The
  kind is a choice kind (never bulk or group applied). `CompactionReviewApplier::FactSupersede`
  supersedes (a replacement text) or retires inside `review.apply`, after re-checking the fact,
  the observation (under its row lock), the project and the guard. Pairs that already have a
  pending row or a suppression are skipped before the judge, except pending `unjudged` rows while
  the LLM is usable: a `superseded` verdict refreshes them, `still_valid` / `unrelated` dismisses
  them (no suppression). `detect_contradictions` with
  `mode: "outdated_by_fact"` runs the same pipeline for agents on `/mcp/maintenance`, judging at
  most 2 batches per call (the rest come back unjudged and the job, queued then, judges them), so a
  call doesn't wait on many LLM calls.
- **Operator-confirmed** means the latest audit row that added the tag or changed the fact's text
  in place has an `operator:` actor, so an agent's rewrite of an operator's fact makes it
  propose-only.
- **Fallbacks.** No embeddings: term match only (the job needs `replaces:` terms, else it
  records "nothing to search"). No LLM: every row is `unjudged` at confidence ≤ 0.5. Both down:
  the Find & supersede page still matches text and supersedes or retires by hand.
- **Auto-apply** (`ReviewPolicies::AutoApplyFactSupersede`, `enable_auto_apply_fact_supersede`,
  **off** by default): rows the judge marked `superseded` at or above
  `auto_apply_fact_supersede_min_confidence` (0.9), with no guard, a scoped entity and an
  operator-confirmed fact; at most 100 per run, in `policy.*` change sets. It lifts the AutoApply
  hard rule for this kind only.
- **Value changes** (1.92.0, `docs/plans/done/contradiction-auto-resolve-plan.md`). The contradiction
  pass of the stale scan (`ContradictionDetector`) also pairs two facts of one entity, with the same
  source and perspective, that differ only in a value ("Port: 3000" / "Port: 3001"), without a
  negative word: `FactKeywords::TokenDiff.value_change` classes the pair `:key_value` (one
  `Key: value` line each, the same key, one changed value, the same unit; no keyword gate) or
  `:free_text` (sentences that differ in place in 1-2 values; keyword gate kept). The row is an
  ordinary `contradiction` row with unchanged payload keys; the class is recomputed from the live
  texts wherever it matters.
  `ReviewPolicies::AutoApplyContradiction` (`enable_auto_apply_contradiction`, **on** by default)
  then applies the key-value class unattended: the older fact is marked `superseded` by the newer
  one through `CompactionReviewService.apply(..., resolution: :supersede)`, a Ruby keyword the MCP
  tool and the UI can't reach (their apply still marks the other side obsolete). Different keys,
  a changed unit, list-like values, a tie on which fact is newer and every other contradiction are
  left for the operator. Each batch is one `policy.auto_apply_contradiction` change set, undoable
  for 30 days. A revert sticks: a fact the policy superseded once (its audit row) that is active
  again is left for the operator on later runs. The contradiction card marks the tokens that differ (`ReviewHelper#review_diff_text`).
- **Find & supersede** (`/review/supersede`, `Review::SupersedeController`, operator only): an
  escaped text search in one project (or all projects, view only), inactive rows on request
  (view only), optionally with a source fact's candidates, guards and pending verdicts.
  `FactSupersede::Bulk` supersedes (one text, or the fact's text) or retires at most 200 rows of
  that project in one `explore.bulk_supersede` change set; rows that changed in between, and
  source facts, are skipped and counted. The changed observations' pending "Outdated by a fact"
  rows are dismissed in the same set (no suppression). It takes the membership lock first, like
  review applies and undo, so their lock order matches; a request waits at most 5 s for it, then
  answers 503 with nothing changed.

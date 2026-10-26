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
        Ollama (external) ──► SummaryGenerationClient (optional text synthesis)
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

The protocol itself is served by the official MCP Ruby SDK (`mcp` gem, pinned to 1.8.1), through
the adapter in `lib/graph_mem/official_mcp/`. The tool classes don't depend on the gem: the
adapter wraps them.
The decisions taken when moving from fast-mcp to the gem (D1–D14: session cap, allowed hosts and
origins, body caps, argument validation, removed aliases and `/mcp/sse`, exact gem pin) are listed
with graph_mem's answers in [the migration guide](guides/migrating-fast-mcp-to-mcp-gem.md) §2.

#### Official MCP SDK feature map

| Feature | `mcp` gem 1.8.1 | GraphMem |
|---|---|---|
| JSON-RPC dispatch, `initialize` negotiation (2024-11-05 … 2025-11-25), `server/discover` and the 2026-07-28 per-request lifecycle | `MCP::Server` | — |
| Tool, prompt and resource-template classes | `MCP::Tool`, `MCP::Prompt`, `MCP::ResourceTemplate` | generated from `ApplicationTool` / `ApplicationPrompt` / `ApplicationResource` by `ToolWrapper`, `PromptWrapper` and `ResourceCatalog` |
| One server per profile, with `instructions` and `capabilities` | `MCP::Server.new(instructions:, capabilities:)` | `ServerFactory.for(profile)`: the profile's tools and prompts, `McpInstructions`, and explicit capabilities (no `subscribe` or `listChanged`) |
| Argument validation | `validate_tool_call_arguments` (turned off) | the tool validates after `ParameterNormalizer` (aliases for required keys) |
| Error formatting | `-32603` for unhandled errors, `exception_reporter` | `ToolWrapper` turns every tool error into the `ToolError` envelope as an `isError` result; gem-side errors go to `Rails.error` |
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
| `MemoryEntitiesController` | CRUD, search, merge |
| `MemoryObservationsController` | CRUD, delete_duplicates |
| `MemoryRelationsController` | CRUD with filters |
| `ContextController` | GET/POST/DELETE context |
| `SearchController` | subgraph search, subgraph_by_ids |
| `BulkController` | atomic bulk operations |
| `MaintenanceController` | suggest_merges, stats |
| `StatusController` | health check, time |
| `GraphDataController` | Cytoscape-format graph data for web UI |
| `GraphTraversalController` | multi-hop traverse, shortest_path |

### 3. Application Logic Layer

#### Graph Traversal (`app/services/graph_traversal_service.rb`)

`GraphTraversalService` performs bounded breadth-first expansion and hop-count shortest-path searches. It queries one frontier at a time, supports incoming/outgoing/bidirectional traversal, canonical relation-type filters, cycle protection, deterministic ordering, and result caps. MCP tools, REST endpoints, and `MemoryGraphResource` share this implementation.

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
- `AgentContextsSnapshot` exposes active clients, current projects, and recent tool activity to the operator dashboard

#### Embedding configuration (`app/services/embedding_config.rb`)

Resolves URL, model, provider, and dimensions with priority **AppSettings → ENV → defaults**. Used by `EmbeddingService`, rake tasks, and the operator embeddings UI. Operators can edit values under **System Settings → Embeddings**; workers pick up changes after save via `EmbeddingService.reset_instance!`.

#### Summarization configuration (`app/services/summarization_config.rb`)

Resolves URL, model, provider, timeout, and output token limits with the same **AppSettings → ENV → defaults** priority. Used by `SummaryGenerationClient` and `SummarizerService`. Operators configure values under **System Settings → Summaries**; saving resets `SummaryGenerationClient` so subsequent summarize requests use the new settings.

#### Embedding Service (`app/services/embedding_service.rb`)

Calls Ollama (or an OpenAI-compatible endpoint) to generate vectors from entity composite text. Uses `EmbeddingConfig.resolved_config`. Gracefully degrades when unavailable.

### 4. Data Access Layer

#### Core Models

- **MemoryEntity** - Graph node with name, entity_type, aliases, description, and VECTOR(768) embedding
- **MemoryObservation** - Versioned text facts plus confidence, provenance, validity, tags, and `active`/`obsolete`/`superseded` lifecycle state, with its own VECTOR(768) embedding
- **MemoryRelation** - Directed edge with a canonicalized relation_type, weight, confidence, and structured properties
- **EntityTypeMapping** - Canonicalization rules for entity types
- **RelationTypeMapping** - Canonicalization rules for relation types
- **AuditLog** - Change tracking for entities
- **MaintenanceReport** - Results from maintenance operations
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
- **Data Exchange** for import/export (`DataExchangeController`). Import matching and execution share `ImportEntityResolver`: lookups use exact name plus canonical entity type (for example `workspace` → `Project`) **within the project scope** — entity names are unique per `project_scope` (`memory_entities.project_id`, NULL = shared global namespace), so the same name can exist once per project. The first Project-typed tree root claims the import's scope; unresolvable *reference* endpoints become global stubs that the first repo to declare them claims into its project (two or more declarers leave the stub global and queue `AMBIGUOUS`/`repoint` proposals). Same-name entities of a different type in the same scope are not treated as matches; the import creates a new entity path instead of attaching observations or relations to the wrong typed node.
  - Import payloads may also carry a top-level `relations` array of name+type-addressed edges (`from_name`/`from_type`/`to_name`/`to_type`/`relation_type` + optional `weight`, `confidence`, `properties`). `ImportExecutionStrategy` applies them as a second pass inside the same transaction, after the entity tree exists; unresolved endpoints are counted in `ImportReport.relations_unresolved` instead of failing.
  - **Graphify ingest**: `GraphifyImporter` (`app/services/graphify_importer.rb`) translates a Graphify `graph.json` (node-link format) into this payload deterministically — Project → File → Class/Module → Method/Constant containment becomes `part_of` tree links, every entity gets a `"Defined at <file><line>"` provenance observation with `source: "graphify"`, and non-tree code edges (`calls`, `inherits`, `mixes_in`, `imports_from` → `depends_on`) flow through `relations` with their `EXTRACTED`/`INFERRED` provenance kept in `properties`. `AMBIGUOUS` edges are withheld and queued as `relationship_proposal` items in the `scan_review` queue — never auto-applied. Rake tasks: `graphify:translate GRAPH=… PROJECT=… [OUT=…]` writes a reviewable import file; `graphify:import GRAPH=… PROJECT=…` runs the whole flow headless (match → auto-accept → execute with `OperationProgress`). Re-runs are idempotent: entities match by name+type, duplicate provenance observations short-circuit, and relations dedupe via `(from, to, type)` uniqueness.

    Re-imports are incremental rescans: the translated payload carries `rescan: true`, and when the root already has graphify-sourced descendants the executor diffs stored provenance against the payload — a `graph.json` is the FULL repo scan by contract, so absence means removed code. Vanished entities get their provenance observations obsoleted and drifted `Defined at` lines `supersede!`d (the merge dedups the replacement), while vanished entities/edges are queued as `delete_entity`/`delete_relation` items in `scan_review` — nothing is auto-deleted. Same-tree moves (stored parent still inside the subtree) stay importable and become `reparent_entity` items; pending delete proposals for items a scan brought back are auto-dismissed so a stale proposal can't delete live data. `GraphifyRescan` owns the diffing; `RESCAN=0` opts out. Dismissed proposals stay dismissed for the current scan's findings, but a *manually* dismissed (or ignored) proposal can return on a later rescan while the finding still holds — suppression (`MaintenanceReportSuppression`) is the permanent route, and `apply` refuses rows that are not active/ignored.

  - **Rails AST extractor**: `RailsAstExtractor` (`app/services/rails_ast_extractor.rb`) produces the same node-link `graph.json` shape for a Rails app's own code — deterministic Prism-only, two passes (index declarations, then emit) so associations resolve order-independently. It covers `app/models`, `app/controllers`, and `config/routes.rb`: associations (`belongs_to`/`has_many`/`has_one`/HABTM; `class_name:` wins, else lexical→top-level→basename resolution — `EXTRACTED`/`INFERRED`, multi-namespace basename ties are `AMBIGUOUS` → scan_review), `include`/`extend`/`prepend` → `mixes_in`, `scope`/`enum` → Method nodes, `delegate` → `delegates_to`, and `resources`/`resource`/verb macros → `Route` entities (`GET /x/:id`) `part_of` routes.rb with `routes_to` edges to `Controller#action`. Payloads declare `"producer": "rails_ast_extractor"`, which stamps that name on provenance observations, relation `properties.source`, and the `rescan` marker — re-imports diff only that producer's facts, so a rails_ast rescan never flags graphify facts and vice versa. Edges from in-subtree sources to foreign-project endpoints are allowed and tagged `properties.cross_repo = true` (counted in `ImportReport.relations_cross_repo`) so `belongs_to`-style edges can bridge repos. Rake: `rails_ast:extract REPO=… [PROJECT=…] [OUT=…]` writes `graph.json` for review/Data-Exchange upload; `rails_ast:import REPO=… [PROJECT=…]` runs extract → match → execute headless (`RESCAN=0` opts out of the rescan pass).
- **Operator Dashboard** with MCP client/project context status from `AgentContextsSnapshot`
- **Swagger UI** at `/api-docs` for REST API exploration

### Browser access, roles and CSP (UI-1, 1.56.0)

- **Shell.** Every page renders inside `layouts/application` (a sidebar from `ui/_sidebar`, toasts, a page-header slot); sign-in uses `layouts/auth`. Shell helpers live in `UiHelper`, the `ui-*` classes in `app/assets/tailwind/application.css`.
- **Roles.** `SessionAuthentication` resolves the session's role: `operator` (full access) or `guest` (read-only, disabled until a guest password is configured; `GraphMem::GuestCredentials`). `ApplicationController#authenticate!` handles sign-in and per-role expiry; `RoleAuthorization#authorize_role!` is deny-by-default: guests may run only actions a controller lists with `allow_guest` (Search, Explore, the Home redirect, Sign out) and get `403` elsewhere. `ApiAuthentication::GUEST_READ_ACTIONS` is the API's guest allowlist. `spec/requests/role_matrix_spec.rb` walks every route to pin this. `/mcp*` (Rack middleware) and ActionCable never accept a guest.
- **CSP.** Enforced (`config/initializers/content_security_policy.rb`): nonce-based `script-src`, `style-src 'self' 'unsafe-inline'`, `base-uri`/`form-action 'self'`, `frame-ancestors`/`object-src 'none'`, violations reported to `/csp-reports`. `/api-docs` keeps rswag's own policy.

## Change sets and undo (UI-4a, 1.57.0)

A **change set** (`change_sets`, `ChangeSet`) groups the writes of one user-visible change so the operator can undo them together. Audit rows point at it through `audit_logs.change_set_id`.

- **What records a set.** `ChangeSet.record(kind:)` wraps each entry point:
  - `graph_write` / `graph_edit` / `graph_delete` (MCP and services): `graph.write`, `graph.edit`, `graph.delete`;
  - the review actions (`CompactionReviewService` apply, dismiss, restore, ignore, snooze and the bulk variants): `review.*`; group actions on the Review page (`ReviewGroupActions`): `review.group_apply`, `review.group_dismiss`, `review.group_snooze`;
  - the review policies (`ReviewPolicyRunner`, actor `policy:<name>`): `policy.<name>`, one set per batch of 200 rows;
  - every merge path (`NodeOperationsStrategy#merge_into`): `merge`, or the caller's kind: `maintenance.merge_node`, `compaction.auto_merge` (actor `compaction:<run_id>`, one set per merge), `api.write` (every non-GET `/api/v1` request).
  - A set opened inside another one joins it: a merge in a `graph_delete` batch or a review apply belongs to the outer set.
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

  A set becomes `none` with a reason: `mixed_merge` (merges plus other writes), `hard_delete` (an entity or observation deleted outside a merge), `audit_incomplete` (an audit row failed) or `snapshot_too_large` (over 4 MB; the merge still runs). Relation deletes and observation obsolete marks stay undoable.
- **Undo.** `ChangeSetUndo.call(uuid, actor:)`, from the console or `POST /changes/:uuid/undo` (operator only).
  - **Audit sets** invert their audit rows newest first:
    - a create is destroyed;
    - an update gets its `from` values back;
    - a deleted relation is re-inserted with its original id.
  - **Merge sets** re-insert the source with its original id and vector bytes, move its observations and edges back, and remove only the aliases the merge added.
  - **Review rows and suppressions** are written back when the row is still in its "after" status; rows changed or pruned since are skipped and listed.
  - **Refusals are all-or-nothing.** A record changed since (the message names the actor and time), a name or id taken, a moved observation or edge, or a deleted target (naming the change to undo first) rolls everything back.
  - **The undo is itself a set** (`undo`), and undoing it is a `redo`, undoable in turn. Undoing a create deletes rows, so that undo is `hard_delete` and can't be redone.
- **Lock order and embeddings.** The undo takes the membership lock, then suppresses inline embeds, then opens the transaction, then takes row locks: the advisory-first rule, so it serializes with merges, imports, the backfill and review applies. The restored source keeps its old vector and `embedded_at`; text the undo changed (the target's aliases, restored names) is re-embedded after the lock is released (at most 50 inline, the rest by the daily backfill). Trust scores are recomputed, never restored.
- **Retention.** `ChangeSetPruneJob` (daily, 5:30 AM GMT) clears snapshots older than 30 days and deletes sets older than 90 days that no audit row references.

## Review queue: classification, limits and policies (UI-5a)

The review rows (`maintenance_report_rows`) that dream-state compaction, the stale scan, project scans and imports seed, shown on the Review & Fix page (`/review`, UI-5b; the old `/data_exchange/compaction_review` URL redirects there).

- **Columns.** `group_key`, `anchor_entity_id`, `project_id`, `confidence` (0-1), `priority` (0-100), `expires_at` (a snooze's end), `resolved_by` (`operator`, `agent`, `policy:<name>`, `generator`) and `change_set_id` (the set that last changed the row, for undo). Status `expired` joins `active`, `ignored`, `approved`, `dismissed`. Suppressions gain `expires_at` (NULL = permanent) and `source` (`dismissed`, `snoozed`, `expired`, `policy`); an expired suppression no longer blocks its signature.
- **Classification.** `ReviewRowClassifier` runs at seed time: the group key and anchor per kind (pairs collapse both directions; observation kinds key on the owner), a confidence per kind and `priority = 100 × (0.6 impact + 0.4 confidence) × age boost` (+ a bump for well-connected anchors; Project roots weigh more; errors never sort below 40). `ReviewRowClassifier.backfill!` (also `bin/rails review:backfill`) classifies older rows. It also orders symmetric `relates_to` signatures, so A→B and B→A are one suggestion.
- **Limits at the source.** Per kind and run: `RUN_CAPS` (relationship 200, merge 100, orphan 100, contradiction 100; counted across one run's flushes, best priority kept). The backlog ceiling (`review_backlog_ceiling` active rows of a kind, default 300) is soft: the room left under it is filled with the best items, and beyond it an item comes in only when it beats the lowest active priority (nothing is evicted). The report's data records `skipped_run_cap` / `skipped_backlog_full`. The queue pages in SQL (root-first rows, then priority); a text search scans at most 2,000 rows.
- **What can be applied in bulk.** Only `relationship_proposal` and `stale_memory` (`SAFE_BULK_KINDS`). Merges, deletes, moves and reparents (`DESTRUCTIVE_KINDS`) and contradictions (`CHOICE_KINDS`) are applied one by one; bulk apply skips them.
- **Snooze.** `CompactionReviewService.snooze` (and `ignore`, which now snoozes for 30 days): status `ignored` until `expires_at`, with a matching "snoozed" suppression. Dismissing a snoozed signature makes the suppression permanent; undo brings the snooze back.
- **Contradictions.** The scheduled stale scan seeds one `contradiction` row per pair its contradiction pass finds (signature `contradiction|<low>-<high>`, either order). Applying needs `keep_observation_id`: that observation is kept and the other is marked obsolete, a `review.apply` set (30 days) undone like any obsolete mark. MCP/API `detect_contradictions` still seed nothing.
- **Policies.** `ReviewPolicyJob` runs `ReviewPolicyRunner` nightly at 5:00 GMT and after a compaction run, stale scan or project scan that seeded rows (never two at once). Each policy reads its `AppSettings` toggle uncached, acts on at most 500 rows per run, in batches of 200, each batch one undoable `policy.<name>` set:

  | Policy | Default | Does |
  |---|---|---|
  | `snooze_expiry` | always | snoozed rows whose snooze ended → active, snoozed suppression removed |
  | `dangling` | on | rows pointing at something gone, or whose effect already holds → dismissed (no suppression) |
  | `no_longer_flagged` | on | stale_memory rows the scanner no longer flags → dismissed (no suppression) |
  | `expire_low_confidence` | on, 30 days | confidence < 0.4, untouched for N days → expired + 90-day suppression |
  | `auto_apply_expired_validity` | off | stale_memory `valid_until_elapsed` → applied (max 100) |
  | `auto_apply_relationships` | off | high-band proposals ≥ 0.90 confidence, never `part_of` → applied (max 50) |

  Hard rule: a policy never applies a destructive or choice kind, whatever the settings say. Each run writes a `review_policy_run` report with the counts, the change-set uuids and the apply/dismiss rates per kind and score.

### The Review & Fix page (UI-5b, 1.58.0)

- **`ReviewController`** (operator only) serves `/review`: Needs attention, By kind, By project, Errors, Scan review, Resolved and Policies, plus row actions (`/review/rows/:uuid/…`), group actions (`/review/group/…`), "Run policies now" and "Import suggest-merges". `ReviewResponses` maps results to 200 (303 for HTML), 404, 409 (a group changed since its preview), 422 (refused) and 503 (membership lock busy or a transient DB lock error), with **Undo** in the toast when the action's change set can be undone and the reason when it can't.
- **Ranking.** `ReviewDigest` groups active compaction and scan review rows by `group_key` (an unclassified row is a group of one) and ranks by priority alone, in SQL with a constant query count: the 10 groups at or above `review_attention_threshold` are the default view, and the nav badge counts them. `CompactionReviewService.items` (MCP `list_maintenance_review`) keeps its root-first order (Decision 13).
- **Preview.** `CompactionReviewApplier.preview(row, action_params)` runs apply's lookups without writing and returns the effects, warnings and the undo window ("not undoable: hard delete" for an entity delete). The confirm cards, the detail pane and MCP `apply_maintenance_review dry_run` use it.
- **Group actions.** `ReviewGroupActions` previews, then applies, dismisses or snoozes a group's pending rows (highest priority first, at most 100) in one change set. Apply only takes `SAFE_BULK_KINDS` and needs the preview's token: if the eligible rows changed meanwhile it answers a conflict and writes nothing. Dismiss and snooze take any kind, pending rows only; a snooze never replaces a permanent suppression.
- **Settings › Review policies** edits the policy toggles and limits; values outside `AppSettings::REVIEW_NUMBERS` are refused with 422, and each change writes an `AuditLog` row on the `AppSettings` record.


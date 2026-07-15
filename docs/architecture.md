# GraphMem Architecture

This document provides an overview of GraphMem's architecture, explaining how the various components work together to provide a complete graph-based memory system accessed through the Model Context Protocol (MCP) and a REST API.

## System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  MCP Clients (Cursor, etc.)          REST / Web UI Clients      │
│         │                                    │                  │
│   JSON-RPC/SSE                          HTTP/JSON               │
│         │                                    │                  │
│  ┌──────▼──────────┐              ┌──────────▼───────────┐      │
│  │  FastMcp Server │              │  Rails Controllers   │      │
│  │  (21 MCP Tools) │              │  (api/v1/*)          │      │
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
```

GraphMem follows a layered architecture that separates concerns between:

1. **MCP Interface Layer** - 27 tools accessed via JSON-RPC/SSE
2. **REST API Layer** - Traditional RESTful endpoints mirroring MCP capabilities
3. **Application Logic Layer** - Search strategies, context scoping, embedding service
4. **Data Access Layer** - ActiveRecord models with vector extensions
5. **Storage Layer** - MariaDB with native VECTOR support

## Component Breakdown

### 1. MCP Interface Layer (27 tools)

Tools are Ruby classes in `app/tools/` that inherit from `ApplicationTool` (which inherits from `FastMcp::Tool`). They auto-register via `ApplicationTool.descendants` in `config/initializers/fast_mcp.rb`.

Tool categories:
- **Context** (3): `set_context`, `get_context`, `clear_context`
- **Entity CRUD** (4): `create_entity`, `get_entity`, `update_entity`, `delete_entity`
- **Observation** (3): `create_observation`, `update_observation`, `delete_observation`
- **Relation** (3): `create_relation`, `delete_relation`, `find_relations`
- **Graph Traversal** (2): `traverse_graph`, `find_shortest_path`
- **Search** (4): `search_entities`, `search_subgraph`, `list_entities`, `get_subgraph_by_ids`
- **Batch/Maintenance** (6): `bulk_update`, `suggest_merges`, `merge_entities`, `dream_state_status`, `get_maintenance_reports`, `get_graph_stats`
- **Utility** (2): `get_version`, `get_current_time`

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
- **VectorSearchStrategy** - Semantic search using MariaDB VECTOR cosine distance, with a quality gate that filters results above a maximum cosine distance threshold
- **HybridSearchStrategy** - Combines text and vector via weighted Reciprocal Rank Fusion (RRF), then applies post-fusion relevance boosts: exact name matching, entity type priority, structural importance (relation count), and graduated context boosting
- **SearchRelevanceBooster** - Shared module providing boost constants and a `rank_entity_ids` method used by both `HybridSearchStrategy` and `SearchSubgraphTool`

#### Context Scoping (`app/models/graph_mem_context.rb`)

Persisted per-client storage for the active project context. MCP clients identify
themselves with the `X-MCP-Client` header; `ApplicationTool` normalizes HTTP
header key variants before `GraphMemContext` stores the scope in the
`agent_contexts` table. Agents without a client header share the `"default"`
bucket for backward compatibility. When set:
- `GraphMemContext.scoped_entity_ids` returns the project ID plus all entities with `part_of` relations to it
- `HybridSearchStrategy` applies a graduated context boost (stronger for the root project entity, lighter for its children)
- `SearchSubgraphTool` ranks results using `SearchRelevanceBooster` with context-aware scoring
- `AgentContextsSnapshot` exposes active clients, current projects, and recent tool activity to the operator dashboard

#### Embedding configuration (`app/services/embedding_config.rb`)

Resolves URL, model, provider, and dimensions with priority **AppSettings → ENV → defaults**. Used by `EmbeddingService`, rake tasks, and the operator embeddings UI. Operators can edit values under **System Settings → Embeddings**; workers pick up changes after save via `EmbeddingService.reset_instance!`.

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

1. MCP client sends JSON-RPC request via SSE or STDIO transport
2. `FastMcp::Server` routes to the appropriate tool class
3. `ApplicationTool` resolves the caller's MCP client ID from request headers and records activity in `agent_contexts`
4. `ApplicationTool#call_with_schema_validation!` normalizes incoming parameters via `ParameterNormalizer` (camelCase to snake_case, entity name to ID resolution, `operations` array parsing for `bulk_update`)
5. Tool validates normalized parameters (via Dry::Schema `arguments` block)
6. Tool executes business logic using ActiveRecord models and search strategies
7. Results are returned as a Ruby hash, serialized to JSON by FastMcp
8. Response delivered to client via the transport

### Parameter Normalization

`ParameterNormalizer` (`app/tools/concerns/parameter_normalizer.rb`) ensures compatibility with both graph_mem's native snake_case/ID-based conventions and the `@modelcontextprotocol/server-memory` camelCase/name-based conventions. This runs at step 3 before schema validation, handling:

- **camelCase to snake_case key conversion** (recursive, for nested hashes in arrays)
- **Standard field aliases** (`content` to `text_content`, `entity_name` to `entity_id` via DB lookup)
- **Entity name resolution** (string entity names resolved to integer IDs via `MemoryEntity.find_by`)
- **`operations` array parsing** (for `bulk_update` only: type-discriminated items split into three arrays)

REST API requests follow a similar path through Rails controllers instead of MCP tools, sharing the same models, strategies, and services.

## Web UI

GraphMem includes a web UI (served by Rails) for browsing and managing the knowledge graph:

- **Graph visualization** using Cytoscape.js (data from `GraphDataController`)
- **Entity browser** with search, create, edit, delete
- **Data Exchange** for import/export (`DataExchangeController`)
- **Operator Dashboard** with MCP client/project context status from `AgentContextsSnapshot`
- **Swagger UI** at `/api-docs` for REST API exploration

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

1. **MCP Interface Layer** - 21 tools accessed via JSON-RPC/SSE
2. **REST API Layer** - Traditional RESTful endpoints mirroring MCP capabilities
3. **Application Logic Layer** - Search strategies, context scoping, embedding service
4. **Data Access Layer** - ActiveRecord models with vector extensions
5. **Storage Layer** - MariaDB with native VECTOR support

## Component Breakdown

### 1. MCP Interface Layer (21 tools)

Tools are Ruby classes in `app/tools/` that inherit from `ApplicationTool` (which inherits from `FastMcp::Tool`). They auto-register via `ApplicationTool.descendants` in `config/initializers/fast_mcp.rb`.

Tool categories:
- **Context** (3): `set_context`, `get_context`, `clear_context`
- **Entity CRUD** (4): `create_entity`, `get_entity`, `update_entity`, `delete_entity`
- **Observation** (2): `create_observation`, `delete_observation`
- **Relation** (3): `create_relation`, `delete_relation`, `find_relations`
- **Search** (4): `search_entities`, `search_subgraph`, `list_entities`, `get_subgraph_by_ids`
- **Batch/Maintenance** (3): `bulk_update`, `suggest_merges`, `get_graph_stats`
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

### 3. Application Logic Layer

#### Search Strategies (`app/strategies/`)

- **EntitySearchStrategy** - Text-based search with token matching and relevance scoring
- **VectorSearchStrategy** - Semantic search using MariaDB VECTOR cosine distance, with a quality gate that filters results above a maximum cosine distance threshold
- **HybridSearchStrategy** - Combines text and vector via weighted Reciprocal Rank Fusion (RRF), then applies post-fusion relevance boosts: exact name matching, entity type priority, structural importance (relation count), and graduated context boosting
- **SearchRelevanceBooster** - Shared module providing boost constants and a `rank_entity_ids` method used by both `HybridSearchStrategy` and `SearchSubgraphTool`

#### Context Scoping (`app/models/graph_mem_context.rb`)

Thread-local storage for the active project context. When set:
- `GraphMemContext.scoped_entity_ids` returns the project ID plus all entities with `part_of` relations to it
- `HybridSearchStrategy` applies a graduated context boost (stronger for the root project entity, lighter for its children)
- `SearchSubgraphTool` ranks results using `SearchRelevanceBooster` with context-aware scoring

#### Embedding Service (`app/services/embedding_service.rb`)

Calls Ollama to generate 768-dimensional vectors from entity composite text. Configurable via `OLLAMA_URL` and `EMBEDDING_MODEL` environment variables. Gracefully degrades when unavailable.

### 4. Data Access Layer

#### Core Models

- **MemoryEntity** - Graph node with name, entity_type, aliases, description, and VECTOR(768) embedding
- **MemoryObservation** - Text content attached to entities, with its own VECTOR(768) embedding
- **MemoryRelation** - Directed edge between entities with a relation_type
- **EntityTypeMapping** - Canonicalization rules for entity types
- **AuditLog** - Change tracking for entities
- **MaintenanceReport** - Results from maintenance operations

### 5. Storage Layer

MariaDB 11.8 with:
- Native `VECTOR(768)` columns for entity and observation embeddings
- `MHNSW` approximate nearest-neighbor indexes for cosine distance search
- Counter caches (`memory_observations_count`) for performance
- Foreign key constraints for referential integrity

## Data Flow

A typical MCP request flows through:

1. MCP client sends JSON-RPC request via SSE or STDIO transport
2. `FastMcp::Server` routes to the appropriate tool class
3. `ApplicationTool#call_with_schema_validation!` normalizes incoming parameters via `ParameterNormalizer` (camelCase to snake_case, entity name to ID resolution, `operations` array parsing for `bulk_update`)
4. Tool validates normalized parameters (via Dry::Schema `arguments` block)
5. Tool executes business logic using ActiveRecord models and search strategies
6. Results are returned as a Ruby hash, serialized to JSON by FastMcp
7. Response delivered to client via the transport

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
- **Swagger UI** at `/api-docs` for REST API exploration

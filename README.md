# GraphMem: Graph-Based Memory MCP Server

GraphMem is a Ruby on Rails application implementing a Model Context Protocol (MCP) server for graph-based memory management. It enables AI assistants and other clients to create, retrieve, search, and manage knowledge entities and their relationships through a standardized interface.

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](lib/graph_mem/version.rb)
[![Rails](https://img.shields.io/badge/rails-8.0.2-orange.svg)](Gemfile)
[![Ruby](https://img.shields.io/badge/ruby-3.4.1-red.svg)](Gemfile)

## Overview

GraphMem provides persistent, structured storage for knowledge entities, their relationships, and observations. It's designed as an MCP server that enables AI assistants to maintain memory across sessions, build domain-specific knowledge graphs, and effectively reference past interactions.

**Key capabilities in v1.0:**
- **Vector semantic search** via MariaDB 11.8 native VECTOR support + Ollama embeddings
- **Entity type canonicalization** to prevent graph fragmentation
- **Auto-deduplication** on entity creation
- **Hybrid search** combining text tokenization with vector similarity
- **Docker Compose** deployment with auto-start support
- **LAN-wide embedding** architecture using a centralized Ollama host

## Technology Stack

* **Ruby**: 3.4.1+
* **Rails**: 8.0.2+
* **MCP Implementation**: [fast-mcp](https://github.com/yjacquin/fast-mcp) gem, vers. 1.5+
* **Database**: MariaDB 11.8+ (VECTOR support required)
* **Embeddings**: Ollama with nomic-embed-text (768 dimensions)

## Features

### MCP Tools

GraphMem exposes the following MCP tools:

#### Entity Management
* `create_entity` -- Create new entities with auto-dedup check
* `get_entity` -- Retrieve entities by ID with observations and relations
* `update_entity` -- Modify entity name, type, aliases, description
* `delete_entity` -- Remove entities and all associated data
* `search_entities` -- Hybrid text + vector semantic search with relevance ranking
* `list_entities` -- Paginated listing of all entities

#### Observation Management
* `create_observation` -- Add observations to existing entities
* `delete_observation` -- Remove observations

#### Relationship Management
* `create_relation` -- Create typed relationships between entities
* `delete_relation` -- Remove relationships
* `find_relations` -- Find relationships by entity or type
* `get_subgraph_by_ids` -- Get connected subgraph of specified entities
* `search_subgraph` -- Search across entities and observations with pagination

#### Context and Workflow
* `set_context` -- Scope subsequent operations to a project
* `get_context` -- Check the active project context
* `clear_context` -- Remove project scoping
* `bulk_update` -- Batch create entities, observations, and relations atomically
* `suggest_merges` -- Find potential duplicate entities via vector similarity

#### Utility
* `get_version` -- Server version
* `get_current_time` -- Server time in ISO 8601

### MCP Resources

* `memory_entities` -- Query entities with filtering, sorting, and relation inclusion
* `memory_observations` -- Access observations with advanced filtering
* `memory_relations` -- Query relationships with bidirectional entity inclusion
* `memory_graph` -- Graph traversals starting from any entity

### REST API

Full REST API at `/api/v1` for direct integration. Swagger docs available at `/api-docs`.

### Graph Visualization

Interactive Cytoscape.js-based graph visualization at the server root (`/`), with contextual menus, drag-and-drop operations, and data management features.

## Quick Start with Docker

```bash
# Clone and enter the project
git clone https://github.com/steveoro/graph_mem.git
cd graph_mem

# Copy example config and set your master key
cp .env.example .env
# Edit .env: set RAILS_MASTER_KEY (from config/master.key) and DB_PASSWORD

# Start the stack (MariaDB 11.8 + Rails in production mode)
docker compose up -d

# Seed canonical entity types
docker compose exec app bin/rails db:seed

# Backfill embeddings (requires Ollama running on host)
docker compose exec app bin/rails embeddings:backfill
```

The app is available at `http://localhost:3003`. Swagger API docs at `http://localhost:3003/api-docs`.

## Native Development Setup

For local development, run the app natively with MariaDB on localhost.

1. **Prerequisites:**
   * Ruby 3.4.1+ (via RVM or rbenv)
   * MariaDB 11.8+ (for vector search)
   * Ollama with an embedding model

2. **Install dependencies:**
   ```bash
   bundle install
   ```

3. **Database setup:**
   ```bash
   cp config/database.example.yml config/database.yml
   # Edit config/database.yml with your MariaDB credentials
   bin/rails db:prepare
   bin/rails db:seed
   ```

4. **Pull an embedding model:**
   ```bash
   ollama pull nomic-embed-text
   ```

5. **Backfill embeddings:**
   ```bash
   bin/rails embeddings:backfill
   ```

6. **Start the development server:**
   ```bash
   bin/dev
   ```

## Setting Up the MCP Client

### Cursor

Add to `~/.cursor/mcp.json`:

**Option A -- SSE transport (recommended with Docker):**
```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://localhost:3003/mcp/sse"
    }
  }
}
```

**Option B -- stdio transport (native development):**
```json
{
  "mcpServers": {
    "graph_mem": {
      "command": "/bin/bash",
      "args": ["/absolute/path/to/graph_mem/bin/mcp_graph_mem_runner.sh"],
      "env": { "RAILS_ENV": "development" }
    }
  }
}
```

**Option C -- stdio via Docker:**
```json
{
  "mcpServers": {
    "graph_mem": {
      "command": "/bin/bash",
      "args": ["/absolute/path/to/graph_mem/bin/docker-mcp"]
    }
  }
}
```

### Windsurf

Add to `~/.codeium/windsurf/mcp_config.json` (or `windsurf-next`):

```json
{
  "mcpServers": {
    "graph_mem": {
      "command": "/bin/bash",
      "args": ["/absolute/path/to/graph_mem/bin/mcp_graph_mem_runner.sh"],
      "env": { "RAILS_ENV": "development" }
    }
  }
}
```

For Docker-based setups, use `bin/docker-mcp` as the command instead, or configure SSE transport if your Windsurf version supports it.

### Claude Code

Add to `~/.claude/mcp_servers.json`:

```json
{
  "graph_mem": {
    "command": "/bin/bash",
    "args": ["/absolute/path/to/graph_mem/bin/mcp_graph_mem_runner.sh"],
    "env": { "RAILS_ENV": "development" }
  }
}
```

For Docker-based setups, use `bin/docker-mcp` as the command argument.

### LAN Access (Multiple Machines)

If running GraphMem on a workstation and accessing from other machines on the LAN:

1. Expose Ollama on the workstation: set `OLLAMA_HOST=0.0.0.0` in the Ollama config
2. On remote machines, set in `.env`:
   ```
   OLLAMA_URL=http://<workstation-ip>:11434
   ```
3. Point MCP clients to the workstation's SSE endpoint:
   ```json
   { "url": "http://<workstation-ip>:3003/mcp/sse" }
   ```

## Database Backup & Restore

Dumps are portable across database names (no `CREATE DATABASE` / `USE` statements):

```bash
# Dump current database to db/backup/graph_mem.sql.bz2
bin/rails db:dump

# Restore into the current environment's database
bin/rails db:restore
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API base URL |
| `EMBEDDING_MODEL` | `nomic-embed-text` | Ollama model name for embeddings |
| `EMBEDDING_PROVIDER` | `ollama` | `ollama` or `openai_compatible` |
| `EMBEDDING_DIMS` | `768` | Vector dimensions (must match model) |
| `DB_PASSWORD` | `my_password` | MariaDB root password |
| `DB_NAME` | `graph_mem` | Database name |
| `DB_PORT` | `3307` | Host port for MariaDB (Docker) |
| `APP_PORT` | `3003` | Host port for the Rails app (Docker) |
| `RAILS_MASTER_KEY` | -- | Rails credentials key (required for Docker) |
| `DATABASE_URL` | -- | Full database URL (overrides individual DB settings) |

## Documentation

* [MCP Tools Reference](docs/mcp_tools.md)
* [Architecture](docs/architecture.md)
* [Development Guide](docs/development.md)
* [Troubleshooting](docs/troubleshooting.md)
* [Memory Entity Resource](docs/memory_entity_resource.md)
* [Memory Observation Resource](docs/memory_observation_resource.md)
* [Memory Relation Resource](docs/memory_relation_resource.md)
* [Memory Graph Resource](docs/memory_graph_resource.md)

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change. Please make sure to update tests as appropriate.

## License

The project is available as open source under the terms of the [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).

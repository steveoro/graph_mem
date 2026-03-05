# GraphMem: Graph-Based Memory MCP Server

GraphMem is a Ruby on Rails application implementing a Model Context Protocol (MCP) server for graph-based memory management. It enables AI assistants and other clients to create, retrieve, search, and manage knowledge entities and their relationships through a standardized interface.

[![Version](https://img.shields.io/badge/version-1.3.0-blue.svg)](lib/graph_mem/version.rb)
[![Rails](https://img.shields.io/badge/rails-8.1.2-orange.svg)](Gemfile)
[![Ruby](https://img.shields.io/badge/ruby-3.4.1-red.svg)](Gemfile)

## Overview

GraphMem provides persistent, structured storage for knowledge entities, their relationships, and observations. It's designed as an MCP server that enables AI assistants to maintain memory across sessions, build domain-specific knowledge graphs, and effectively reference past interactions.

### Single-User Design

GraphMem is designed as a **single-user, local-network server**. There is no authentication layer -- the server trusts all incoming requests. The project context (set via `set_context`) is a single process-global value shared across all requests: one user sets a project scope, and all subsequent tool calls see it.

This is intentional: the server is meant to run on a local machine or LAN, accessed by one AI assistant at a time. If you need multi-user or multi-tenant support, an authentication and per-session context layer would need to be added.

**Key capabilities:**
- **Vector semantic search** via MariaDB 11.8 native VECTOR support + Ollama embeddings
- **Project context scoping** -- set once, persists across all MCP tool calls within the process
- **Entity type canonicalization** to prevent graph fragmentation
- **Auto-deduplication** on entity creation
- **Hybrid search** combining text tokenization with vector similarity (with context boosting)
- **Docker Compose** deployment with auto-start support
- **LAN-wide embedding** architecture using a centralized Ollama host

## Technology Stack

* **Ruby**: 3.4.1+
* **Rails**: 8.1.2+
* **MCP Implementation**: [fast-mcp](https://github.com/yjacquin/fast-mcp) gem
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

**Prerequisites:** Ollama must be running on the host with at least one embedding model pulled:

```bash
# Install Ollama (https://ollama.com) then pull the default embedding model
ollama pull nomic-embed-text
```

> The `app` container uses `network_mode: host`, so it shares the host's network
> stack. `localhost:11434` reaches Ollama with no bridge/firewall configuration needed.
> The app binds directly to host port 3003.

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

# Verify Ollama connectivity
docker compose exec app bin/rails embeddings:check

# Backfill embeddings
docker compose exec app bin/rails embeddings:backfill

# Update the container after a repository pull
docker compose down && docker compose up -d --build
```

The app is available at `http://localhost:3003`. Swagger API docs at `http://localhost:3003/api-docs`.

The app port (3003) is hardcoded on Dockerfile and docker-compose.yml because the service relies on host networking to access the embedding service by `ollama`. This allows a simpler container setup on different machines without resorting to iptables or firewall mangling.

This containerized app is a **single-user server** with no authentication layer -- it is
designed to run locally on a machine and/or be accessible only through a trusted LAN.
**Do not expose this service to the public internet.**


## LAN sharing

To allow a local Ubuntu server running `graph_mem` in a container with `ollama` running as a service for embedding processing, remember to allow incoming trafic if you're using `ufw` (assuming your local LAN is set on 192.168.0.0/24):

```bash
sudo ufw allow from 192.168.0.0/24 to any port 3003 proto tcp comment "GraphMem from LAN"

sudo ufw allow from 192.168.0.0/24 to any port 11434 proto tcp comment "Ollama from LAN"
```

This way, the graph_mem UI will be accessible on `http://<graph_mem_server_ip>:3003/` while the MCP server will be at `http://<graph_mem_server_ip>:3003/mcp/sse`.


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

**1. Expose Ollama on the workstation**

By default Ollama only listens on `127.0.0.1`. Create a systemd drop-in override
(survives Ollama package upgrades):

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
echo '[Service]
Environment="OLLAMA_HOST=0.0.0.0"' | sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify it's bound to all interfaces:

```bash
ss -tlnp | grep 11434
# Should show *:11434 instead of 127.0.0.1:11434
```

**2. Configure OLLAMA_URL**

On the workstation running GraphMem, `OLLAMA_URL=http://localhost:11434` (the default) works
because the `app` container uses host networking.

If Ollama runs on a *different* machine, set in `.env`:

```
OLLAMA_URL=http://<ollama-host-ip>:11434
```

**3. Connect MCP clients from other LAN machines**

Point them to the workstation's SSE endpoint:

```json
{ "url": "http://<workstation-ip>:3003/mcp/sse" }
```

## Embedding Management

### Testing Ollama Connectivity

Before backfilling or regenerating embeddings, verify that the app can reach your Ollama instance:

```bash
# Docker
docker compose exec app bin/rails embeddings:check

# Native
bin/rails embeddings:check
```

This sends a single test embedding through `EmbeddingService` using the configured `OLLAMA_URL`, `EMBEDDING_MODEL`, and `EMBEDDING_PROVIDER`. It reports the resolved config, response latency, and vector dimensions — the exact same code path used by `backfill` and `regenerate`.

For a lower-level check, `curl` is available inside the production container (host networking
means `localhost` reaches Ollama directly):

```bash
# Verify Ollama is reachable and list available models
docker compose exec app curl -sf http://localhost:11434/api/tags

# Test a raw embedding request
docker compose exec app curl -sf http://localhost:11434/api/embed \
  -d '{"model":"nomic-embed-text","input":"hello"}'
```

### Rake Tasks

| Task | Description |
|---|---|
| `embeddings:check` | Smoke-test Ollama connectivity and config |
| `embeddings:backfill` | Generate embeddings for records missing them |
| `embeddings:regenerate` | Recompute all embeddings in-place (e.g. after switching models) |
| `embeddings:add_indexes` | Add `VECTOR INDEX` (HNSW, cosine) after all rows are populated |
| `embeddings:drop_indexes` | Remove indexes and revert columns to nullable |

### Switching Embedding Models

To change the model (e.g. from `nomic-embed-text` to a different one):

1. Pull the new model on the Ollama host: `ollama pull <model-name>`
2. Update `EMBEDDING_MODEL` (and `EMBEDDING_DIMS` if different) in `.env`
3. Verify connectivity: `bin/rails embeddings:check`
4. Recompute all vectors: `bin/rails embeddings:regenerate`

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
| `RAILS_MASTER_KEY` | -- | Rails credentials key (required for Docker) |
| `DATABASE_URL` | -- | Full database URL (overrides individual DB settings) |
| `DB_BACKUP_HOST_PATH` | `./db/backup` | full path to DB backup(s) folder (default is invalid: docker-compose won't expand special characters) |

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

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change. Please make sure to update tests as appropriate. Pull requests without proper test cases won't be accepted.

## License

The project is available as open source under the terms of the [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).

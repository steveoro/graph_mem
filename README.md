# GraphMem: Graph-Based Memory MCP Server

GraphMem is a Ruby on Rails application implementing a Model Context Protocol (MCP) server for graph-based memory management. It enables AI assistants and other clients to create, retrieve, search, and manage knowledge entities and their relationships through a standardized interface.

[![Version](https://img.shields.io/badge/version-1.52.1-blue.svg)](lib/graph_mem/version.rb)
[![Rails](https://img.shields.io/badge/rails-8.1.4-orange.svg)](Gemfile)
[![Ruby](https://img.shields.io/badge/ruby-3.4.1-red.svg)](Gemfile)

## Overview

GraphMem provides persistent, structured storage for knowledge entities, their relationships, and observations. It's designed as an MCP server that enables AI assistants to maintain memory across sessions, build domain-specific knowledge graphs, and effectively reference past interactions.

### Single-User Design

GraphMem is designed as a **single-user, local-network server**: one graph for one implicit owner, shared by a handful of that owner's agents. There is no per-user authorization model, deliberately -- the shared graph is the point.

Access is controlled by network reach plus an optional shared bearer token. By default the MCP endpoint accepts unauthenticated requests **only** from loopback and private (RFC1918) ranges, and it can never be simultaneously unauthenticated and reachable from a public address. See [docs/mcp_access_control.md](docs/mcp_access_control.md) for configuration, and set `GRAPH_MEM_MCP_TOKEN` before exposing the server beyond a trusted LAN.

**Per-agent project context:** Several MCP clients can connect concurrently, **provided each sends a distinct `X-MCP-Client` value** -- context is stored per client id, so two agents sharing one value will overwrite each other's scope. GraphMem detects that case and adds a `warning` to `set_context` and `get_context` responses. Each agent identifies itself in its MCP configuration:

```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://localhost:3030/mcp",
      "headers": { "X-MCP-Client": "Agent-1" }
    }
  }
}
```

The example above assumes using the container setup, which is hardcoded to port 3030. (APP_PORT is currently hardcoded in Dockerfile and docker-compose.yml).

**Project-scoped names:** entity names are unique *per project* (`UNIQUE(project_scope, name)` — members carry `project_id` of their Project root; Project roots and unclaimed reference stubs live in the global namespace). Two projects can therefore hold same-named entities independently, and name resolution is context-first-then-global — a name declared in several projects raises an ambiguity error listing the candidates instead of guessing. Pre-1.50 graphs can be stamped by `bin/rails graph_mem:backfill_project_ids` (dry-run supported).

Use `/mcp` for the default **Streamable HTTP** profile. Use
`/mcp/readonly` for context and read tools only, or `/mcp/maintenance` for the
full catalog including maintenance operations. The legacy HTTP+SSE endpoint
(`/mcp/sse`) was removed in 1.55.0.
Client and protocol compatibility: [`docs/protocol_compat.md`](docs/protocol_compat.md).

Streamable HTTP and stdio speak MCP 2026-07-28 (`server/discover`) and 2024-11-05 … 2025-11-25
(the `initialize` handshake); a client picks the version it supports.

The server also publishes `orient`, `recall`, and `persist` MCP prompts
(`persist` is not available on the readonly profile — `/mcp/readonly`, or stdio
with `GRAPH_MEM_MCP_PROFILE=readonly` — which has no graph-write tools). Every
successful tool call includes the GraphMem version, a concise `next_move`, and
a context banner when the client has not selected a project.

The 12 default tools advertise `outputSchema` and return matching
`structuredContent` plus mirrored JSON text for backward-compatible clients.

Context set via `set_context` is stored per `client_id` in the database and survives server restarts. Agents without the header share the `"default"` client bucket (backward-compatible single-agent behavior), so give every agent its own value once you run more than one.

The header is a cooperative scope key, **not** a credential: an agent can claim any client id, and the shared token grants identical full read/write access to everyone holding it. Multi-tenant isolation remains out of scope -- if two people need separate memories, run two instances against two databases.

**Key capabilities:**
- **Vector semantic search** via MariaDB 11.8 native VECTOR support + Ollama embeddings
- **Project context scoping** -- per-agent via `X-MCP-Client`, persisted across restarts
- **Entity type canonicalization** to prevent graph fragmentation
- **Auto-deduplication** on entity creation
- **Hybrid search** combining text tokenization with vector similarity (with context boosting)
- **Docker Compose** deployment with auto-start support
- **LAN-wide embedding** architecture using a centralized Ollama host

## Technology Stack

* **Ruby**: 3.4.1+
* **Rails**: 8.1.4+
* **MCP Implementation**: the official MCP Ruby SDK ([`mcp`](https://github.com/modelcontextprotocol/ruby-sdk) gem, pinned to 1.8.2) over Streamable HTTP and stdio (MCP 2024-11-05 … 2026-07-28). Moving another Rails app off fast-mcp: [`docs/guides/migrating-fast-mcp-to-mcp-gem.md`](docs/guides/migrating-fast-mcp-to-mcp-gem.md)
* **Database**: MariaDB 11.8+ (VECTOR support required)
* **Embeddings**: Ollama with nomic-embed-text (768 dimensions)

## Features

### Rules & Skills

GraphMem ships agent-facing rules and a vendor-neutral skill:

**Using GraphMem as an MCP toolset** (your agent talks to a running server):

- `docs/rules/graph_mem_mcp_rules.md` — always-on rules to copy into your
  agent's rule set (per-agent install targets: `docs/rules/README.md`)
- `docs/rules/general_coding_rules.md` — optional, project-agnostic coding rules
- `skills/graph-mem-mcp-toolset/SKILL.md` — vendor-neutral operational skill
  (works in Cursor, Claude Code, Devin, ...; this repo links it from
  `.agents/skills/` and `.claude/skills/`)

**Developing GraphMem itself** (editing this repo): see `AGENTS.md` (the one
rule file for every agent; `CLAUDE.md` imports it) and `docs/development.md`.

### MCP Tools

GraphMem exposes the following MCP tools:

#### Entity Management
* `get_entities` -- Retrieve one or more entities with observations and all/internal relation projections
* `search` -- Ranked summary search, projected subgraph search, or paginated catalog listing

#### Graph Mutation
* `graph_write` -- Atomically create entities, observations, and relations
* `graph_edit` -- Atomically update entity metadata or observation content/lifecycle
* `graph_delete` -- Atomically delete, obsolete, or merge graph records

Observations use an `active`, `obsolete`, or `superseded` lifecycle. Normal entity reads, graph traversal, relationship discovery, and search expose active observations only. Use `get_entities(include_obsolete: true)` or `include_obsolete=true` on observation REST/resource listings to inspect retained history. Explicit duplicate-cleanup maintenance operations still hard-delete redundant active rows.

#### Relationship Management
* `traverse_graph` -- Bounded multi-hop traversal or direct endpoint/type relation query
* `find_shortest_path` -- Shortest path (by hop count) between two entities

The older per-operation tool names (`create_entity`, `search_entities`, …) were removed in 1.55.0;
use the tools above (`graph_write`, `graph_edit` and `graph_delete` take them as operation types).

#### Context and Workflow
* `set_context` -- Scope subsequent operations to a project (per `X-MCP-Client`)
* `get_context` -- Check the active project context
* `suggest_merges` -- Find potential duplicate entities via vector similarity
* `dream_state_status` -- Report background graph compaction state (running/paused/cursor)
* `get_maintenance_reports` -- Read maintenance/compaction reports, including the `compaction_review` queue

#### Utility
* `get_current_time` -- Server time in ISO 8601

### Dream-State Compaction

A background **dream-state** job (`DreamStateCompactionJob`, scheduled via Solid Queue `recurring.yml`) periodically compacts the knowledge graph:

- **Orphan phase** -- attaches high-confidence orphan nodes to matching `Project` roots
- **Tree-walk phase** -- deduplicates identical observations and auto-merges very similar entities (cosine distance &lt; 0.10)
- **Review queue** -- lower-confidence merges and orphan matches are written to `maintenance_reports` (`compaction_review`), readable via `get_maintenance_reports`

The job is **cooperatively pausable**: mutating MCP tools request a pause when compaction is running, so live tool traffic takes priority. Use `dream_state_status` to inspect cursor position and stats, and `get_maintenance_reports` to review and action the queued suggestions. Paused runs resume on the next scheduled trigger.

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
> The app binds directly to host port 3030.

```bash
# Clone and enter the project
git clone https://github.com/steveoro/graph_mem.git
cd graph_mem

# Copy example config and set your master key
cp .env.example .env
# Edit .env: set RAILS_MASTER_KEY (from config/master.key) and DB_PASSWORD

# Start the stack (MariaDB 11.8 + Rails in production mode), with the host's LAN
# address and names as the MCP allowlist defaults (bin/up --print shows them)
bin/up

# Seed canonical entity types
docker compose exec app bin/rails db:seed

# Verify Ollama connectivity
docker compose exec app bin/rails embeddings:check

# Backfill embeddings
docker compose exec app bin/rails embeddings:backfill

# Update the container after a repository pull
docker compose down && bin/up --build
```

`docker compose up -d` still works and uses the built-in MCP allowlist defaults (loopback and private
ranges, loopback host names); see [MCP access control](docs/mcp_access_control.md#starting-with-binup).

The app is available at `http://localhost:3030`. Swagger API docs at `http://localhost:3030/api-docs`.

The app port (3030) is hardcoded on Dockerfile and docker-compose.yml because the service relies on host networking to access the embedding service by `ollama`. This allows a simpler container setup on different machines without resorting to iptables or firewall mangling.

**Project scans in Docker:** compose mounts your home folder **read-only at the same path** inside
the container (`${HOME}:${HOME}:ro`, override with `GRAPH_MEM_SCAN_HOME`), so a host path like
`/home/you/Projects/app` can be scanned as typed. Only the folders in the Settings › Project scans
subfolder filter (default `Projects`) are scannable, and hidden folders and secret files never are.
See [docs/container_scan_mounts.md](docs/container_scan_mounts.md) (UID, rootless Podman, SELinux).

This containerized app is a **single-user server** with no authentication layer -- it is
designed to run locally on a machine and/or be accessible only through a trusted LAN.
**Do not expose this service to the public internet.**


## LAN sharing

To allow a local Ubuntu server running `graph_mem` in a container with `ollama` running as a service for embedding processing, remember to allow incoming trafic if you're using `ufw` (assuming your local LAN is set on 192.168.0.0/24):

```bash
sudo ufw allow from 192.168.0.0/24 to any port 3030 proto tcp comment "GraphMem from LAN"

sudo ufw allow from 192.168.0.0/24 to any port 11434 proto tcp comment "Ollama from LAN"
```

This way, the graph_mem UI will be accessible on `http://<graph_mem_server_ip>:3030/` while the MCP server will be at `http://<graph_mem_server_ip>:3030/mcp` (Streamable HTTP).

The MCP endpoint checks the `Host` header (DNS-rebinding protection, always on): only `localhost`,
`127.0.0.1` and `::1` are accepted by default, so add the address or name the other machines use
to `.env`, or they get `403`:

```bash
GRAPH_MEM_MCP_ALLOWED_HOSTS=<graph_mem_server_ip>,graphmem.lan
```

### Access control on a shared LAN

The MCP endpoint accepts unauthenticated requests from private ranges by default, so every device
on the LAN has full read/write access to the graph. Once the network is not fully trusted, set a
shared token on the server:

```bash
# in .env on the GraphMem host
GRAPH_MEM_MCP_TOKEN=$(openssl rand -hex 32)
# A custom list replaces the defaults: keep loopback and the Docker bridge range
# (or leave it unset and let bin/up add your LAN subnet)
GRAPH_MEM_MCP_ALLOWED_IPS=127.0.0.0/8,::1,172.16.0.0/12,192.168.0.0/24
```

and add it to every client config alongside the `X-MCP-Client` header:

```json
"headers": {
  "Authorization": "Bearer <GRAPH_MEM_MCP_TOKEN>",
  "X-MCP-Client": "cursor-1"
}
```

Clients may be updated before the server: while no token is configured the header is ignored, so
you can roll it out without downtime. Full reference in
[docs/mcp_access_control.md](docs/mcp_access_control.md).


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

Edit your Cursor's `mcp.json`:

**Option A -- Streamable HTTP transport (recommended for modern clients):**
```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://localhost:3030/mcp",
      "headers": { "X-MCP-Client": "Agent-1" }
    }
  }
}
```

**Option B -- stdio transport (native development / real-time changes applied):**
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

Edit your Windsurf's `mcp_config.json` using the same approach as Cursor's.


### Antigravity / Devin (Streamable HTTP)

GraphMem supports the Streamable HTTP transport (MCP 2024-11-05 … 2026-07-28). Point these clients at the base MCP URL:

```json
{
  "mcpServers": {
    "graph_mem": {
      "url": "http://localhost:3030/mcp",
      "headers": { "X-MCP-Client": "Agent-1" }
    }
  }
}
```

Assuming `graph_mem-app-1` is the running container name, edit `mcp_servers.json`:

```json
{
    "mcpServers": {
        "graph_mem": {
            "command": "/usr/bin/docker",
            "args": [
                "exec",
                "-i",
                "graph_mem-app-1",
                "bash",
                "-c",
                "'bin/bundle exec ruby bin/mcp_stdio_runner.rb'"
                // For development, change env below and replace the command with bash, first arg "-c" and second arg:
                // "cd /home/steve/Projects/graph_mem && exec /usr/share/rvm/wrappers/ruby-3.4.1@graph_mem/bundle exec ruby bin/mcp_stdio_runner.rb"
            ],
            "env": {
                "RAILS_ENV": "production"
            }
        }
    }
}
```


### Claude Code

Claude Code does not read the Cursor-style `mcp.json` / `mcp_servers.json` files. Configure it through
`.mcp.json` (project root, shareable), `~/.claude.json` (user scope) or the `claude mcp add` CLI.

**Streamable HTTP (recommended).** Unlike Cursor, Claude Code requires an explicit `"type": "http"`:
an entry with only `url` + `headers` is rejected as invalid. Custom headers such as `X-MCP-Client` are
passed through untouched.

```json
{
  "mcpServers": {
    "graph_mem": {
      "type": "http",
      "url": "http://localhost:3030/mcp",
      "headers": {
        "Authorization": "Bearer <GRAPH_MEM_MCP_TOKEN>",
        "X-MCP-Client": "${MCP_CLIENT_ID:-claude-code-1}"
      }
    }
  }
}
```

Or, equivalently, via the CLI (`--scope` is one of `local`, `project` or `user`):

```bash
claude mcp add --transport http graph_mem http://localhost:3030/mcp \
  --header "X-MCP-Client: claude-code" --scope user
```

**Unique client id per Claude instance.** `.mcp.json` supports environment variable expansion
(`${VAR}` and `${VAR:-default}`), so a single shared file can still give every instance its own id:

```json
"headers": { "X-MCP-Client": "${MCP_CLIENT_ID:-claude-code-1}" }
```

```bash
MCP_CLIENT_ID=claude-my_project claude
```

Instances started without the variable fall back to `claude-code-1`. Other agents keep using their own
configuration and ids; as noted above, each concurrent agent must send a distinct `X-MCP-Client` value.
When a token is configured, add `"Authorization": "Bearer <GRAPH_MEM_MCP_TOKEN>"` to the same `headers` object.

**stdio.** The stdio options (C and D above) work as well, using the same `command` / `args` / `env`
fields (add `"type": "stdio"` if you prefer to be explicit).


### LAN Access (Multiple Machines)

See [Architecture](docs/architecture.md) for details.

Mind that the current version of GraphMem is specifically designed for single-user usage only, meaning 1 AI user per installation: currently there's no session storage per conversation, so multiple AI agents connecting and using the same running GraphMem instance may overwrite each other's work (one could reset the current context of another preventing the "context valve" to work as expected, thus leading to context bloat).

But nothing prevents you to share the same generated memory graph among different workstations, provided GraphMem will be used by a single AI user at a time.
Or, more realistically, deploy GraphMem on a performant server and access it your usual workstation.

So, when running GraphMem on a local server and accessing it from other machines on the LAN:

**1. Expose Ollama on the runner host**

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

On the host running GraphMem, `OLLAMA_URL=http://localhost:11434` (the default) works
because the `app` container uses host networking.

If Ollama runs on an another *different* machine, set in `.env`:

```
OLLAMA_URL=http://<ollama-host-ip>:11434
```

**3. Connect MCP clients from other LAN machines**

Use the Streamable HTTP endpoint for modern clients:

```json
{ "url": "http://<workstation-ip>:3030/mcp" }
```

and list `<workstation-ip>` (or the name the clients use) in `GRAPH_MEM_MCP_ALLOWED_HOSTS` on the
GraphMem host (see [LAN sharing](#lan-sharing)).


## Embedding Management

### Operator dashboard

Sign in at `/operator/login`, then open **Embeddings** from the home dashboard or go to `/operator/embeddings`. The page shows coverage, index status, resolved configuration (with source badges: AppSettings / ENV / Default), connection test, backfill/regenerate jobs, and add/drop ANN index actions.

Embedding service settings live under **System Settings → Embeddings** (`/operator/settings?tab=embeddings`). Configuration resolves in this order:

| Priority | Source |
|---|---|
| 1 | AppSettings (operator UI) — blank string or `0` dims defers to ENV |
| 2 | Environment variables (`OLLAMA_URL`, `EMBEDDING_MODEL`, `EMBEDDING_PROVIDER`, `EMBEDDING_DIMS`) |
| 3 | Built-in defaults (`http://localhost:11434`, `nomic-embed-text`, `ollama`, 768) |

ENV variables remain the right choice for Docker and deployment manifests; the UI overrides them when values are set. Enable **scheduled backfill** in settings to run `EmbeddingScheduledBackfillJob` daily (see `config/recurring.yml`).

See [docs/operator/embeddings.md](docs/operator/embeddings.md) for the recommended operator workflow.

### Testing Ollama Connectivity

Before backfilling or regenerating embeddings, verify that the app can reach your Ollama instance:

```bash
# Docker
docker compose exec app bin/rails embeddings:check

# Native
bin/rails embeddings:check
```

This sends a single test embedding through `EmbeddingService` using the resolved configuration (AppSettings → ENV → defaults). It reports the resolved config, response latency, and vector dimensions — the exact same code path used by `backfill` and `regenerate`.

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
| `embeddings:add_indexes` | Add `VECTOR INDEX` (HNSW, cosine) after all rows are populated — idempotent; also repairs missing insert triggers |
| `embeddings:drop_indexes` | Remove indexes and revert columns to nullable |

### Switching Embedding Models

To change the model (e.g. from `nomic-embed-text` to a different one):

1. Pull the new model on the Ollama host: `ollama pull <model-name>`
2. Update the model (and dimensions if different) in **System Settings → Embeddings** or via `EMBEDDING_MODEL` / `EMBEDDING_DIMS` in `.env`
3. Verify connectivity: `bin/rails embeddings:check` or the operator **Test connection** button
4. Recompute all vectors: `bin/rails embeddings:regenerate` or the operator **Regenerate all** action



## Database Backup & Restore

Backups are managed through **System Settings** (`/operator/settings`, session login) and rake tasks. Dumps are timestamped, environment-scoped, and retained according to `backup_keep_max`:

```bash
# Dump current database to <backup_folder>/<YYYYMMDDHHMM>_<env>.sql.bz2
bin/rails db:dump

# List backups for the current environment
bin/rails db:list_backups

# Restore from newest backup, or a specific file
bin/rails db:restore
FILE=202601011200_production.sql.bz2 bin/rails db:restore
```

Scheduled backups run via Solid Queue (`DatabaseBackupJob`) when **Enable scheduled backups** is on in System Settings. Production schedule: 1pm and 5pm GMT (`config/recurring.yml`). Use the **Jobs** dashboard at `/operator/jobs` (same operator session) to inspect queue status.

Sign in at `/operator/login`. Default operator credentials: `operator` / `changeme`. In production the login returns 503 until the password is changed from `changeme` (the default username is fine). Override with `OPERATOR_USERNAME` / `OPERATOR_PASSWORD` or Rails credentials under `operator:`.

**Read-only guest.** An optional second account can browse Search and Explore without changing anything. It is disabled until a guest password is set in `GRAPH_MEM_GUEST_PASSWORD` or Rails credentials `guest.password`; the username defaults to `guest` (`GRAPH_MEM_GUEST_USERNAME` or `guest.username`). The guest's username and password must both differ from the operator's, or the guest stays disabled. **Settings › Feature Flags › Guest access** turns it off at any time (signed-in guests are signed out on their next click). A guest can read all graph content (there is no per-project scoping), gets `403` on every other page and every other `/api/v1` endpoint (only the graph, entity, observation and relation reads, search subgraph and traversal are open), and never gets MCP access: `/mcp*` ignores browser sessions. Guests can run up to 60 searches a minute per IP and 300 a minute across all guests (HTML and API combined; `429` after that). Guest sessions expire after 2 hours idle or 24 hours.


## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API base URL (overridden by AppSettings `embedding_url` when set) |
| `EMBEDDING_MODEL` | `nomic-embed-text` | Ollama model name for embeddings |
| `EMBEDDING_PROVIDER` | `ollama` | `ollama` or `openai_compatible` |
| `EMBEDDING_DIMS` | `768` | Vector dimensions (must match model) |
| `DB_PASSWORD` | `my_password` | MariaDB root password |
| `DB_NAME` | `graph_mem` | Database name |
| `DB_PORT` | `3307` | Host port for MariaDB (Docker) |
| `RAILS_MASTER_KEY` | -- | Rails credentials key (required for Docker) |
| `DATABASE_URL` | -- | Full database URL (overrides individual DB settings) |
| `DB_BACKUP_HOST_PATH` | `./db/backup` | full path to DB backup(s) folder (default is invalid: docker-compose won't expand special characters) |
| `OPERATOR_USERNAME` | `operator` | Operator login username for the web dashboard |
| `OPERATOR_PASSWORD` | `changeme` | Operator login password (production refuses to serve the login form while it is still `changeme`) |
| `GRAPH_MEM_MCP_TOKEN` | -- | Shared bearer token for `/mcp` and `/api/v1`; without it `/api/v1` accepts operator sessions only |
| `GRAPH_MEM_MCP_ALLOWED_IPS` | loopback + private ranges | IP allowlist applied to bearer-token requests on `/mcp` and `/api/v1` |
| `GRAPH_MEM_GUEST_USERNAME` | `guest` | Username of the read-only guest account |
| `GRAPH_MEM_GUEST_PASSWORD` | -- | Guest password; blank = guest login disabled. Must differ from the operator's |


## Documentation

* [Web UI guide](docs/guides/ui-guide.md) (operator and read-only guest, with screenshots)
* [Operator embeddings guide](docs/operator/embeddings.md)
* [MCP Tools Reference](docs/mcp_tools.md)
* [App Settings Reference](docs/app_settings_reference.md)
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

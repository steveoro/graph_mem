# GraphMem: Graph-Based Memory MCP Server

GraphMem is a Ruby on Rails application implementing a Model Context Protocol (MCP) server for graph-based memory management. It enables AI assistants and other clients to create, retrieve, search, and manage knowledge entities and their relationships through a standardized interface.

[![Version](https://img.shields.io/badge/version-0.7.0-blue.svg)](lib/graph_mem/version.rb)
[![Rails](https://img.shields.io/badge/rails-8.0.2-orange.svg)](Gemfile)
[![Ruby](https://img.shields.io/badge/ruby-3.4.1-red.svg)](Gemfile)

## Overview

GraphMem provides persistent, structured storage for knowledge entities, their relationships, and observations. It's designed as a MCP server that enables AI assistants to maintain memory across sessions, build domain-specific knowledge graphs, and effectively reference past interactions.

## Technology Stack

* **Ruby**: 3.4.1+
* **Rails**: 8.0.2+
* **MCP Implementation**: [fast-mcp](https://github.com/yjacquin/fast-mcp) gem, vers. 1.5+
* **Database**: MariaDB

## Features

### MCP Tools

GraphMem exposes the following MCP tools through an endpoint at `/mcp/messages`:

#### Entity Management
* `get_version`: Get server version information
* `create_entity`: Create new entities with name and type
* `get_entity`: Retrieve entities by ID with related data
* `search_entities`: Search for entities based on name
* `list_entities`: List entities with pagination and filtering
* `delete_entity`: Remove entities and all associated data

#### Observation Management
* `create_observation`: Add observations to existing entities
* `delete_observation`: Remove observations from entities

#### Relationship Management
* `create_relation`: Create typed relationships between entities
* `delete_relation`: Remove relationships
* `find_relations`: Find relationships connected to entities
* `get_subgraph_by_ids`: Get a connected subgraph of specified entities
* `get_current_time`: Retrieve server time in ISO 8601 format

### MCP Resources

GraphMem also provides higher-level structured resource access:

* `memory_entities`: Query entities with filtering, sorting, and relation inclusion
* `memory_observations`: Access observations with advanced filtering
* `memory_relations`: Query entity relationships with bidirectional entity inclusion
* `memory_graph`: Get graph traversals starting from any entity with configurable depth

### REST API

Includes a traditional REST API at `/api/v1` for direct interaction with the database, suitable for integration with non-MCP clients.

## Current Status

* **API server**: Fully operational and tested
* **stdio MCP transport**: Compatible with both MCP Inspector and Windsurf
* **SSE transport**: Tested with MCP Inspector
* **WebSocket transport**: Development in progress

## Documentation

Comprehensive documentation is available in the `/docs` directory:

* [Memory Entity Resource](docs/memory_entity_resource.md)
* [Memory Observation Resource](docs/memory_observation_resource.md) 
* [Memory Relation Resource](docs/memory_relation_resource.md)
* [Memory Graph Resource](docs/memory_graph_resource.md)
* [REST API Reference](docs/api/rest_api_reference.md) or run the Rails server and navigate to `http://localhost:3000/api-docs/index.html` (uses Swagger)


## Setup and Installation

1.  **Prerequisites:**
    *   Ruby (version 3.4.1 recommended)
    *   Bundler (`gem install bundler`)
2.  **Clone the repository:**
    ```bash
    git clone <repository_url>
    cd graph_mem
    ```
3.  **Install dependencies:**
    ```bash
    bundle install
    ```
4.  **Database Setup:**
    (If you are using the default MariaDB, this step might create the database file. For other databases, ensure your `config/database.yml` is configured correctly.)
    ```bash
    rails db:prepare
    ```
    (or `rails db:setup` which also runs seeds if you have any)


## Setting up the MCP client

Edit your MCP (JSON) configuration file, usually located under the folder of your MCP client setup (e.g., for Windsurf `~/.codeium/windsurf/mcp_config.json`,  for Windsurf-Next `~/.codeium/windsurf-next/mcp_config.json`, for Cursor `~/.cursor/mcp.json`), and add the `graph_mem` server block:

```json
{
  "mcpServers": {

    [...]

    "graph_mem": {
      "command": "/bin/bash",
      "args": [
        "<path_to_graph_mem_folder>/bin/mcp_graph_mem_runner.sh"
      ],
      "env": {
        "RAILS_ENV": "development"
      }
    }
  }
}
```

Always use the absolute path to the `mcp_graph_mem_runner.sh` script.

Subsequently, edit your global rules file and add the contents of the `docs/knowledge_graph_management_rules.md` file to it.


## Running the API Server

You can run the Rails server, which also provides an API endpoint to check the database contents, using the usual:

```bash
bin/rails server
```
This will typically start the server on `http://localhost:3000`.

Alternatively, a custom script is provided to run the server on port 3003:
```bash
bin/mcp
```

The SSE MCP endpoints will be available at `http://localhost:3003/mcp/sse` and `http://localhost:3003/mcp/messages`.

The STDIO MCP server can be run using the `bin/mcp_graph_mem_runner.sh` script. Although designed to work with Windsurf, it should work also with other MCP clients (currently not tested).


## Interacting with the MCP Server

All MCP requests should be `POST` requests to the `/mcp/messages` endpoint with a JSON-RPC 2.0 payload.

**Example: Get Server Version**
```bash
curl -X POST -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"VersionTool","params":{},"id":1}' \
     http://localhost:3003/mcp/messages
```

**Example: Search Entities**
```bash
curl -X POST -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"SearchEntitiesTool","params":{"query":"MyEntityName"},"id":2}' \
     http://localhost:3003/mcp/messages
```

**Example: Get Entity by ID**
```bash
curl -X POST -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"GetEntityTool","params":{"entity_id":"entity-uuid-123"},"id":3}' \
     http://localhost:3003/mcp/messages
```


## Development

*   **Custom MCP Tools:** Located in `app/tools/`. New tools should inherit from `ApplicationTool` and be placed in this directory.
*   **Custom MCP Resources:** Located in `app/resources/`. New resources should inherit from `ApplicationResource` and be placed in this directory.
*   **Fast-MCP Configuration:** The main configuration for the `fast-mcp` gem, including tool registration and CORS settings, is in `config/initializers/fast_mcp.rb`.
*   **Logging:** MCP-related logs can be found in the standard Rails log output. Debug logging for `fast-mcp` is enabled in `config/initializers/fast_mcp.rb`.


## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.


## License
The project is available as open source under the terms of the [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).

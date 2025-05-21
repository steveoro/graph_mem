# GraphMem: MCP Server

GraphMem is a Ruby on Rails application that implements a Model Context Protocol (MCP) server. It's designed to provide an interface for interacting with a graph-based memory system, allowing clients to create, retrieve, search, and manage entities and their relationships.


## Technology Stack

*   Ruby: 3.4.1+
*   Rails: 8.0.2+
*   MCP Implementation: [fast-mcp](https://github.com/yjacquin/fast-mcp) gem
*   Database: MariaDB
*   [fast-mcp](https://github.com/yjacquin/fast-mcp) gem with local patches for stdio + SSE
*   [actionmcp](https://github.com/seuros/action_mcp) gem for pub-sub on a dedicated branch


## Features

*   Provides an MCP endpoint at `/mcp/messages`.
*   Supports the following MCP tools for graph memory operations:
    *   `VersionTool`: Get server version information.
    *   `CreateEntityTool`: Create new entities.
    *   `GetEntityTool`: Retrieve entities by ID.
    *   `SearchEntitiesTool`: Search for entities based on criteria.
    *   `DeleteEntityTool`: Delete entities.
    *   `CreateObservationTool`: Add observations to entities.
    *   `DeleteObservationTool`: Remove observations from entities.
    *   `CreateRelationTool`: Create relationships between entities.
    *   `DeleteRelationTool`: Remove relationships between entities.
    *   `FindRelationsTool`: Find relationships connected to an entity.
*   Includes an additional API server at `/api/v1` for direct interaction with the database, or for any other custom logic that doesn't rely on MCP.


## Current state
- API server: working and tested
- stdio runner: working and tested both with the MCP inspector and Windsurf
- sse runner: tested but working only with the MCP inspector
- pub-sub (on separate branch): tested but working only with the MCP inspector


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

Edit your `~/.mcp.json` file to add the server block:

```json
{
  "mcpServers": {

    [...]

    "graph_mem": {
      "command": "/bin/bash",
      "args": [
        "<path_to_graph_mem>/bin/windsurf_mcp_graph_mem_runner.sh"
      ],
      "env": {
        "RAILS_ENV": "development"
      }
    }
  }
}
```

Always use the absolute path to the `windsurf_mcp_graph_mem_runner.sh` script.

Subsequently, edit your global rules file and add the contents of the `docs/knowledge_graph_management_rules.md` file to it.


## Running the API Server

You can run the Rails server, which includes the MCP endpoint, using:

```bash
bin/rails server
```
This will typically start the server on `http://localhost:3000`.

Alternatively, a custom script is provided to run the server on port 3003:
```bash
bin/mcp
```
The MCP endpoint will be available at `http://localhost:3003/mcp/messages`.

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
     -d '{"jsonrpc":"2.0","method":"GetEntityTool","params":{"id":"entity-uuid-123"},"id":3}' \
     http://localhost:3003/mcp/messages
```


## Development

*   **Custom MCP Tools:** Located in `app/tools/`. New tools should inherit from `ApplicationTool` and be placed in this directory.
*   **Fast-MCP Configuration:** The main configuration for the `fast-mcp` gem, including tool registration and CORS settings, is in `config/initializers/fast_mcp.rb`.
*   **Logging:** MCP-related logs can be found in the standard Rails log output. Debug logging for `fast-mcp` is enabled in `config/initializers/fast_mcp.rb`.


## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.


## License
The gem is available as open source under the terms of the [LGPL-3.0 License](https://opensource.org/licenses/LGPL-3.0).

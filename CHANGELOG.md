# Changelog

All notable changes to GraphMem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-01-27

### Changes
- Added data-exchange feature from graph_mem server landing page
- Bundle update

## [0.8.6] - 2025-12-07

### Changes
- Generalized RVM sourcing in runner script to support multiple installation paths
- Bundle update

## [0.8.5] - 2025-08-02

### Changes
- Set default value for `memory_observations_count` to 0
- Added tests for `delete_duplicates` API endpoint
- Added "delete duplicates" action to graph visualization in observation details show pop-up menu

## [0.8.4] - 2025-08-01

### Changes
- Substitute deprecated :unprocessable_content status code with :unprocessable_content; bundle updated
- Fixed merge operation on node-to-node action in graph visualization
- Removed legacy `observations_count` (proper counter cache column: `memory_observations_count`)

## [0.8.3] - 2025-07-18

### Added
- Improved "knowledge graph visualization": contextual menu for nodes and edges, with options to navigate to related entities and observations; double-click to close up to a node subgraph; editable entity data

## [0.8.2] - 2025-07-02

### Added
- Tokenized search for entities, by name, aliases and entity_type, with overall relevance score (float)

## [0.8.1] - 2025-06-16

### Added
- Preliminary graph visualization with Cytoscape.js + Stimulus.js using the localhost Rails server


## [0.8.0] - 2025-06-13

### Added
- `update_entity_tool` to update an existing entity
- support for entity names aliases as pipe-separated strings


## [0.7.1] - 2025-06-10

### Added
- `db:append_json` task to merge matching objects in legacy memory.json data files into existing database rows
- `db:merge_entity` task to merge a single entity into an existing entity
- `db:project_report` task to generate a consolidated Markdown report with Mermaid diagrams for all projects in the database


## [0.7.0] - 2025-06-09

### Added
- MCP Resources for higher-level structured access:
  - `memory_entities` resource with advanced filtering, sorting, and relation inclusion
  - `memory_observations` resource with text search and entity inclusion
  - `memory_relations` resource with bidirectional entity inclusion
  - `memory_graph` resource for graph traversal starting from any entity
- Comprehensive documentation in `/docs` directory
- Support for pagination in all list operations
- Integration with Windsurf via STDIO transport
- Improved error handling with custom error classes

### Changed
- Refactored MCP tools to use unified application tool base class
- Improved response formatting for better compatibility with Cascade MCP client
- Enhanced JSON serialization for better performance
- Updated README with more detailed installation and usage instructions

### Fixed
- Monkey-patched `FastMcp::Server#handle_tools_call` to fix tool instantiation issue
- Fixed response formatting for Cascade compatibility
- Corrected CORS configuration for cross-origin requests
- Resolved N+1 query issues in relationship traversal

## [0.6.0] - 2025-05-20

### Added
- SSE transport for real-time updates
- Support for complex graph traversal operations
- `get_subgraph_by_ids` tool for retrieving connected subgraphs
- Improved entity search with partial name matching

### Changed
- Updated to fast-mcp 1.4.0
- Enhanced entity serialization with observation counts
- Better error handling and validation for tool parameters

## [0.5.0] - 2025-04-12

### Added
- Complete RESTful API at `/api/v1` for non-MCP clients
- Swagger API documentation
- Authentication framework (disabled by default)
- Database indices for improved performance

### Changed
- Moved to Ruby 3.4.1
- Updated Rails to 8.0.2
- Refactored database schema for better performance
- Enhanced model validations

## [0.4.0] - 2025-03-05

### Added
- Relation management tools:
  - `create_relation`
  - `delete_relation`
  - `find_relations`
- Support for typed relationships between entities
- Database migrations for relation model

## [0.3.0] - 2025-02-18

### Added
- Observation management tools:
  - `create_observation`
  - `delete_observation`
- Support for attaching multiple observations to entities
- Observation count tracking

### Fixed
- Entity deletion cascade to associated observations
- Proper JSON-RPC error codes for common error scenarios

## [0.2.0] - 2025-01-27

### Added
- Entity management tools:
  - `create_entity`
  - `get_entity`
  - `search_entities`
  - `list_entities`
  - `delete_entity`
- Basic entity schema with name and type
- Integration with MariaDB

### Changed
- Updated project structure to Rails 8.0 conventions
- Enhanced tool parameter validation

## [0.1.0] - 2025-01-06

### Added
- Initial project setup
- Basic MCP server implementation
- `version` tool
- Configuration for fast-mcp gem
- Project documentation and license

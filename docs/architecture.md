# GraphMem Architecture

This document provides an overview of GraphMem's architecture, explaining how the various components work together to provide a complete graph-based memory system accessed through the Model Context Protocol (MCP).

## System Architecture Overview

![GraphMem System Architecture](https://via.placeholder.com/800x500?text=GraphMem+Architecture+Diagram)

GraphMem follows a layered architecture that separates concerns between:

1. **MCP Interface Layer** - Handles communication with MCP clients
2. **Application Logic Layer** - Implements business logic and memory operations
3. **Data Access Layer** - Manages database interactions
4. **Storage Layer** - Persistence of graph memory data

## Component Breakdown

### 1. MCP Interface Layer

The MCP interface layer consists of:

- **FastMcp::Server** - Base server implementation from the `fast-mcp` gem
- **Custom Transports** - Includes STDIO and SSE transport implementations
- **Tool Registration** - Configuration in `config/initializers/fast_mcp.rb`

The interface layer receives JSON-RPC 2.0 requests from clients, routes them to the appropriate tools, and formats responses according to the MCP specification.

#### Key Implementation Details

- Transport implementations handle the communication protocol specifics (STDIO, HTTP/SSE)
- The FastMcp::Server instance handles JSON-RPC request/response lifecycle
- CORS configuration enables cross-origin requests for web clients

### 2. Application Logic Layer

The application logic layer is built around:

- **Custom MCP Tools** - Located in `app/tools/`
- **MCP Resources** - Higher-level access patterns for common operations
- **Service Classes** - Encapsulate complex business logic
- **Error Handling** - Custom error classes and standardized error responses

All custom tools inherit from `ApplicationTool` which in turn inherits from `FastMcp::Tool`. This hierarchy ensures consistent behavior and proper integration with the FastMcp server.

#### Tool Structure

Tools follow a consistent pattern:
1. Parameter validation using JSON Schema
2. Business logic implementation
3. Response formatting for MCP compatibility
4. Error handling with appropriate JSON-RPC error codes

### 3. Data Access Layer

The data access layer consists of:

- **ActiveRecord Models** - Object-relational mapping for database entities
- **Query Objects** - Complex query encapsulation
- **Scopes** - Reusable query components
- **Caching** - Performance optimization for frequently accessed data

#### Core Models

- **MemoryEntity** - Represents a node in the knowledge graph
- **MemoryObservation** - Contains text content associated with entities
- **MemoryRelation** - Represents edges between entities

### 4. Storage Layer

The storage layer is built on MariaDB and includes:

- **Database Schema** - Optimized for graph operations
- **Indices** - Strategic indexing for query performance
- **Constraints** - Data integrity enforcement
- **Migrations** - Version-controlled schema evolution

## Data Flow

A typical request through the system follows this path:

1. Client makes a JSON-RPC request to the MCP endpoint
2. FastMcp::Server receives and parses the request
3. The appropriate tool instance is located and invoked
4. The tool validates parameters and performs business logic
5. ActiveRecord models interact with the database
6. Results are formatted according to MCP specifications
7. Response is delivered back to the client

## Integration Points

### Cascade Integration

GraphMem integrates with Cascade through:

- STDIO transport for direct integration
- Standardized tool interfaces
- MCP-compliant response formatting
- [Customized global rules](global_and_knowledge_graph_management_rules.md) for AI assistants

### External API Integration

In addition to the MCP interface, GraphMem offers a REST API that:

- Follows standard RESTful conventions
- Provides JSON responses
- Implements CORS for browser access
- Offers similar capabilities to the MCP interface

## Performance Considerations

GraphMem is designed with performance in mind:

- Database indices optimize common query patterns
- Eager loading prevents N+1 query issues
- Query result pagination limits response size
- Graph traversal depth limiting prevents excessive recursion

## Security Model

The security model includes:

- No authentication for local development
- Optional authentication for production deployments
- Input validation using JSON Schema
- SQL injection prevention via parameterized queries
- Resource limits to prevent DoS vulnerabilities

## Development and Extension

### Adding New Tools

To add a new MCP tool:

1. Create a new tool class in `app/tools/` that inherits from `ApplicationTool`
2. Define the JSON Schema for parameter validation
3. Implement the `call` method with your business logic
4. Register the tool in `config/initializers/fast_mcp.rb`
5. Add tests in `spec/tools/`

### Adding New Resources

To add a new MCP resource:

1. Create a new resource class in `app/resources/`
2. Define the JSON Schema for query parameters
3. Implement the resource logic
4. Register the resource in `config/initializers/fast_mcp.rb`

## Known Limitations and Workarounds

- **Agentic Client Refresh Requirement**: When making changes to MCP tools or resources, any agentic client usually requires a manual UI refresh to discover the changes.

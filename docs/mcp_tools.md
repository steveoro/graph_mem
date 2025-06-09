# MCP Tools Documentation

This document provides detailed information about the Model Context Protocol (MCP) tools available in GraphMem, how they're implemented, and best practices for using and extending them.

## Overview

MCP tools in GraphMem are Ruby classes that implement specific operations on the knowledge graph. Each tool follows the FastMcp tool pattern and is designed to handle a specific type of operation, such as entity creation, relationship management, or data retrieval.

## Available Tools

GraphMem provides the following MCP tools, categorized by their function:

### Entity Management

#### `get_version`

Returns the current version of the GraphMem server.

**Parameters:** None

**Response:**
```json
{
  "version": "0.7.0"
}
```

#### `create_entity`

Creates a new entity in the knowledge graph.

**Parameters:**
- `name` (string, required): The name of the entity
- `entity_type` (string, required): The type classification for the entity
- `observations` (array of strings, optional): Initial observations to attach to the entity

**Response:**
```json
{
  "id": 123,
  "name": "Project X",
  "entity_type": "Project",
  "observations_count": 1,
  "created_at": "2025-06-09T15:30:00Z",
  "updated_at": "2025-06-09T15:30:00Z"
}
```

#### `get_entity`

Retrieves a specific entity by its ID.

**Parameters:**
- `entity_id` (integer, required): The ID of the entity to retrieve

**Response:**
```json
{
  "id": 123,
  "name": "Project X",
  "entity_type": "Project",
  "observations_count": 3,
  "created_at": "2025-06-09T15:30:00Z",
  "updated_at": "2025-06-09T15:45:00Z",
  "observations": [
    {
      "id": 456,
      "content": "Initial project setup",
      "created_at": "2025-06-09T15:30:00Z",
      "updated_at": "2025-06-09T15:30:00Z"
    }
  ]
}
```

#### `search_entities`

Searches for entities by name (case-insensitive partial match).

**Parameters:**
- `query` (string, required): The search term to find within entity names

**Response:**
```json
[
  {
    "id": 123,
    "name": "Project X",
    "entity_type": "Project",
    "observations_count": 3,
    "created_at": "2025-06-09T15:30:00Z",
    "updated_at": "2025-06-09T15:45:00Z"
  },
  {
    "id": 124,
    "name": "Project Y",
    "entity_type": "Project",
    "observations_count": 1,
    "created_at": "2025-06-09T16:00:00Z",
    "updated_at": "2025-06-09T16:00:00Z"
  }
]
```

#### `list_entities`

Lists entities with pagination support.

**Parameters:**
- `page` (integer, optional): The page number to retrieve (default: 1)
- `per_page` (integer, optional): The number of entities per page (default: 20, max: 100)

**Response:**
```json
{
  "entities": [
    {
      "id": 123,
      "name": "Project X",
      "entity_type": "Project",
      "observations_count": 3,
      "created_at": "2025-06-09T15:30:00Z",
      "updated_at": "2025-06-09T15:45:00Z"
    }
  ],
  "pagination": {
    "total_entities": 45,
    "per_page": 20,
    "current_page": 1,
    "total_pages": 3
  }
}
```

#### `delete_entity`

Deletes an entity and all its associated observations and relations.

**Parameters:**
- `entity_id` (integer, required): The ID of the entity to delete

**Response:**
```json
{
  "success": true,
  "message": "Entity deleted successfully"
}
```

### Observation Management

#### `create_observation`

Adds an observation to an existing entity.

**Parameters:**
- `entity_id` (integer, required): The ID of the entity to add the observation to
- `text_content` (string, required): The content of the observation

**Response:**
```json
{
  "id": 456,
  "content": "New observation content",
  "memory_entity_id": 123,
  "created_at": "2025-06-09T16:15:00Z",
  "updated_at": "2025-06-09T16:15:00Z"
}
```

#### `delete_observation`

Removes an observation from an entity.

**Parameters:**
- `observation_id` (integer, required): The ID of the observation to delete

**Response:**
```json
{
  "success": true,
  "message": "Observation deleted successfully"
}
```

### Relationship Management

#### `create_relation`

Creates a relationship between two existing entities.

**Parameters:**
- `from_entity_id` (integer, required): The ID of the source entity
- `to_entity_id` (integer, required): The ID of the target entity
- `relation_type` (string, required): The type of relationship (e.g., "depends_on", "part_of")

**Response:**
```json
{
  "id": 789,
  "from_entity_id": 123,
  "to_entity_id": 124,
  "relation_type": "depends_on",
  "created_at": "2025-06-09T16:30:00Z",
  "updated_at": "2025-06-09T16:30:00Z"
}
```

#### `delete_relation`

Removes a relationship between entities.

**Parameters:**
- `relation_id` (integer, required): The ID of the relation to delete

**Response:**
```json
{
  "success": true,
  "message": "Relation deleted successfully"
}
```

#### `find_relations`

Finds relationships connected to specified entities.

**Parameters:**
- `from_entity_id` (integer, optional): Filter by source entity ID
- `to_entity_id` (integer, optional): Filter by target entity ID
- `relation_type` (string, optional): Filter by relation type

**Response:**
```json
[
  {
    "id": 789,
    "from_entity_id": 123,
    "to_entity_id": 124,
    "relation_type": "depends_on",
    "created_at": "2025-06-09T16:30:00Z",
    "updated_at": "2025-06-09T16:30:00Z"
  }
]
```

#### `get_subgraph_by_ids`

Retrieves a subgraph consisting of specified entities and their relations.

**Parameters:**
- `entity_ids` (array of integers, required): The IDs of entities to include in the subgraph

**Response:**
```json
{
  "entities": [
    {
      "id": 123,
      "name": "Project X",
      "entity_type": "Project",
      "observations_count": 3,
      "created_at": "2025-06-09T15:30:00Z",
      "updated_at": "2025-06-09T15:45:00Z",
      "observations": [...]
    },
    {
      "id": 124,
      "name": "Project Y",
      "entity_type": "Project",
      "observations_count": 1,
      "created_at": "2025-06-09T16:00:00Z",
      "updated_at": "2025-06-09T16:00:00Z",
      "observations": [...]
    }
  ],
  "relations": [
    {
      "id": 789,
      "from_entity_id": 123,
      "to_entity_id": 124,
      "relation_type": "depends_on",
      "created_at": "2025-06-09T16:30:00Z",
      "updated_at": "2025-06-09T16:30:00Z"
    }
  ]
}
```

#### `get_current_time`

Retrieves the current server time in ISO 8601 format.

**Parameters:** None

**Response:**
```json
{
  "time": "2025-06-09T16:40:00Z"
}
```

## Tool Implementation Details

### Directory Structure

All MCP tools are located in the `app/tools/` directory:

```
app/tools/
├── application_tool.rb                # Base class for all tools
├── version_tool.rb                    # Returns server version
├── entity/
│   ├── create_entity_tool.rb          # Creates new entities
│   ├── get_entity_tool.rb             # Retrieves entities by ID
│   ├── search_entities_tool.rb        # Searches for entities by name
│   ├── list_entities_tool.rb          # Lists entities with pagination
│   └── delete_entity_tool.rb          # Deletes entities
├── observation/
│   ├── create_observation_tool.rb     # Adds observations to entities
│   └── delete_observation_tool.rb     # Removes observations
└── relation/
    ├── create_relation_tool.rb        # Creates relationships
    ├── delete_relation_tool.rb        # Removes relationships
    ├── find_relations_tool.rb         # Finds relationships
    ├── get_subgraph_by_ids_tool.rb    # Gets a subgraph of entities
    └── get_current_time_tool.rb       # Gets server time
```

### Base Tool Class

The `ApplicationTool` class serves as the base class for all tools:

```ruby
# app/tools/application_tool.rb
class ApplicationTool < FastMcp::Tool
  def tool_name
    self.class.tool_name
  end
  
  def self.tool_name
    name.demodulize.underscore.sub(/_tool$/, '')
  end
  
  # Additional shared functionality...
end
```

### Tool Registration

Tools are registered in the FastMcp server configuration:

```ruby
# config/initializers/fast_mcp.rb
server = FastMcp::Server.new(
  version: GraphMem::VERSION,
  transport: transport
)

# Auto-discover and register tool classes
Dir[Rails.root.join('app/tools/**/*_tool.rb')].each do |file|
  require file
  tool_class_name = File.basename(file, '.rb').camelize
  tool_class = tool_class_name.constantize
  server.register_tool(tool_class.new)
end
```

## Creating New Tools

### Step 1: Create the Tool Class

Create a new Ruby class in `app/tools/` that inherits from `ApplicationTool`:

```ruby
# app/tools/my_custom_tool.rb
class MyCustomTool < ApplicationTool
  schema do
    required(:param1).filled(:string)
    optional(:param2).filled(:integer)
  end
  
  def call(params)
    # Your implementation here
    # Return value will be sent as JSON response
    { result: "Success!" }
  end
end
```

### Step 2: Define the JSON Schema

Use the `schema` block to define the parameters your tool accepts:

```ruby
schema do
  required(:required_param).filled(:string)
  optional(:optional_param).filled(:integer)
  optional(:complex_param).schema do
    required(:nested_param).filled(:string)
  end
end
```

### Step 3: Implement Business Logic

Put your business logic in the `call` method:

```ruby
def call(params)
  # Access validated parameters
  entity_id = params[:entity_id]
  
  # Perform operations
  entity = MemoryEntity.find(entity_id)
  
  # Return a response (will be automatically converted to JSON)
  entity.as_json(include: :observations)
end
```

### Step 4: Handle Errors

Use Ruby exceptions for error handling:

```ruby
def call(params)
  begin
    entity = MemoryEntity.find(params[:entity_id])
    entity.as_json
  rescue ActiveRecord::RecordNotFound
    # Will be converted to a JSON-RPC error response
    raise McpGraphMemErrors::ResourceNotFound, "Entity not found"
  rescue => e
    # Generic error
    raise McpGraphMemErrors::OperationFailed, e.message
  end
end
```

## Error Handling

GraphMem defines custom error classes for common scenarios:

```ruby
module McpGraphMemErrors
  # Used when a requested resource is not found
  class ResourceNotFound < StandardError; end
  
  # Used when an operation fails
  class OperationFailed < StandardError; end
end
```

These errors map to specific JSON-RPC error codes:

- `ResourceNotFound` → `-32002`
- `OperationFailed` → `-32003`

## Response Formatting

The FastMcp server has been patched to ensure proper response formatting for the Cascade MCP client:

```ruby
# config/initializers/zzz_fast_mcp_patches.rb
module FastMcp
  class Server
    # Monkey patch to fix tool instantiation issue and ensure proper response format
    def handle_tools_call(id, tool_name, params)
      begin
        # Find tool by name
        tool = @tools.find { |t| t.tool_name.to_s == tool_name.to_s }
        raise FastMcp::Error::MethodNotFound.new if tool.nil?
        
        # Call the tool directly (not tool.new)
        actual_tool_data = tool.call_with_schema_validation!(ActionController::Parameters.new(params))

        # Format response for Cascade MCP client
        response_payload = {
          jsonrpc: "2.0",
          id: id,
          result: {
            content: [
              {
                type: "json",
                json: actual_tool_data.to_json # Convert to JSON string
              }
            ]
          }
        }
        
        @transport.send_message(response_payload)
      rescue => e
        # Error handling code...
      end
    end
  end
end
```

## Best Practices

### Tool Design

1. **Single Responsibility:** Each tool should do one thing well.
2. **Input Validation:** Always validate input parameters using the schema block.
3. **Error Handling:** Use appropriate error classes for different error scenarios.
4. **Response Format:** Return structured data that can be easily serialized to JSON.

### Performance

1. **Pagination:** Always implement pagination for list operations.
2. **Eager Loading:** Use eager loading to avoid N+1 query issues.
3. **Limit Recursion:** Set reasonable limits for graph traversal operations.
4. **Response Size:** Be mindful of response size, especially for graph operations.

### Security

1. **Input Validation:** Always validate and sanitize input parameters.
2. **Resource Authorization:** Verify access permissions for sensitive operations.
3. **Rate Limiting:** Consider implementing rate limiting for production use.

## Testing

Tools should have comprehensive test coverage:

```ruby
# spec/tools/get_entity_tool_spec.rb
require 'rails_helper'

RSpec.describe GetEntityTool do
  describe '#call' do
    let(:entity) { create(:memory_entity, name: 'Test Entity') }
    let(:params) { { entity_id: entity.id } }

    it 'returns the entity when found' do
      result = subject.call(params)
      expect(result[:id]).to eq(entity.id)
      expect(result[:name]).to eq('Test Entity')
    end

    it 'raises ResourceNotFound when entity does not exist' do
      expect {
        subject.call(entity_id: 999999)
      }.to raise_error(McpGraphMemErrors::ResourceNotFound)
    end
  end
end
```

## MCP Resources vs. Tools

GraphMem provides both MCP tools and higher-level resources:

- **Tools:** Direct operations with simple parameter validation
- **Resources:** More complex querying with filtering, sorting, and pagination

For complex data access patterns, consider using the resource approach rather than creating overly complex tools.
# MCP Tools Documentation

This document provides detailed information about the Model Context Protocol (MCP) tools available in GraphMem.

## Overview

MCP tools in GraphMem are Ruby classes that implement specific operations on the knowledge graph. Each tool is designed to handle a specific type of operation, such as entity creation, relationship management, or data retrieval. They are accessed via JSON-RPC calls, typically managed by an MCP client.

## Available Tools

GraphMem provides the following MCP tools, categorized by their function:

### Utility Tools

#### `get_version`
- **Description:** Returns the current version of the GraphMem server.
- **Parameters:** None
- **Response Example:**
  ```json
  {
    "version": "0.8.0"
  }
  ```

#### `get_current_time`
- **Description:** Retrieves the current server time.
- **Parameters:** None
- **Response Example:**
  ```json
  {
    "time": "2024-05-15T10:30:00Z"
  }
  ```

### Entity Management

#### `create_entity`
- **Description:** Creates a new entity in the knowledge graph.
- **Parameters:**
  - `name` (string, required): The unique name for the new entity.
  - `entity_type` (string, required): The type classification for the new entity (e.g., 'Project', 'Task').
  - `aliases` (string, optional): Pipe-separated string of alternative names for the entity.
  - `observations` (array of strings, optional): Initial observation strings to associate with the entity.
- **Response Example:**
  ```json
  {
    "entity_id": 1,
    "name": "New Project Alpha",
    "entity_type": "Project",
    "aliases": "alpha|project_a",
    "observations_count": 1,
    "created_at": "2024-05-15T10:30:00Z",
    "updated_at": "2024-05-15T10:30:00Z"
  }
  ```

#### `get_entity`
- **Description:** Retrieves a specific entity by its ID, including its observations and relations.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity to retrieve.
- **Response Example:**
  ```json
  {
    "entity_id": 1,
    "name": "Project Alpha",
    "entity_type": "Project",
    "aliases": "alpha|project_a",
    "created_at": "2024-05-15T10:30:00Z",
    "updated_at": "2024-05-15T10:35:00Z",
    "observations": [
      {
        "observation_id": 101,
        "content": "Initial setup complete.",
        "created_at": "2024-05-15T10:30:00Z",
        "updated_at": "2024-05-15T10:30:00Z"
      }
    ],
    "relations_from": [
      {
        "relation_id": 201,
        "to_entity_id": 2,
        "to_entity_name": "Task Beta",
        "relation_type": "has_task",
        "created_at": "2024-05-15T10:35:00Z",
        "updated_at": "2024-05-15T10:35:00Z"
      }
    ],
    "relations_to": []
  }
  ```

#### `update_entity`
- **Description:** Updates an existing entity's core properties (name, type, aliases).
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity to update.
  - `name` (string, optional): The new name for the entity. If provided, must be unique.
  - `entity_type` (string, optional): The new type classification for the entity.
  - `aliases` (string, optional): The new pipe-separated string of aliases. This will replace existing aliases. Pass empty string to clear aliases.
- **Response Example:**
  ```json
  {
    "entity_id": 1,
    "name": "Project Alpha Updated",
    "entity_type": "Project",
    "aliases": "alpha_v2|project_alpha_prime",
    "created_at": "2024-05-15T10:30:00Z",
    "updated_at": "2024-05-15T10:40:00Z"
  }
  ```

#### `delete_entity`
- **Description:** Deletes a specific entity by ID. This will also delete associated observations and relations.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity to delete.
- **Response Example:**
  ```json
  {
    "entity_id": 1,
    "name": "Project Alpha Updated",
    "entity_type": "Project",
    "aliases": "alpha_v2|project_alpha_prime",
    "created_at": "2024-05-15T10:30:00Z",
    "updated_at": "2024-05-15T10:40:00Z",
    "message": "Entity and associated data deleted successfully."
  }
  ```

### Observation Management

#### `create_observation`
- **Description:** Creates a new observation and associates it with an existing entity.
- **Parameters:**
  - `entity_id` (integer, required): The ID of the entity to add the observation to.
  - `text_content` (string, required): The textual content of the observation.
- **Response Example:**
  ```json
  {
    "observation_id": 102,
    "memory_entity_id": 1,
    "content": "A new piece of information.",
    "created_at": "2024-05-15T10:45:00Z",
    "updated_at": "2024-05-15T10:45:00Z"
  }
  ```

#### `delete_observation`
- **Description:** Deletes a specific observation by ID.
- **Parameters:**
  - `observation_id` (integer, required): The ID of the observation to delete.
- **Response Example:**
  ```json
  {
    "observation_id": 102,
    "memory_entity_id": 1,
    "content": "A new piece of information.",
    "created_at": "2024-05-15T10:45:00Z",
    "updated_at": "2024-05-15T10:45:00Z",
    "message": "Observation deleted successfully."
  }
  ```

### Relation Management

#### `create_relation`
- **Description:** Creates a relationship between two existing entities.
- **Parameters:**
  - `from_entity_id` (integer, required): The ID of the entity where the relation starts.
  - `to_entity_id` (integer, required): The ID of the entity where the relation ends.
  - `relation_type` (string, required): The type classification for the relationship (e.g., 'related_to', 'depends_on').
- **Response Example:**
  ```json
  {
    "relation_id": 202,
    "from_entity_id": 1,
    "to_entity_id": 3,
    "relation_type": "linked_to",
    "created_at": "2024-05-15T10:50:00Z",
    "updated_at": "2024-05-15T10:50:00Z"
  }
  ```

#### `delete_relation`
- **Description:** Deletes a specific relation by ID.
- **Parameters:**
  - `relation_id` (integer, required): The ID of the relation to delete.
- **Response Example:**
  ```json
  {
    "relation_id": 202,
    "from_entity_id": 1,
    "to_entity_id": 3,
    "relation_type": "linked_to",
    "created_at": "2024-05-15T10:50:00Z",
    "updated_at": "2024-05-15T10:50:00Z",
    "message": "Relation deleted successfully."
  }
  ```

### Search & Query Tools

#### `list_entities`
- **Description:** Retrieves a paginated list of all entities.
- **Parameters:**
  - `page` (integer, optional, default: 1): The page number to retrieve. Must be 1 or greater.
  - `per_page` (integer, optional, default: 20, max: 100): The maximum number of entities to return per page. Must be between 1 and 100.
- **Response Example:**
  ```json
  {
    "entities": [
      {
        "entity_id": 1,
        "name": "Project Alpha Updated",
        "entity_type": "Project",
        "aliases": "alpha_v2|project_alpha_prime",
        "created_at": "2024-05-15T10:30:00Z",
        "updated_at": "2024-05-15T10:40:00Z"
      },
      {
        "entity_id": 2,
        "name": "Task Beta",
        "entity_type": "Task",
        "aliases": null,
        "created_at": "2024-05-15T10:32:00Z",
        "updated_at": "2024-05-15T10:32:00Z"
      }
    ],
    "pagination": {
      "current_page": 1,
      "per_page": 20,
      "total_entries": 2,
      "total_pages": 1
    }
  }
  ```

#### `search_entities`
- **Description:** Searches for entities by name, type, or aliases (case-insensitive).
- **Parameters:**
  - `query` (string, required): The search term to find within entity names, types, or aliases.
- **Response Example (array of matching entities):**
  ```json
  [
    {
      "entity_id": 1,
      "name": "Project Alpha Updated",
      "entity_type": "Project",
      "aliases": "alpha_v2|project_alpha_prime",
      "created_at": "2024-05-15T10:30:00Z",
      "updated_at": "2024-05-15T10:40:00Z"
    }
  ]
  ```

#### `find_relations`
- **Description:** Finds relations based on optional filtering criteria (from_entity_id, to_entity_id, relation_type).
- **Parameters:**
  - `from_entity_id` (integer, optional): Filter relations starting from this entity ID.
  - `to_entity_id` (integer, optional): Filter relations ending at this entity ID.
  - `relation_type` (string, optional): Filter relations by this type.
- **Response Example (array of matching relations):**
  ```json
  [
    {
      "relation_id": 201,
      "from_entity_id": 1,
      "to_entity_id": 2,
      "relation_type": "has_task",
      "created_at": "2024-05-15T10:35:00Z",
      "updated_at": "2024-05-15T10:35:00Z"
    }
  ]
  ```

#### `get_subgraph_by_ids`
- **Description:** Retrieves a specific set of entities by their IDs, including their observations, and all relations that exist exclusively between them.
- **Parameters:**
  - `entity_ids` (array of integers, required): An array of entity IDs to include in the subgraph.
- **Response Example:**
  ```json
  {
    "entities": [
      {
        "entity_id": 1,
        "name": "Project Alpha Updated",
        "entity_type": "Project",
        "aliases": "alpha_v2|project_alpha_prime",
        "created_at": "2024-05-15T10:30:00Z",
        "updated_at": "2024-05-15T10:40:00Z",
        "observations": [
          {
            "observation_id": 101,
            "content": "Initial setup complete.",
            "created_at": "2024-05-15T10:30:00Z",
            "updated_at": "2024-05-15T10:30:00Z"
          }
        ]
      },
      {
        "entity_id": 2,
        "name": "Task Beta",
        "entity_type": "Task",
        "aliases": null,
        "created_at": "2024-05-15T10:32:00Z",
        "updated_at": "2024-05-15T10:32:00Z",
        "observations": []
      }
    ],
    "relations": [
      {
        "relation_id": 201,
        "from_entity_id": 1,
        "to_entity_id": 2,
        "relation_type": "has_task",
        "created_at": "2024-05-15T10:35:00Z",
        "updated_at": "2024-05-15T10:35:00Z"
      }
    ]
  }
  ```

#### `search_subgraph`
- **Description:** Searches a query across entity names, types, aliases, and observations. Returns a paginated subgraph of matching entities (with observations) and relations exclusively between them.
- **Parameters:**
  - `query` (string, required): The search term to find.
  - `search_in_name` (boolean, optional, default: true): Whether to search in entity names.
  - `search_in_type` (boolean, optional, default: true): Whether to search in entity types.
  - `search_in_aliases` (boolean, optional, default: true): Whether to search in entity aliases.
  - `search_in_observations` (boolean, optional, default: true): Whether to search in entity observations.
  - `page` (integer, optional, default: 1): The page number to retrieve.
  - `per_page` (integer, optional, default: 20, max: 100): The number of entities per page.
- **Response Example:**
  ```json
  {
    "entities": [
      {
        "entity_id": 1,
        "name": "Matching Project",
        "entity_type": "Project",
        "aliases": "match",
        "created_at": "2024-05-15T11:00:00Z",
        "updated_at": "2024-05-15T11:05:00Z",
        "observations": [
          {
            "observation_id": 105,
            "content": "This entity matches the search query.",
            "created_at": "2024-05-15T11:00:00Z",
            "updated_at": "2024-05-15T11:00:00Z"
          }
        ]
      }
    ],
    "relations": [],
    "pagination": {
      "current_page": 1,
      "per_page": 20,
      "total_entries": 1,
      "total_pages": 1
    }
  }
  ```
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
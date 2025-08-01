# Memory Graph Resource

The Memory Graph Resource provides a consolidated view of the memory knowledge graph starting from a specified entity and traversing its relationships to a configurable depth.

## Resource URI

```
memory_graph
```

## Query Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| entity_id | **(Required)** The ID of the entity to start the graph traversal from | `entity_id=42` |
| depth | Traversal depth for related entities (default: 1, max: 3) | `depth=2` |
| include_observations | Whether to include observations for entities (true/false) | `include_observations=true` |
| include_relations | Whether to include relations for entities (true/false) | `include_relations=true` |

## Features

This resource combines the capabilities of the `memory_entities`, `memory_observations`, and `memory_relations` resources into a single, graph-oriented view:

- **Recursive Graph Traversal**: Automatically traverses and includes related entities up to the specified depth
- **Cycle Detection**: Prevents infinite loops by tracking visited entity IDs
- **Configurable Inclusion**: Control whether observations and relations are included
- **Performance Safeguards**: Depth is capped at 3 to prevent excessive queries and response sizes

## Use Cases

The Memory Graph Resource is particularly useful for:

1. **Knowledge Exploration**: Starting from a concept and exploring related ideas
2. **Dependency Analysis**: Understanding how entities relate to each other
3. **Context Building**: Gathering comprehensive information about an entity and its connections
4. **Visualization Preparation**: Generating data suitable for graph visualization tools

## Response Format

The response includes:

- The starting entity with its properties
- Observations (if requested) for the entity
- Outgoing and incoming relations (if requested)
- Nested related entities up to the specified depth

### Example Response

```json
{
  "id": 42,
  "name": "Project A",
  "entity_type": "Project",
  "created_at": "2023-06-10T09:00:00Z",
  "updated_at": "2023-06-15T11:00:00Z",
  "memory_observations_count": 3,
  "observations": [
    {
      "id": 101,
      "content": "This is the main project for Team Alpha",
      "memory_entity_id": 42,
      "created_at": "2023-06-10T09:00:00Z",
      "updated_at": "2023-06-10T09:00:00Z"
    }
  ],
  "outgoing_relations": [
    {
      "id": 201,
      "from_entity_id": 42,
      "to_entity_id": 43,
      "relation_type": "has_component",
      "created_at": "2023-06-11T10:00:00Z",
      "updated_at": "2023-06-11T10:00:00Z",
      "to_entity": {
        "id": 43,
        "name": "Feature B",
        "entity_type": "Feature",
        "created_at": "2023-06-11T10:00:00Z",
        "updated_at": "2023-06-11T10:00:00Z",
        "memory_observations_count": 2,
        "observations": [
          {
            "id": 102,
            "content": "Key feature for Phase 1",
            "memory_entity_id": 43,
            "created_at": "2023-06-11T10:00:00Z",
            "updated_at": "2023-06-11T10:00:00Z"
          }
        ]
      }
    }
  ],
  "incoming_relations": [
    {
      "id": 202,
      "from_entity_id": 44,
      "to_entity_id": 42,
      "relation_type": "depends_on",
      "created_at": "2023-06-12T11:00:00Z",
      "updated_at": "2023-06-12T11:00:00Z",
      "from_entity": {
        "id": 44,
        "name": "Project C",
        "entity_type": "Project",
        "created_at": "2023-06-12T11:00:00Z",
        "updated_at": "2023-06-12T11:00:00Z",
        "memory_observations_count": 1
      }
    }
  ]
}
```

## Performance Considerations

When using this resource:

- Higher depth values will result in more database queries and larger responses
- Including observations can significantly increase response size for entities with many observations
- Consider using the more focused resources (`memory_entities`, `memory_observations`, `memory_relations`) for simpler queries
- This resource is best used for exploration or visualization purposes, not for high-frequency API calls

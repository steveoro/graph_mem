# Memory Entity Resource

The `MemoryEntityResource` provides a RESTful interface to access memory entities with advanced filtering, sorting, pagination, and relation inclusion capabilities.

## Resource URI

```
memory_entities{?page,per_page,entity_type,name,id,created_after,created_before,updated_after,updated_before,min_observations,sort_by,sort_dir,include,or_filters}
```

## Basic Usage

To retrieve memory entities, access the resource URI:

```
memory_entities
```

This returns the first 20 memory entities (default pagination).

## Pagination

Control pagination with the following parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `page` | Page number to retrieve (1-indexed) | 1 |
| `per_page` | Number of entities per page | 20 |

Example:

```
memory_entities?page=2&per_page=10
```

## Filtering

Filter entities using any of the following parameters:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `entity_type` | Filter by entity type | `memory_entities?entity_type=Project` |
| `name` | Filter by partial name match | `memory_entities?name=goggles` |
| `id` | Filter by exact entity ID | `memory_entities?id=345` |
| `created_after` | Entities created after this timestamp | `memory_entities?created_after=2025-06-01T00:00:00Z` |
| `created_before` | Entities created before this timestamp | `memory_entities?created_before=2025-06-09T00:00:00Z` |
| `updated_after` | Entities updated after this timestamp | `memory_entities?updated_after=2025-06-01T00:00:00Z` |
| `updated_before` | Entities updated before this timestamp | `memory_entities?updated_before=2025-06-09T00:00:00Z` |
| `min_observations` | Entities with at least this many observations | `memory_entities?min_observations=5` |

Combine multiple filters for more specific results:

```
memory_entities?entity_type=Project&min_observations=3
```

## Advanced Filtering with OR Conditions

Use the `or_filters` parameter to apply OR logic between conditions. This parameter accepts a URL-encoded JSON array of filter objects:

```
memory_entities?or_filters=[{"entity_type":"Issue"},{"entity_type":"Task"}]
```

**Important:** The JSON must be URL-encoded in actual requests:

```
memory_entities?or_filters=%5B%7B%22entity_type%22%3A%22Issue%22%7D%2C%7B%22entity_type%22%3A%22Task%22%7D%5D
```

This example returns entities that are either Issues OR Tasks.

## Sorting

Control result ordering using:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `sort_by` | Field to sort by | `id` |
| `sort_dir` | Sort direction (`asc` or `desc`) | `asc` |

Supported sort fields:
- `id`
- `name`
- `entity_type`
- `observations_count`
- `created_at`
- `updated_at`

Example:

```
memory_entities?sort_by=created_at&sort_dir=desc
```

## Relation Inclusion

The resource supports including related observations and relations using boolean parameters:

- `include_observations=true` - Include memory observations for each entity
- `include_relations=true` - Include incoming and outgoing relations for each entity

You can combine both parameters in a single request:

```
memory_entities?include_observations=true&include_relations=true
```

This approach simplifies parameter handling and avoids the URI parameter limitations encountered with the previous implementation.

## Response Format

All responses follow this format:

```json
{
  "entities": [
    {
      "id": 345,
      "name": "MemoryEntityResource MCP Implementation",
      "entity_type": "Feature",
      "observations_count": 0,
      "created_at": "2025-06-09T12:32:38.328Z",
      "updated_at": "2025-06-09T12:32:38.328Z",
      "memory_observations_count": 7,
      "observations": [...],  // Only included when requested
      "relations": {...}      // Only included when requested
    },
    ...
  ],
  "pagination": {
    "total_entities": 137,
    "per_page": 5,
    "current_page": 1,
    "total_pages": 28
  },
  "applied_filters": {
    // Filter parameters that were applied
  },
  "applied_sorting": {
    "sort_by": "created_at",
    "sort_dir": "desc"
  },
  "applied_includes": {
    "include": ["observations", "relations"]
  }
}
```

## Examples

### Get the 10 most recently created entities:

```
memory_entities?sort_by=created_at&sort_dir=desc&per_page=10
```

### Get all Issue entities with at least 3 observations:

```
memory_entities?entity_type=Issue&min_observations=3
```

### Get entities created in the past week with "test" in their name:

```
memory_entities?created_after=2025-06-02T00:00:00Z&name=test
```

### Get entities that are either Projects or Tasks, along with their observations:

```
memory_entities?or_filters=%5B%7B%22entity_type%22%3A%22Project%22%7D%2C%7B%22entity_type%22%3A%22Task%22%7D%5D&include=observations
```
# Memory Observation Resource

The Memory Observation Resource provides direct access to memory observations with pagination, filtering, and sorting capabilities.

## Resource URI

```
memory_observations
```

## Query Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| page | Page number for pagination (default: 1) | `page=2` |
| per_page | Number of items per page (default: 20, max: 100) | `per_page=50` |
| memory_entity_id | Filter by parent entity ID | `memory_entity_id=42` |
| content | Filter by observation content (partial match) | `content=important` |
| created_after | Filter by creation date (after) | `created_after=2023-01-01T00:00:00Z` |
| created_before | Filter by creation date (before) | `created_before=2023-12-31T23:59:59Z` |
| updated_after | Filter by update date (after) | `updated_after=2023-06-01T00:00:00Z` |
| updated_before | Filter by update date (before) | `updated_before=2023-06-30T23:59:59Z` |
| sort_by | Field to sort by | `sort_by=created_at` |
| sort_dir | Sort direction (asc or desc) | `sort_dir=desc` |
| include_entity | Include parent entity details | `include_entity=true` |

## Sorting

Use `sort_by` and `sort_dir` parameters to control the order of observations:

| Field | Description |
|-------|-------------|
| id | Sort by observation ID |
| memory_entity_id | Sort by parent entity ID |
| content | Sort alphabetically by content |
| created_at | Sort by creation timestamp |
| updated_at | Sort by last update timestamp |

The sorting direction can be `asc` (ascending, default) or `desc` (descending).

Examples:

```
memory_observations?sort_by=created_at&sort_dir=desc
memory_observations?sort_by=memory_entity_id&sort_dir=asc
```

## Entity Inclusion

Use the `include_entity=true` parameter to include the parent entity details with each observation:

```
memory_observations?include_entity=true
```

## Response Format

The response includes the following sections:

- `observations`: Array of observation objects
- `pagination`: Information about the current page and total results
- `applied_filters`: Summary of filters that were applied
- `applied_sorting`: Summary of the sorting applied
- `applied_includes`: Summary of any included related data

### Example Response

```json
{
  "observations": [
    {
      "id": 123,
      "memory_entity_id": 42,
      "content": "This is an important observation",
      "created_at": "2023-06-15T10:30:00Z",
      "updated_at": "2023-06-15T10:30:00Z",
      "entity": {
        "id": 42,
        "name": "Important Entity",
        "entity_type": "Feature",
        "aliases": "important_entity,entity_a",
        "created_at": "2023-06-10T09:00:00Z",
        "updated_at": "2023-06-15T11:00:00Z"
      }
    }
  ],
  "pagination": {
    "total_observations": 150,
    "per_page": 20,
    "current_page": 1,
    "total_pages": 8
  },
  "applied_filters": {
    "memory_entity_id": "42"
  },
  "applied_sorting": {
    "sort_by": "created_at",
    "sort_dir": "desc"
  },
  "applied_includes": {
    "include_entity": true
  }
}
```

# Memory Relation Resource

The Memory Relation Resource provides direct access to memory relations with pagination, filtering, and sorting capabilities.

## Resource URI

```
memory_relations
```

## Query Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| page | Page number for pagination (default: 1) | `page=2` |
| per_page | Number of items per page (default: 20, max: 100) | `per_page=50` |
| from_entity_id | Filter by source entity ID | `from_entity_id=42` |
| to_entity_id | Filter by target entity ID | `to_entity_id=43` |
| relation_type | Filter by relation type | `relation_type=depends_on` |
| created_after | Filter by creation date (after) | `created_after=2023-01-01T00:00:00Z` |
| created_before | Filter by creation date (before) | `created_before=2023-12-31T23:59:59Z` |
| updated_after | Filter by update date (after) | `updated_after=2023-06-01T00:00:00Z` |
| updated_before | Filter by update date (before) | `updated_before=2023-06-30T23:59:59Z` |
| sort_by | Field to sort by | `sort_by=created_at` |
| sort_dir | Sort direction (asc or desc) | `sort_dir=desc` |
| include_from_entity | Include source entity details | `include_from_entity=true` |
| include_to_entity | Include target entity details | `include_to_entity=true` |

## Sorting

Use `sort_by` and `sort_dir` parameters to control the order of relations:

| Field | Description |
|-------|-------------|
| id | Sort by relation ID |
| from_entity_id | Sort by source entity ID |
| to_entity_id | Sort by target entity ID |
| relation_type | Sort alphabetically by relation type |
| created_at | Sort by creation timestamp |
| updated_at | Sort by last update timestamp |

The sorting direction can be `asc` (ascending, default) or `desc` (descending).

Examples:

```
memory_relations?sort_by=created_at&sort_dir=desc
memory_relations?sort_by=relation_type&sort_dir=asc
```

## Entity Inclusion

You can include associated entities with your relations using these parameters:

- `include_from_entity=true` - Include the source entity details
- `include_to_entity=true` - Include the target entity details
- Both can be used together: `include_from_entity=true&include_to_entity=true`

## Graph Traversal Queries

The resource supports basic graph traversal through filter combinations:

1. **Find all relations from a specific entity:**
   ```
   memory_relations?from_entity_id=42
   ```

2. **Find all relations to a specific entity:**
   ```
   memory_relations?to_entity_id=43
   ```

3. **Find all relations of a specific type:**
   ```
   memory_relations?relation_type=depends_on
   ```

4. **Find specific relation types between two entities:**
   ```
   memory_relations?from_entity_id=42&to_entity_id=43&relation_type=depends_on
   ```

## Response Format

The response includes the following sections:

- `relations`: Array of relation objects
- `pagination`: Information about the current page and total results
- `applied_filters`: Summary of filters that were applied
- `applied_sorting`: Summary of the sorting applied
- `applied_includes`: Summary of any included related data

### Example Response

```json
{
  "relations": [
    {
      "id": 123,
      "from_entity_id": 42,
      "to_entity_id": 43,
      "relation_type": "depends_on",
      "created_at": "2023-06-15T10:30:00Z",
      "updated_at": "2023-06-15T10:30:00Z",
      "from_entity": {
        "id": 42,
        "name": "Project A",
        "entity_type": "Project",
        "aliases": "project_a",
        "created_at": "2023-06-10T09:00:00Z",
        "updated_at": "2023-06-15T11:00:00Z"
      },
      "to_entity": {
        "id": 43,
        "name": "Task B",
        "entity_type": "Task",
        "aliases": "task_b",
        "created_at": "2023-06-12T14:00:00Z",
        "updated_at": "2023-06-14T16:30:00Z"
      }
    }
  ],
  "pagination": {
    "total_relations": 150,
    "per_page": 20,
    "current_page": 1,
    "total_pages": 8
  },
  "applied_filters": {
    "relation_type": "depends_on"
  },
  "applied_sorting": {
    "sort_by": "created_at",
    "sort_dir": "desc"
  },
  "applied_includes": {
    "include_from_entity": true,
    "include_to_entity": true
  }
}
```

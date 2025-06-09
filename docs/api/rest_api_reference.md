# GraphMem REST API Reference

This document provides a comprehensive reference for the GraphMem REST API, which complements the MCP interface by offering a traditional RESTful approach to accessing the graph memory system.

## API Overview

The GraphMem REST API is available at the `/api/v1` endpoint and provides access to the following resources:

- **Memory Entities** - Knowledge graph nodes
- **Memory Observations** - Text content attached to entities
- **Memory Relations** - Relationships between entities
- **Status** - System status information

All API responses are formatted as JSON and use standard HTTP response codes. The API follows RESTful conventions for resource operations.

## Base URL

```
http://localhost:3000/api/v1
```

## Authentication

The API does not require authentication in development mode. For production deployments, authentication can be enabled through configuration.

## Common Response Formats

### Success Responses

Successful responses include an HTTP status code in the 2xx range and a JSON body with the requested data.

### Error Responses

Error responses include an HTTP status code in the 4xx or 5xx range and a JSON body with details about the error:

```json
{
  "error": "Error message",
  "details": {...}  // Optional additional information
}
```

## Memory Entities API

Memory entities are the nodes in the knowledge graph.

### List Memory Entities

Retrieves a list of memory entities.

**Endpoint:** `GET /api/v1/memory_entities`

**Query Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| page | Page number | `page=2` |
| per_page | Items per page | `per_page=20` |
| entity_type | Filter by entity type | `entity_type=Project` |
| name | Filter by name (partial match) | `name=task` |

**Response:** `200 OK`

```json
[
  {
    "id": 1,
    "name": "Project A",
    "entity_type": "Project",
    "observations_count": 5,
    "created_at": "2025-06-01T10:00:00Z",
    "updated_at": "2025-06-02T14:30:00Z"
  },
  {
    "id": 2,
    "name": "Task B",
    "entity_type": "Task",
    "observations_count": 2,
    "created_at": "2025-06-01T11:00:00Z",
    "updated_at": "2025-06-01T11:00:00Z"
  }
]
```

### Create Memory Entity

Creates a new memory entity.

**Endpoint:** `POST /api/v1/memory_entities`

**Request Body:**

```json
{
  "name": "New Project",
  "entity_type": "Project"
}
```

**Required Fields:**
- `name` (string): The name of the entity
- `entity_type` (string): The type classification of the entity

**Response:** `201 Created`

```json
{
  "id": 3,
  "name": "New Project",
  "entity_type": "Project",
  "observations_count": 0,
  "created_at": "2025-06-09T15:00:00Z",
  "updated_at": "2025-06-09T15:00:00Z"
}
```

### Get Memory Entity

Retrieves a specific memory entity by ID.

**Endpoint:** `GET /api/v1/memory_entities/:id`

**Response:** `200 OK`

```json
{
  "id": 1,
  "name": "Project A",
  "entity_type": "Project",
  "observations_count": 5,
  "created_at": "2025-06-01T10:00:00Z",
  "updated_at": "2025-06-02T14:30:00Z"
}
```

### Update Memory Entity

Updates an existing memory entity.

**Endpoint:** `PATCH /api/v1/memory_entities/:id`

**Request Body:**

```json
{
  "name": "Updated Project Name"
}
```

**Response:** `200 OK`

```json
{
  "id": 1,
  "name": "Updated Project Name",
  "entity_type": "Project",
  "observations_count": 5,
  "created_at": "2025-06-01T10:00:00Z",
  "updated_at": "2025-06-09T16:00:00Z"
}
```

### Delete Memory Entity

Deletes a memory entity and its associated observations and relations.

**Endpoint:** `DELETE /api/v1/memory_entities/:id`

**Response:** `204 No Content`

## Memory Observations API

Memory observations are text content attached to entities.

### List Memory Observations

Retrieves a list of observations.

**Endpoint:** `GET /api/v1/memory_observations`

**Query Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| page | Page number | `page=2` |
| per_page | Items per page | `per_page=20` |
| memory_entity_id | Filter by entity ID | `memory_entity_id=1` |
| content | Filter by content (partial match) | `content=important` |

**Response:** `200 OK`

```json
[
  {
    "id": 1,
    "content": "This is an important observation",
    "memory_entity_id": 1,
    "created_at": "2025-06-01T10:05:00Z",
    "updated_at": "2025-06-01T10:05:00Z"
  },
  {
    "id": 2,
    "content": "Another observation",
    "memory_entity_id": 1,
    "created_at": "2025-06-01T10:10:00Z",
    "updated_at": "2025-06-01T10:10:00Z"
  }
]
```

### Create Memory Observation

Creates a new observation for an entity.

**Endpoint:** `POST /api/v1/memory_observations`

**Request Body:**

```json
{
  "content": "New observation text",
  "memory_entity_id": 1
}
```

**Required Fields:**
- `content` (string): The text content of the observation
- `memory_entity_id` (integer): The ID of the entity to attach the observation to

**Response:** `201 Created`

```json
{
  "id": 3,
  "content": "New observation text",
  "memory_entity_id": 1,
  "created_at": "2025-06-09T16:30:00Z",
  "updated_at": "2025-06-09T16:30:00Z"
}
```

### Get Memory Observation

Retrieves a specific observation by ID.

**Endpoint:** `GET /api/v1/memory_observations/:id`

**Response:** `200 OK`

```json
{
  "id": 1,
  "content": "This is an important observation",
  "memory_entity_id": 1,
  "created_at": "2025-06-01T10:05:00Z",
  "updated_at": "2025-06-01T10:05:00Z"
}
```

### Update Memory Observation

Updates an existing observation.

**Endpoint:** `PATCH /api/v1/memory_observations/:id`

**Request Body:**

```json
{
  "content": "Updated observation text"
}
```

**Response:** `200 OK`

```json
{
  "id": 1,
  "content": "Updated observation text",
  "memory_entity_id": 1,
  "created_at": "2025-06-01T10:05:00Z",
  "updated_at": "2025-06-09T16:45:00Z"
}
```

### Delete Memory Observation

Deletes an observation.

**Endpoint:** `DELETE /api/v1/memory_observations/:id`

**Response:** `204 No Content`

## Memory Relations API

Memory relations represent relationships between entities.

### List Memory Relations

Retrieves a list of relations.

**Endpoint:** `GET /api/v1/memory_relations`

**Query Parameters:**

| Parameter | Description | Example |
|-----------|-------------|---------|
| page | Page number | `page=2` |
| per_page | Items per page | `per_page=20` |
| from_entity_id | Filter by source entity ID | `from_entity_id=1` |
| to_entity_id | Filter by target entity ID | `to_entity_id=2` |
| relation_type | Filter by relation type | `relation_type=depends_on` |

**Response:** `200 OK`

```json
[
  {
    "id": 1,
    "from_entity_id": 1,
    "to_entity_id": 2,
    "relation_type": "depends_on",
    "created_at": "2025-06-01T10:15:00Z",
    "updated_at": "2025-06-01T10:15:00Z"
  },
  {
    "id": 2,
    "from_entity_id": 3,
    "to_entity_id": 1,
    "relation_type": "part_of",
    "created_at": "2025-06-01T10:20:00Z",
    "updated_at": "2025-06-01T10:20:00Z"
  }
]
```

### Create Memory Relation

Creates a new relation between entities.

**Endpoint:** `POST /api/v1/memory_relations`

**Request Body:**

```json
{
  "from_entity_id": 1,
  "to_entity_id": 3,
  "relation_type": "depends_on"
}
```

**Required Fields:**
- `from_entity_id` (integer): The ID of the source entity
- `to_entity_id` (integer): The ID of the target entity
- `relation_type` (string): The type of relationship

**Response:** `201 Created`

```json
{
  "id": 3,
  "from_entity_id": 1,
  "to_entity_id": 3,
  "relation_type": "depends_on",
  "created_at": "2025-06-09T17:00:00Z",
  "updated_at": "2025-06-09T17:00:00Z"
}
```

### Get Memory Relation

Retrieves a specific relation by ID.

**Endpoint:** `GET /api/v1/memory_relations/:id`

**Response:** `200 OK`

```json
{
  "id": 1,
  "from_entity_id": 1,
  "to_entity_id": 2,
  "relation_type": "depends_on",
  "created_at": "2025-06-01T10:15:00Z",
  "updated_at": "2025-06-01T10:15:00Z"
}
```

### Update Memory Relation

Updates an existing relation.

**Endpoint:** `PATCH /api/v1/memory_relations/:id`

**Request Body:**

```json
{
  "relation_type": "updated_relation_type"
}
```

**Response:** `200 OK`

```json
{
  "id": 1,
  "from_entity_id": 1,
  "to_entity_id": 2,
  "relation_type": "updated_relation_type",
  "created_at": "2025-06-01T10:15:00Z",
  "updated_at": "2025-06-09T17:15:00Z"
}
```

### Delete Memory Relation

Deletes a relation.

**Endpoint:** `DELETE /api/v1/memory_relations/:id`

**Response:** `204 No Content`

## Status API

Provides information about the system status.

### Get Status

Retrieves the current system status.

**Endpoint:** `GET /api/v1/status`

**Response:** `200 OK`

```json
{
  "status": "ok",
  "version": "0.7.0"
}
```

## Error Codes

The API uses standard HTTP status codes to indicate the success or failure of requests:

- `200 OK` - The request was successful and the response body contains the requested data
- `201 Created` - The resource was successfully created
- `204 No Content` - The request was successful but there is no response body
- `400 Bad Request` - The request was malformed or invalid
- `404 Not Found` - The requested resource was not found
- `422 Unprocessable Entity` - The request was well-formed but contained invalid parameters
- `500 Internal Server Error` - An unexpected error occurred on the server

## Pagination

List endpoints support pagination through the `page` and `per_page` query parameters:

- `page` - The page number to retrieve (default: 1)
- `per_page` - The number of items per page (default: 20, max: 100)

Responses include pagination metadata:

```json
{
  "data": [...],
  "pagination": {
    "current_page": 2,
    "per_page": 20,
    "total_items": 45,
    "total_pages": 3
  }
}
```

## Advanced Filtering

Some endpoints support additional filtering options:

- **Memory Entities**:
  - `created_after` - Filter by creation date (format: ISO 8601)
  - `created_before` - Filter by creation date (format: ISO 8601)
  - `updated_after` - Filter by update date (format: ISO 8601)
  - `updated_before` - Filter by update date (format: ISO 8601)

- **Memory Observations**:
  - `created_after` - Filter by creation date (format: ISO 8601)
  - `created_before` - Filter by creation date (format: ISO 8601)

- **Memory Relations**:
  - `created_after` - Filter by creation date (format: ISO 8601)
  - `created_before` - Filter by creation date (format: ISO 8601)

## Additional Resources

- [Swagger Documentation](/swagger/v1/swagger.yaml) - OpenAPI specification
- [MCP Tools Documentation](/docs/mcp_tools.md) - Alternative MCP interface
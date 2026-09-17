# frozen_string_literal: true

module GraphMem
  # Shallow, post-ToolSuccessResponse schemas for the 12 default MCP tools.
  module McpOutputSchemas
    CONTEXT = {
      type: "object",
      properties: {
        status: { const: "none" },
        next_move: { type: "string" }
      },
      required: %w[status next_move],
      additionalProperties: true
    }.freeze
    OBSERVATION = {
      type: "object",
      properties: {
        observation_id: { type: "integer" },
        content: { type: "string" },
        observation_content: { type: "string" },
        status: { type: "string" }
      },
      additionalProperties: true
    }.freeze
    ENTITY = {
      type: "object",
      properties: {
        entity_id: { type: "integer" },
        name: { type: "string" },
        entity_type: { type: "string" },
        observations: { type: "array", items: { "$ref": "#/$defs/observation" } }
      },
      additionalProperties: true
    }.freeze
    RELATION = {
      type: "object",
      properties: {
        relation_id: { type: "integer" },
        from_entity_id: { type: "integer" },
        to_entity_id: { type: "integer" },
        relation_type: { type: "string" }
      },
      additionalProperties: true
    }.freeze
    PAGINATION = {
      type: "object",
      properties: {
        current_page: { type: "integer" },
        per_page: { type: "integer" }
      },
      additionalProperties: true
    }.freeze
    BASE_DEFS = {
      context: CONTEXT,
      observation: OBSERVATION,
      entity: ENTITY,
      relation: RELATION,
      pagination: PAGINATION
    }.freeze

    TOOL_BODIES = {
      "get_context" => {
        properties: { status: { type: "string" } },
        required: %w[status],
        oneOf: %w[no_context context_active context_cleared].map do |status|
          { properties: { status: { const: status } } }
        end
      },
      "set_context" => {
        properties: { status: { type: "string" } },
        required: %w[status],
        oneOf: %w[context_set context_cleared].map do |status|
          { properties: { status: { const: status } } }
        end
      },
      "search" => {
        properties: {
          mode: { enum: %w[catalog summary subgraph] },
          entities: { type: "array", items: { "$ref": "#/$defs/entity" } },
          results: { type: "array", items: { type: "object", additionalProperties: true } },
          relations: { type: "array", items: { "$ref": "#/$defs/relation" } },
          pagination: { "$ref": "#/$defs/pagination" }
        },
        required: %w[mode],
        oneOf: [
          { properties: { mode: { const: "catalog" } }, required: %w[entities pagination] },
          { properties: { mode: { const: "summary" } }, required: %w[results pagination retrieval] },
          { properties: { mode: { const: "subgraph" } }, required: %w[entities pagination retrieval] }
        ]
      },
      "get_entities" => {
        properties: {
          entities: { type: "array", items: { "$ref": "#/$defs/entity" } },
          relations: { type: "array", items: { "$ref": "#/$defs/relation" } },
          missing_entity_ids: { type: "array", items: { type: "integer" } },
          relation_scope: { enum: %w[all internal] }
        },
        required: %w[entities relations missing_entity_ids relation_scope]
      },
      "traverse_graph" => {
        properties: {
          entities: { type: "array", items: { "$ref": "#/$defs/entity" } },
          relations: { type: "array", items: { "$ref": "#/$defs/relation" } },
          traversal: { type: "object", additionalProperties: true }
        },
        oneOf: [
          { required: %w[traversal] },
          {
            not: { required: %w[traversal] },
            anyOf: [ { required: %w[entities] }, { required: %w[relations] } ]
          }
        ]
      },
      "find_shortest_path" => {
        properties: {
          found: { type: "boolean" },
          hop_count: { type: [ "integer", "null" ] },
          direction: { type: "string" },
          entities: { type: "array", items: { "$ref": "#/$defs/entity" } },
          relations: { type: "array", items: { "$ref": "#/$defs/relation" } }
        },
        required: %w[found hop_count direction entities relations]
      },
      "summarize" => {
        properties: {
          query: { type: "string" },
          summary: { type: "string" },
          sources: { type: "array" }
        },
        required: %w[query summary]
      },
      "rank_observations" => {
        properties: {
          entity_id: { type: "integer" },
          observations: { type: "array", items: { "$ref": "#/$defs/observation" } }
        },
        required: %w[entity_id observations]
      },
      "graph_write" => {
        properties: {
          mode: { const: "batch" },
          status: { enum: %w[ok possible_duplicate] },
          results: { type: "array" },
          summary: { type: "object" },
          candidates: { type: "array" }
        },
        required: %w[mode status],
        oneOf: [
          { properties: { status: { const: "ok" } }, required: %w[results summary] },
          {
            properties: { status: { const: "possible_duplicate" } },
            required: %w[kind operation_index submitted candidates]
          }
        ]
      },
      "graph_edit" => {
        properties: {
          mode: { const: "batch" },
          status: { const: "ok" },
          results: { type: "array" },
          summary: { type: "object" }
        },
        required: %w[mode status results summary]
      },
      "graph_delete" => {
        properties: {
          mode: { const: "batch" },
          status: { const: "ok" },
          results: { type: "array" },
          summary: { type: "object" }
        },
        required: %w[mode status results summary]
      },
      "get_current_time" => {
        properties: { timestamp: { type: "string", format: "date-time" } },
        required: %w[timestamp]
      }
    }.freeze

    module_function

    # Returns the post-envelope output schema for a canonical default tool.
    #
    # @param tool_name [String, Symbol]
    # @return [Hash, nil] JSON Schema or nil for non-default/legacy tools
    def for(tool_name)
      body = TOOL_BODIES[tool_name.to_s]
      return unless body

      schema = {
        type: "object",
        properties: {
          version: { type: "string" },
          next_move: { type: [ "string", "null" ] },
          context: { "$ref": "#/$defs/context" }
        }.merge(body.fetch(:properties)),
        required: (Array(body[:required]) + %w[version]).uniq,
        additionalProperties: true,
        "$defs": BASE_DEFS
      }
      schema[:oneOf] = body[:oneOf] if body[:oneOf]
      schema
    end
  end
end

# frozen_string_literal: true

class FindRelationsTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "find_relations"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    advertised: false,
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Find 1-hop edges matching optional AND-combined filters. Pass optional `from_entity_id` (integer), " \
    "`to_entity_id` (integer), `relation_type` (string, canonicalized). Returns relations only. " \
    "Do not use for a multi-hop neighborhood; use `traverse_graph` instead. " \
    "Do not use for the shortest path between two entities; use `find_shortest_path` instead. " \
    "Do not use for one entity's relations bundled with observations; use `get_entities` instead. " \
    "Do not use to create or delete edges; use `graph_write` or `graph_delete` instead."

  arguments do
    optional(:from_entity_id).filled(:integer).description("Optional: Filter relations starting from this entity ID.")
    optional(:to_entity_id).filled(:integer).description("Optional: Filter relations ending at this entity ID.")
    optional(:relation_type).filled(:string).description("Optional: Filter relations by this type.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  # Needed, otherwise the LLM will not figure out the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: {
        from_entity_id: { type: "integer", description: "Optional: Filter relations starting from this entity ID." },
        to_entity_id: { type: "integer", description: "Optional: Filter relations ending at this entity ID." },
        relation_type: { type: "string", description: "Optional: Filter relations by this type." }
      },
      required: []
    }
  end

  # Output: Array of relation objects

  def call(from_entity_id: nil, to_entity_id: nil, relation_type: nil)
    logger.info "Performing FindRelationsTool with filters: from=#{from_entity_id}, to=#{to_entity_id}, type=#{relation_type}"
    begin
      RelationQueryService.call(
        from_entity_id: from_entity_id,
        to_entity_id: to_entity_id,
        relation_type: relation_type
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue StandardError => e
      logger.error "InternalServerError in FindRelationsTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

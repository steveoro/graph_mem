# frozen_string_literal: true

class FindRelationsTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "find_relations"
  end

  description "Find 1-hop edges matching optional AND-combined filters. Pass optional `from_entity_id` (integer), " \
    "`to_entity_id` (integer), `relation_type` (string, canonicalized). Returns relations only. " \
    "Do not use for a multi-hop neighborhood; use `traverse_graph` instead. " \
    "Do not use for the shortest path between two entities; use `find_shortest_path` instead. " \
    "Do not use for one entity's relations bundled with observations; use `get_entity` instead. " \
    "Do not use to create or delete edges; use `create_relation` or `delete_relation` instead."

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
      if from_entity_id.present? && !MemoryEntity.exists?(id: from_entity_id)
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{from_entity_id} not found.",
          next_move: "Call `search_entities`, then retry `find_relations` with a known from_entity_id."
        )
      end
      if to_entity_id.present? && !MemoryEntity.exists?(id: to_entity_id)
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity with ID=#{to_entity_id} not found.",
          next_move: "Call `search_entities`, then retry `find_relations` with a known to_entity_id."
        )
      end

      relations_query = MemoryRelation.all

      relations_query = relations_query.where(from_entity_id: from_entity_id) if from_entity_id.present?
      relations_query = relations_query.where(to_entity_id: to_entity_id) if to_entity_id.present?
      if relation_type.present?
        relations_query = relations_query.where(relation_type: MemoryRelation.canonical_relation_type(relation_type))
      end

      matching_relations = relations_query.to_a

      matching_relations.map do |relation|
        {
          relation_id: relation.id,
          from_entity_id: relation.from_entity_id,
          to_entity_id: relation.to_entity_id,
          relation_type: relation.relation_type,
          weight: relation.weight,
          confidence: relation.confidence,
          properties: relation.properties,
          created_at: relation.created_at.iso8601,
          updated_at: relation.updated_at.iso8601
        }
      end
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

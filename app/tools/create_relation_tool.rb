# frozen_string_literal: true

class CreateRelationTool < ApplicationTool
  def self.tool_name
    "create_relation"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Add one directed edge between two existing entities. Pass required `from_entity_id` " \
    "(integer or name; aliases `from_entity`, `from`), `to_entity_id` (integer or name; aliases `to_entity`, `to`), " \
    "and `relation_type` (string, canonicalized); optional `weight` (float >=0), `confidence` (float 0-1), " \
    "`properties` (hash). Do not use to create nodes; use `graph_write` instead. " \
    "Do not use to batch-create relations; use `graph_write` instead. " \
    "Do not use to query existing 1-hop edges; use `traverse_graph` instead. " \
    "Do not use for a multi-hop neighborhood; use `traverse_graph` instead. " \
    "Do not use to remove an edge; use `graph_delete` instead."

  arguments do
    required(:from_entity_id).filled(:integer).description("The ID of the entity where the relation starts.")
    required(:to_entity_id).filled(:integer).description("The ID of the entity where the relation ends.")
    required(:relation_type).filled(:string).description("The type classification for the relationship (e.g., 'related_to', 'depends_on').")
    optional(:weight).maybe(:float).description("Optional non-negative relation weight.")
    optional(:confidence).maybe(:float).description("Optional confidence score from 0.0 to 1.0.")
    optional(:properties).hash.description("Optional structured relation properties.")
  end

  def call(from_entity_id:, to_entity_id:, relation_type:, weight: nil, confidence: nil, properties: {})
    logger.info "Performing CreateRelationTool with from_id: #{from_entity_id}, to_id: #{to_entity_id}, type: #{relation_type}"
    begin
      GraphWriteService.execute_one(
        "create_relation",
        {
          from_entity_id: from_entity_id,
          to_entity_id: to_entity_id,
          relation_type: relation_type,
          weight: weight,
          confidence: confidence,
          properties: properties
        },
        logger: logger
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue ActiveRecord::RecordInvalid => e
      error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}. " \
        "Pass from_entity_id and to_entity_id as integers of existing entities, relation_type as a non-empty string, " \
        "optional weight as a float >= 0, confidence as a float from 0.0 to 1.0, and properties as an object."
      logger.error "InvalidArguments in CreateRelationTool: #{error_message} (was: #{e.message})"
      raise FastMcp::Tool::InvalidArgumentsError, error_message
    rescue ActiveRecord::RecordNotUnique
      canonical_type = MemoryRelation.canonical_relation_type(relation_type)
      error_message = "A relation of type '#{canonical_type}' already exists from from_entity_id=#{from_entity_id} " \
        "to to_entity_id=#{to_entity_id}."
      logger.error "OperationFailed in CreateRelationTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed.new(
        error_message,
        category: "validation",
        next_move: "Call `traverse_graph` to inspect the existing edge, or `graph_delete` before creating a replacement."
      )
    rescue StandardError => e
      logger.error "InternalServerError in CreateRelationTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

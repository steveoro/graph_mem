# frozen_string_literal: true

class GraphEditTool < ApplicationTool
  MAX_OPERATIONS = GraphMutationBatch::MAX_OPERATIONS

  def self.tool_name
    "graph_edit"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Rewrite what the graph already knows. When a stored rule or fact is outdated, call " \
    "update_observation with `supersede: true` (history is kept) rather than adding a new dated observation. " \
    "Atomically edit graph data with up to #{MAX_OPERATIONS} type-discriminated `operations`. " \
    "Use update_entity with entity_id and metadata fields, or update_observation with observation_id, fields, " \
    "and optional supersede/reason. Every operation rolls back if any operation fails. " \
    "Do not use to create data; use `graph_write` instead. " \
    "Do not use to obsolete, delete, or merge data; use `graph_delete` instead."

  arguments do
    required(:operations).array(:hash).description("update_entity or update_observation operations.")
  end

  # Publishes the update fields GraphEditService accepts without rejecting extra keys.
  #
  # @return [Hash] JSON Schema with a typed `operations` item
  def self.input_schema_to_json
    schema = super.deep_dup
    # GraphEditService looks records up by numeric id only; names are not resolved.
    id_reference = { type: "integer", description: "Numeric id; names aren't resolved." }
    schema[:properties][:operations][:items] = {
      type: "object",
      required: [ "type" ],
      additionalProperties: true,
      properties: {
        type: { type: "string", examples: GraphEditService::TYPES, description: "Operation discriminator." },
        entity_id: id_reference,
        observation_id: id_reference,
        name: { type: "string" },
        entity_type: { type: "string", examples: GraphVocabulary::ENTITY_TYPES },
        aliases: {
          type: "array", items: { type: "string" },
          description: "Replaces existing aliases; [] clears. No \"|\" inside an alias. A legacy pipe-separated string is still accepted."
        },
        description: { type: "string" },
        text_content: { type: "string" },
        supersede: { type: "boolean", description: "true keeps the old text as history." },
        reason: { type: "string" }
      }.merge(observation_field_properties)
    }
    schema
  end

  # Observation field definitions shared with `graph_write`.
  #
  # @return [Hash]
  def self.observation_field_properties
    GraphWriteTool.input_schema_to_json.dig(:properties, :operations, :items, :properties)
                  .slice(:confidence, :source, :valid_from, :valid_until, :tags, :perspective)
  end
  private_class_method :observation_field_properties

  def call(operations:)
    GraphEditService.call(operations: operations)
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "GraphEditTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

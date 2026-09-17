# frozen_string_literal: true

class GraphWriteTool < ApplicationTool
  MAX_OPERATIONS = GraphMutationBatch::MAX_OPERATIONS

  def self.tool_name
    "graph_write"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Atomically create entities, observations, and relations (max #{MAX_OPERATIONS} logical operations). " \
    "Pass primary `operations` items with type create_entity, create_observation, or create_relation; the existing " \
    "`entities`, `observations`, and `relations` arrays are also accepted. Single writes use one operation. " \
    "A possible entity duplicate prevents every write and returns candidate details. " \
    "Do not use to update existing data; use `graph_edit` instead. " \
    "Do not use to delete or merge data; use `graph_delete` instead."

  arguments do
    optional(:operations).array(:hash).description("Type-discriminated create operations.")
    optional(:entities).array(:hash).description("Compatibility array of entities to create.")
    optional(:observations).array(:hash).description("Compatibility array of observations to create.")
    optional(:relations).array(:hash).description("Compatibility array of relations to create.")
  end

  # Publishes soft type vocabularies without rejecting custom values.
  #
  # @return [Hash] JSON Schema for canonical and compatibility inputs
  def self.input_schema_to_json
    schema = super.deep_dup
    operation_properties = {
      type: {
        type: "string",
        examples: GraphWriteService::TYPES,
        description: "Operation discriminator."
      },
      name: { type: "string" },
      entity_type: { type: "string", examples: GraphVocabulary::ENTITY_TYPES },
      entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
      text_content: { type: "string" },
      from_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
      to_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
      relation_type: { type: "string", examples: GraphVocabulary::RELATION_TYPES }
    }
    schema[:properties][:operations][:items] = {
      type: "object",
      properties: operation_properties,
      required: [ "type" ],
      additionalProperties: true
    }
    schema[:properties][:entities][:items] = {
      type: "object",
      properties: {
        name: { type: "string" },
        entity_type: { type: "string", examples: GraphVocabulary::ENTITY_TYPES }
      },
      additionalProperties: true
    }
    schema[:properties][:relations][:items] = {
      type: "object",
      properties: {
        from_entity_id: operation_properties[:from_entity_id],
        to_entity_id: operation_properties[:to_entity_id],
        relation_type: operation_properties[:relation_type]
      },
      additionalProperties: true
    }
    schema
  end

  def call(operations: [], entities: [], observations: [], relations: [])
    bucket_operations = GraphWriteService.operations_from_buckets(
      entities: entities,
      observations: observations,
      relations: relations
    )
    GraphWriteService.call(
      operations: Array(operations) + bucket_operations,
      logger: logger
    )
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "GraphWriteTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

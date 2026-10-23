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

  description "Persist a durable lesson. Call when the user corrects you or states a preference, when you learn " \
    "where something lives, or when a fix or procedure is verified. Write each observation as one general, " \
    "imperative rule with scope and reason (\"In <project>, when <situation>, do <action> because <reason>\"), " \
    "not a log of what happened; set `source`, and `valid_until` for time-bound facts. To correct a stored rule, " \
    "use `graph_edit` update_observation with `supersede: true` instead of appending. " \
    "Atomically create entities, observations, and relations (max #{MAX_OPERATIONS} logical operations). " \
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
      relation_type: { type: "string", examples: GraphVocabulary::RELATION_TYPES },
      source: { type: "string", description: "Who/what this came from, e.g. \"claude-code/opus: release task\"." },
      confidence: { type: "number", minimum: 0, maximum: 1 },
      valid_from: { type: "string", format: "date-time" },
      valid_until: { type: "string", format: "date-time", description: "Set for time-bound facts; must be ≥ valid_from." },
      tags: { type: "array", items: { type: "string" } },
      perspective: { type: "string", enum: MemoryObservation::PERSPECTIVES },
      weight: { type: "number", minimum: 0, description: "create_relation only." },
      properties: { type: "object", description: "create_relation only." }
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
    schema[:properties][:observations][:items] = {
      type: "object",
      additionalProperties: true,
      properties: {
        entity_id: operation_properties[:entity_id],
        text_content: operation_properties[:text_content]
      }.merge(operation_properties.slice(:source, :confidence, :valid_from, :valid_until, :tags, :perspective))
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
      logger: logger,
      project_id: graph_mem_context.current_project_id
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

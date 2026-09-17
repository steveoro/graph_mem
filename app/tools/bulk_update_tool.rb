# frozen_string_literal: true

class BulkUpdateTool < ApplicationTool
  MAX_OPERATIONS = 50

  def self.tool_name
    "bulk_update"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Atomically batch-create entities, observations, and relations (max #{MAX_OPERATIONS} operations; " \
    "rolls back on error). Pass optional `entities`, `observations`, `relations` arrays, or `operations` " \
    "(type-discriminated items with type create_entity, create_observation, or create_relation). " \
    "At least one operation is required. Create-only. Do not use for a single create; use `graph_write`, " \
    "`graph_write`, or `graph_write` instead. Do not use to update, delete, or merge; use " \
    "`graph_edit`, `graph_edit`, `graph_delete`, `graph_delete`, `graph_delete`, or " \
    "`graph_delete` instead."

  arguments do
    optional(:entities).description("Entities to create.")
    optional(:observations).description("Observations to add to existing entities.")
    optional(:relations).description("Relations to create between entities.")
  end

  def self.input_schema_to_json
    {
      type: "object",
      properties: {
        entities: {
          type: "array",
          items: {
            type: "object",
            properties: {
              name: { type: "string" },
              entity_type: { type: "string" },
              aliases: { type: %w[string null] },
              description: { type: %w[string null] },
              observations: { type: "array", items: { type: "string" } }
            },
            required: %w[name entity_type]
          },
          description: "Entities to create."
        },
        observations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              entity_id: { type: "integer" },
              text_content: { type: "string" },
              confidence: { type: %w[number null], minimum: 0, maximum: 1 },
              source: { type: %w[string null] },
              valid_from: { type: %w[string null], format: "date-time" },
              valid_until: { type: %w[string null], format: "date-time" },
              tags: { type: "array", items: { type: "string" } }
            },
            required: %w[entity_id text_content]
          },
          description: "Observations to add to existing entities."
        },
        relations: {
          type: "array",
          maxItems: MAX_OPERATIONS,
          items: {
            type: "object",
            properties: {
              from_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
              to_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
              relation_type: { type: "string" },
              weight: { type: %w[number null], minimum: 0 },
              confidence: { type: %w[number null], minimum: 0, maximum: 1 },
              properties: { type: "object", additionalProperties: true }
            },
            required: %w[from_entity_id to_entity_id relation_type]
          },
          description: "Relations to create between entities."
        },
        operations: {
          type: "array",
          maxItems: MAX_OPERATIONS,
          items: {
            type: "object",
            properties: {
              type: { type: "string" },
              name: { type: "string" },
              entity_type: { type: "string" },
              entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
              from_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
              to_entity_id: { oneOf: [ { type: "integer" }, { type: "string" } ] },
              relation_type: { type: "string" },
              text_content: { type: "string" },
              content: { type: "string" },
              contents: { type: "array", items: { type: "string" } }
            },
            required: %w[type]
          },
          description: "Type-discriminated operations alternative to entities/observations/relations arrays."
        }
      },
      required: []
    }
  end

  def call(entities: [], observations: [], relations: [])
    operations = GraphWriteService.operations_from_buckets(
      entities: entities,
      observations: observations,
      relations: relations
    )
    if operations.empty?
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one operation (entity, observation, or relation) is required. " \
            "Provide at least one item in `entities`, `observations`, `relations`, or `operations` and retry."
    end
    if operations.size > MAX_OPERATIONS
      raise FastMcp::Tool::InvalidArgumentsError,
            "Maximum #{MAX_OPERATIONS} operations per call (got #{operations.size}). " \
            "Split into multiple `graph_write` calls of #{MAX_OPERATIONS} or fewer operations."
    end

    result = GraphWriteService.call(operations: operations, logger: logger)
    return result if result[:status] == "possible_duplicate"

    entity_results = results_for(result, "create_entity")
    observation_results = results_for(result, "create_observation")
    relation_results = results_for(result, "create_relation")

    {
      created_entities: entity_results.map { |item| item.slice(:entity_id, :name, :entity_type) },
      created_observations: observation_results.map do |item|
        item.slice(:observation_id, :entity_id, :confidence, :source, :valid_from, :valid_until, :tags)
      end,
      created_relations: relation_results.map do |item|
        {
          relation_id: item[:relation_id],
          from: item[:from_entity_id],
          to: item[:to_entity_id],
          type: item[:relation_type],
          weight: item[:weight],
          confidence: item[:confidence],
          properties: item[:properties]
        }
      end,
      summary: {
        entities_created: entity_results.size,
        observations_created: observation_results.size,
        relations_created: relation_results.size
      }
    }
  rescue FastMcp::Tool::InvalidArgumentsError => e
    raise if e.message.match?(/At least one operation|Maximum \d+ operations/)

    raise FastMcp::Tool::InvalidArgumentsError,
          "Bulk operation rolled back due to errors: #{e.message}. " \
          "Fix the listed op errors and retry `graph_write`."
  rescue McpGraphMemErrors::Error => e
    raise FastMcp::Tool::InvalidArgumentsError,
          "Bulk operation rolled back due to errors: #{e.message}. " \
          "Fix the listed op errors and retry `graph_write`."
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "BulkUpdateTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def results_for(result, type)
    result[:results].filter_map { |item| item[:result] if item[:type] == type }
  end
end

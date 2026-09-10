# frozen_string_literal: true

class BulkUpdateTool < ApplicationTool
  MAX_OPERATIONS = 50

  def self.tool_name
    "bulk_update"
  end

  description "Atomically batch-create entities, observations, and relations (max #{MAX_OPERATIONS} operations; " \
    "rolls back on error). Pass optional `entities`, `observations`, `relations` arrays, or `operations` " \
    "(type-discriminated items with type create_entity, create_observation, or create_relation). " \
    "At least one operation is required. Create-only. Do not use for a single create; use `create_entity`, " \
    "`create_observation`, or `create_relation` instead. Do not use to update, delete, or merge; use " \
    "`update_entity`, `update_observation`, `delete_entity`, `delete_observation`, `delete_relation`, or " \
    "`merge_entities` instead."

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
    entities ||= []
    observations ||= []
    relations ||= []

    total_ops = entities.length + observations.length + relations.length
    if total_ops == 0
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one operation (entity, observation, or relation) is required. " \
            "Provide at least one item in `entities`, `observations`, `relations`, or `operations` and retry."
    end
    if total_ops > MAX_OPERATIONS
      raise FastMcp::Tool::InvalidArgumentsError,
            "Maximum #{MAX_OPERATIONS} operations per call (got #{total_ops}). " \
            "Split into multiple `bulk_update` calls of #{MAX_OPERATIONS} or fewer operations."
    end

    created_entities = []
    created_observations = []
    created_relations = []
    errors = []

    ActiveRecord::Base.transaction do
      entities.each_with_index do |ent_data, idx|
        ent_data = ent_data.symbolize_keys
        entity = MemoryEntity.create!(
          name: ent_data[:name],
          entity_type: ent_data[:entity_type],
          aliases: ent_data[:aliases],
          description: ent_data[:description]
        )

        (ent_data[:observations] || []).each do |obs_text|
          MemoryObservation.create!(memory_entity: entity, content: obs_text)
        end

        created_entities << { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type }
      rescue ActiveRecord::RecordInvalid => e
        errors << { type: "entity", index: idx, error: e.record.errors.full_messages.join(", ") }
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback if errors.any?

      observations.each_with_index do |obs_data, idx|
        obs_data = obs_data.symbolize_keys
        obs = MemoryObservation.create!(
          memory_entity_id: obs_data[:entity_id],
          content: obs_data[:text_content],
          confidence: obs_data[:confidence],
          source: obs_data[:source],
          valid_from: obs_data[:valid_from],
          valid_until: obs_data[:valid_until],
          tags: obs_data[:tags] || []
        )
        created_observations << {
          observation_id: obs.id,
          entity_id: obs.memory_entity_id,
          confidence: obs.confidence,
          source: obs.source,
          valid_from: obs.valid_from&.iso8601,
          valid_until: obs.valid_until&.iso8601,
          tags: obs.tags
        }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
        errors << { type: "observation", index: idx, error: e.message }
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback if errors.any?

      relations.each_with_index do |rel_data, idx|
        rel_data = rel_data.symbolize_keys
        rel = MemoryRelation.create!(
          from_entity_id: rel_data[:from_entity_id],
          to_entity_id: rel_data[:to_entity_id],
          relation_type: MemoryRelation.canonical_relation_type(rel_data[:relation_type]),
          weight: rel_data[:weight],
          confidence: rel_data[:confidence],
          properties: rel_data[:properties] || {}
        )
        created_relations << {
          relation_id: rel.id,
          from: rel.from_entity_id,
          to: rel.to_entity_id,
          type: rel.relation_type,
          weight: rel.weight,
          confidence: rel.confidence,
          properties: rel.properties
        }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
        errors << { type: "relation", index: idx, error: e.message }
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      raise FastMcp::Tool::InvalidArgumentsError,
            "Bulk operation rolled back due to errors: #{errors.map { |e| "#{e[:type]}[#{e[:index]}]: #{e[:error]}" }.join('; ')}. " \
            "Fix the listed op errors and retry `bulk_update`."
    end

    {
      created_entities: created_entities,
      created_observations: created_observations,
      created_relations: created_relations,
      summary: {
        entities_created: created_entities.length,
        observations_created: created_observations.length,
        relations_created: created_relations.length
      }
    }
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "BulkUpdateTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

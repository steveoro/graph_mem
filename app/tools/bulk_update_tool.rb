# frozen_string_literal: true

class BulkUpdateTool < ApplicationTool
  MAX_OPERATIONS = 50

  def self.tool_name
    "bulk_update"
  end

  description "Perform multiple graph memory operations in a single atomic transaction. " \
    "Supports creating entities, adding observations, and creating relations in one call. " \
    "Maximum #{MAX_OPERATIONS} total operations per call."

  arguments do
    optional(:entities).description("Array of entities to create. Each: {name, entity_type, aliases?, description?, observations?[]}")
    optional(:observations).description("Array of observations to add. Each: {entity_id, text_content}")
    optional(:relations).description("Array of relations to create. Each: {from_entity_id, to_entity_id, relation_type}")
  end

  def input_schema_to_json
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
              aliases: { type: [ "string", "null" ] },
              description: { type: [ "string", "null" ] },
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
              text_content: { type: "string" }
            },
            required: %w[entity_id text_content]
          },
          description: "Observations to add to existing entities."
        },
        relations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              from_entity_id: { type: "integer" },
              to_entity_id: { type: "integer" },
              relation_type: { type: "string" }
            },
            required: %w[from_entity_id to_entity_id relation_type]
          },
          description: "Relations to create between entities."
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
      raise FastMcp::Tool::InvalidArgumentsError, "At least one operation (entity, observation, or relation) is required."
    end
    if total_ops > MAX_OPERATIONS
      raise FastMcp::Tool::InvalidArgumentsError, "Maximum #{MAX_OPERATIONS} operations per call (got #{total_ops})."
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
          content: obs_data[:text_content]
        )
        created_observations << { observation_id: obs.id, entity_id: obs.memory_entity_id }
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
          relation_type: rel_data[:relation_type]
        )
        created_relations << { relation_id: rel.id, from: rel.from_entity_id, to: rel.to_entity_id, type: rel.relation_type }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
        errors << { type: "relation", index: idx, error: e.message }
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      raise FastMcp::Tool::InvalidArgumentsError,
            "Bulk operation rolled back due to errors: #{errors.map { |e| "#{e[:type]}[#{e[:index]}]: #{e[:error]}" }.join('; ')}"
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
  rescue StandardError => e
    logger.error "BulkUpdateTool error: #{e.message} - #{e.backtrace.first(5).join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "Bulk operation failed: #{e.message}"
  end
end

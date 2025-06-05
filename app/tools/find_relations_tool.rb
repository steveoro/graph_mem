# frozen_string_literal: true

class FindRelationsTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'find_relations'
  end

  description "Find relations for an entity in the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      entity_id: { type: "string", description: "The ID of the entity to find relations for." }
    },
    required: ["entity_id"]
  })

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  # Needed, otherwise the LLM will not figure out the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "string", description: "The ID of the entity to find relations for." }
      },
      required: ["entity_id"]
    }
  end

  # Output: Array of relation objects

  def call(entity_id:)
    return validation_error("Entity ID cannot be blank") if entity_id.blank?

    entity = MemoryEntity.find_by(id: entity_id)
    return not_found_error("Entity", entity_id) unless entity

    relations_from = MemoryRelation.includes(:to_entity).where(from_entity: entity)
    relations_to = MemoryRelation.includes(:from_entity).where(to_entity: entity)

    result = {
      entity_id: entity_id,
      entity_name: entity.name,
      relations_from: relations_from.map { |r| {
        relation_id: r.id.to_s,
        to_entity_name: r.to_entity.name,
        relation_type: r.relation_type
      }},
      relations_to: relations_to.map { |r| {
        relation_id: r.id.to_s,
        from_entity_name: r.from_entity.name,
        relation_type: r.relation_type
      }}
    }

    success_response(result)
  rescue StandardError => e
    error_response("Error finding relations: #{e.message}")
  end
end

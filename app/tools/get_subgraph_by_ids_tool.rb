# frozen_string_literal: true

class GetSubgraphByIdsTool < ApplicationTool
  def self.tool_name
    'get_subgraph_by_ids'
  end

  description "Get a subgraph containing specific entities and their relations."

  tool_input_schema({
    type: "object",
    properties: {
      entity_ids: {
        type: "array",
        items: { type: "string" },
        description: "Array of entity IDs to include in the subgraph."
      }
    },
    required: ["entity_ids"]
  })

  def call(entity_ids:)
    return validation_error("Entity IDs cannot be empty") if entity_ids.blank?

    entities = MemoryEntity.includes(:memory_observations).where(id: entity_ids)
    relations = MemoryRelation.includes(:from_entity, :to_entity)
                              .where(from_entity_id: entity_ids, to_entity_id: entity_ids)

    result = {
      entities: entities.map do |entity|
        {
          entity_id: entity.id.to_s,
          name: entity.name,
          entity_type: entity.entity_type,
          observations_count: entity.memory_observations.count
        }
      end,
      relations: relations.map do |relation|
        {
          relation_id: relation.id.to_s,
          from_entity_name: relation.from_entity.name,
          to_entity_name: relation.to_entity.name,
          relation_type: relation.relation_type
        }
      end
    }

    success_response(result)
  rescue StandardError => e
    error_response("Error getting subgraph: #{e.message}")
  end
end

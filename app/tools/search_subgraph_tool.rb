# frozen_string_literal: true

class SearchSubgraphTool < ApplicationTool
  DEFAULT_PER_PAGE = 20 # Renamed from DEFAULT_LIMIT
  MAX_PER_PAGE = 100    # Renamed from MAX_LIMIT
  DEFAULT_PAGE = 1

  def self.tool_name
    'search_subgraph'
  end

  description "Search for entities and return a subgraph with their relations."

  tool_input_schema({
    type: "object",
    properties: {
      query: { type: "string", description: "Search query for entities." },
      limit: { type: "integer", description: "Maximum entities to return (default: 10).", default: 10 }
    },
    required: ["query"]
  })

  def call(query:, limit: 10)
    return validation_error("Query cannot be blank") if query.blank?

    limit = [[limit.to_i, 1].max, 50].min

    entities = MemoryEntity.where("name ILIKE ? OR entity_type ILIKE ?", "%#{query}%", "%#{query}%")
                           .limit(limit).includes(:memory_observations)

    entity_ids = entities.pluck(:id)
    relations = MemoryRelation.includes(:from_entity, :to_entity)
                              .where("from_entity_id IN (?) OR to_entity_id IN (?)", entity_ids, entity_ids)

    result = {
      query: query,
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
    error_response("Error searching subgraph: #{e.message}")
  end
end

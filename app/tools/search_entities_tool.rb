# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'search_entities'
  end

  description "Search entities by name or type in the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      query: {
        type: "string",
        description: "Search query to match against entity names or types."
      },
      limit: {
        type: "integer",
        description: "Maximum number of results to return (default: 20).",
        default: 20
      }
    },
    required: ["query"]
  })

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: { query: { type: "string", description: "The search term to find within entity names (case-insensitive)." } },
      required: [ "query" ]
    }
  end

  # Output: Array of entity objects

  def call(query:, limit: 20)
    logger.info "Searching entities with query: #{query}"

    return validation_error("Query cannot be blank") if query.blank?

    limit = [[limit.to_i, 1].max, 100].min  # Between 1 and 100

    entities = MemoryEntity.where(
      "name ILIKE ? OR entity_type ILIKE ?",
      "%#{query}%", "%#{query}%"
    ).limit(limit).includes(:memory_observations)

    result = {
      query: query,
      results: entities.map do |entity|
        {
          entity_id: entity.id.to_s,
          name: entity.name,
          entity_type: entity.entity_type,
          observations_count: entity.memory_observations.count
        }
      end,
      count: entities.count
    }

    success_response(result)
  rescue StandardError => e
    logger.error "Error in SearchEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An error occurred while searching entities: #{e.message}")
  end
end

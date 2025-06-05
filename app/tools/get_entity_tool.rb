# frozen_string_literal: true

class GetEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'get_entity'
  end

  description "Retrieve an entity by ID with its observations from the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      entity_id: {
        type: "string",
        description: "The ID of the entity to retrieve."
      }
    },
    required: ["entity_id"]
  })

  # Output: Complex object with entity details, observations, and relations (from/to)

  def call(entity_id:)
    logger.info "Retrieving entity with ID: #{entity_id}"

    # Validate inputs
    return validation_error("Entity ID cannot be blank") if entity_id.blank?

    # Find the entity with observations
    entity = MemoryEntity.includes(:memory_observations).find_by(id: entity_id)
    return not_found_error("Entity", entity_id) unless entity

    logger.info "Found entity: #{entity.name} with #{entity.memory_observations.count} observations"

    # Format output hash
    result = {
      entity_id: entity.id.to_s,
      name: entity.name,
      entity_type: entity.entity_type,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      observations: entity.memory_observations.map do |obs|
        {
          observation_id: obs.id.to_s,
          content: obs.content,
          created_at: obs.created_at.iso8601,
          updated_at: obs.updated_at.iso8601
        }
      end,
      observations_count: entity.memory_observations.count
    }

    success_response(result)
  rescue StandardError => e
    logger.error "Error in GetEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An internal server error occurred while retrieving the entity: #{e.message}")
  end
end

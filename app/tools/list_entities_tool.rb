# frozen_string_literal: true

class ListEntitiesTool < ApplicationTool
  def self.tool_name
    'list_entities'
  end

  description "List all entities in the graph memory database with pagination."

  tool_input_schema({
    type: "object",
    properties: {
      limit: {
        type: "integer",
        description: "Maximum number of entities to return (default: 50, max: 1000).",
        default: 50
      },
      offset: {
        type: "integer",
        description: "Number of entities to skip for pagination (default: 0).",
        default: 0
      },
      entity_type: {
        type: "string",
        description: "Filter entities by type (optional)."
      }
    },
    required: []
  })

  def call(limit: 50, offset: 0, entity_type: nil)
    logger.info "Listing entities with limit: #{limit}, offset: #{offset}, type: #{entity_type}"

    # Validate and sanitize inputs
    limit = [[limit.to_i, 1].max, 1000].min  # Between 1 and 1000
    offset = [offset.to_i, 0].max  # Non-negative

    # Build query
    query = MemoryEntity.includes(:memory_observations)
    query = query.where(entity_type: entity_type) if entity_type.present?

    # Get total count for pagination info
    total_count = query.count

    # Apply pagination
    entities = query.limit(limit).offset(offset).order(:created_at)

    logger.info "Found #{entities.count} entities (#{total_count} total)"

    # Format output
    result = {
      entities: entities.map do |entity|
        {
          entity_id: entity.id.to_s,
          name: entity.name,
          entity_type: entity.entity_type,
          observations_count: entity.memory_observations.count,
          created_at: entity.created_at.iso8601,
          updated_at: entity.updated_at.iso8601
        }
      end,
      pagination: {
        limit: limit,
        offset: offset,
        total_count: total_count,
        returned_count: entities.count,
        has_more: (offset + limit) < total_count
      }
    }

    success_response(result)
  rescue StandardError => e
    logger.error "Error in ListEntitiesTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An internal server error occurred while listing entities: #{e.message}")
  end
end

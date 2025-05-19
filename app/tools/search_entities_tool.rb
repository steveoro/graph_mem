# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  description "Search for graph memory entities by name."

  arguments do
    required(:query).filled(:string).description("The search term to find within entity names (case-insensitive).")
  end

  # Output: Array of entity objects

  def call(query:)
    logger.info "Performing SearchEntitiesTool with query: #{query}"
    begin
      # Perform case-insensitive search using LOWER on both sides
      matching_entities = MemoryEntity.where("LOWER(name) LIKE LOWER(?)", "%#{query}%").to_a

      # Format output (array of entity objects) - return array of hashes directly
      matching_entities.map do |entity|
        {
          id: entity.id,
          name: entity.name,
          entity_type: entity.entity_type,
          created_at: entity.created_at.iso8601,
          updated_at: entity.updated_at.iso8601
        }
      end
    rescue => e
      logger.error "Unexpected error in SearchEntitiesTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end

# frozen_string_literal: true

class SearchEntitiesTool < ApplicationTool
  description "Search for graph memory entities by name."

  property :query,
           type: "string",
           description: "The search term to find within entity names (case-insensitive).",
           required: true

  # Output: Array of entity objects

  def perform
    logger.info "Performing SearchEntitiesTool with query: #{query}"
    begin
      # Perform case-insensitive search using LOWER
      matching_entities = MemoryEntity.where("LOWER(name) LIKE LOWER(?)", "%#{query.downcase}%").to_a

      # Format output (array of entity objects)
      result_hash = matching_entities.map do |entity|
        {
          id: entity.id,
          name: entity.name,
          entity_type: entity.entity_type,
          created_at: entity.created_at.iso8601,
          updated_at: entity.updated_at.iso8601
        }
      end
      render(text: result_hash.to_json, mime_type: "application/json")

    # No KeyError needed
    rescue => e
      logger.error "Unexpected error in SearchEntitiesTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end

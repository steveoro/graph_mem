# frozen_string_literal: true

class GetEntityTool < ApplicationTool
  description "Retrieve a specific entity by ID, including its observations and relations."

  property :entity_id,
           type: "integer",
           description: "The ID of the entity to retrieve.",
           required: true

  # Output: Complex object with entity details, observations, and relations (from/to)

  def perform
    logger.info "Performing GetEntityTool with entity_id: #{entity_id}"
    begin
      # Find the entity and pre-load associations for efficiency
      entity = MemoryEntity.includes(:memory_observations, :relations_from, :relations_to)
                           .find(entity_id)

      # Format the output hash
      result_hash = {
        id: entity.id,
        name: entity.name,
        entity_type: entity.entity_type,
        created_at: entity.created_at.iso8601,
        updated_at: entity.updated_at.iso8601,
        observations: entity.memory_observations.map do |obs|
          {
            id: obs.id,
            content: obs.content,
            created_at: obs.created_at.iso8601,
            updated_at: obs.updated_at.iso8601
          }
        end,
        relations_from: entity.relations_from.map do |rel|
          {
            id: rel.id,
            to_entity_id: rel.to_entity_id,
            relation_type: rel.relation_type,
            created_at: rel.created_at.iso8601,
            updated_at: rel.updated_at.iso8601
            # Include to_entity details here if desired
          }
        end,
        relations_to: entity.relations_to.map do |rel|
          {
            id: rel.id,
            from_entity_id: rel.from_entity_id,
            relation_type: rel.relation_type,
            created_at: rel.created_at.iso8601,
            updated_at: rel.updated_at.iso8601
            # Include from_entity details here if desired
          }
        end
      }
      render(text: result_hash.to_json, mime_type: "application/json")

    rescue ActiveRecord::RecordNotFound => e
      logger.error "Entity Not Found in GetEntityTool: ID=#{entity_id}"
      render(error: [ "Entity with ID=#{entity_id} not found." ])
    # No KeyError needed
    rescue => e
      logger.error "Unexpected error in GetEntityTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end

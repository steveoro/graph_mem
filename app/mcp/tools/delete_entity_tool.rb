# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  description "Delete a specific entity by ID. This will also delete associated observations and relations."

  property :entity_id,
           type: "integer",
           description: "The ID of the entity to delete.",
           required: true

  # Output: Success message object

  def perform
    logger.info "Performing DeleteEntityTool with entity_id: #{entity_id}"
    begin
      # Find and destroy the entity
      # Assuming dependent: :destroy is set correctly on MemoryEntity model for relations/observations
      entity = MemoryEntity.find(entity_id)
      entity.destroy!

      # Return success message
      render(text: "Entity with ID=#{entity_id} and its associated data deleted successfully.", mime_type: "text/plain")

    rescue ActiveRecord::RecordNotFound => e
      logger.error "Entity Not Found in DeleteEntityTool: ID=#{entity_id}"
      render(error: [ "Entity with ID=#{entity_id} not found." ])
    # No KeyError needed
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Entity in DeleteEntityTool: ID=#{entity_id}, Error: #{e.message}"
      render(error: [ "Failed to delete entity: #{e.message}" ])
    rescue => e
      logger.error "Unexpected error in DeleteEntityTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end

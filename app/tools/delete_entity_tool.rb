# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  description "Delete a specific entity by ID. This will also delete associated observations and relations."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to delete.")
  end

  # Output: Success message object

  def call(entity_id:)
    logger.info "Performing DeleteEntityTool with entity_id: #{entity_id}"
    begin
      # Find and destroy the entity
      # Assuming dependent: :destroy is set correctly on MemoryEntity model for relations/observations
      entity = MemoryEntity.find(entity_id)
      entity.destroy!

      # Return success message - as a hash
      { message: "Entity with ID=#{entity_id} and its associated data deleted successfully." }
    rescue ActiveRecord::RecordNotFound => e
      logger.error "Entity Not Found in DeleteEntityTool: ID=#{entity_id}"
      raise FastMcp::Errors::ResourceNotFound, "Entity with ID=#{entity_id} not found."
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "Failed to Destroy Entity in DeleteEntityTool: ID=#{entity_id}, Error: #{e.message}"
      raise FastMcp::Errors::OperationFailed, "Failed to delete entity: #{e.message}"
    rescue => e
      logger.error "Unexpected error in DeleteEntityTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end

# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'delete_entity'
  end

  description "Delete a specific entity by ID. This will also delete associated observations and relations."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to delete.")
  end

  # def self.input_schema
  #   schema
  # end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: { entity_id: { type: "integer", description: "The ID of the entity to delete." } },
      required: [ "entity_id" ]
    }
  end

  # Output: Success message object

  def call(entity_id:)
    logger.info "Performing DeleteEntityTool with entity_id: #{entity_id}"
    begin
      # Find and destroy the entity
      # Assuming dependent: :destroy is set correctly on MemoryEntity model for relations/observations
      entity = MemoryEntity.find(entity_id)
      entity_attributes = entity.attributes # Capture attributes before destroy
      entity.destroy!

      # Return the attributes of the deleted entity as a simple hash, plus a success message
      {
        id: entity_attributes["id"],
        name: entity_attributes["name"],
        entity_type: entity_attributes["entity_type"],
        created_at: entity_attributes["created_at"].iso8601(3),
        updated_at: entity_attributes["updated_at"].iso8601(3),
        # observations_count was part of the original entity, include if it makes sense
        # observations_count: entity_attributes["observations_count"],
        message: "Entity with ID=#{entity_id} and its associated data deleted successfully."
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in DeleteEntityTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordNotDestroyed => e
      error_message = "Failed to delete entity with ID=#{entity_id}: #{e.message}"
      logger.error "OperationFailed in DeleteEntityTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed, error_message
    rescue StandardError => e
      logger.error "InternalServerError in DeleteEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in DeleteEntityTool: #{e.message}"
    end
  end
end

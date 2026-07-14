# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_entity"
  end

  description "Delete a specific entity by ID. This will also delete associated observations and relations."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to delete.")
    optional(:reason).maybe(:string).description("Optional reason for deletion, e.g., 'duplicate' or 'API/operator'.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "integer", description: "The ID of the entity to delete." },
        reason: { type: "string", description: "Optional reason for deletion, e.g., 'duplicate' or 'API/operator'." }
      },
      required: [ "entity_id" ]
    }
  end

  # Output: Success message object

  def call(entity_id:, reason: nil)
    logger.info "Performing DeleteEntityTool with entity_id: #{entity_id}, reason: #{reason}"
    begin
      # Find and destroy the entity
      # Assuming dependent: :destroy is set correctly on MemoryEntity model for relations/observations
      entity = MemoryEntity.find(entity_id)
      if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
        error_message = NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR
        logger.error "OperationFailed in DeleteEntityTool: #{error_message}"
        raise McpGraphMemErrors::OperationFailed, error_message
      end

      entity_attributes = entity.attributes # Capture attributes before destroy
      begin
        Current.deletion_reason = reason
        entity.destroy!
      ensure
        Current.deletion_reason = nil
      end

      # Return the attributes of the deleted entity as a simple hash, plus a success message
      {
        entity_id: entity_attributes["id"],
        name: entity_attributes["name"],
        entity_type: entity_attributes["entity_type"],
        aliases: entity_attributes["aliases"],
        memory_observations_count: entity_attributes["memory_observations_count"],
        created_at: entity_attributes["created_at"].iso8601(3),
        updated_at: entity_attributes["updated_at"].iso8601(3),
        message: "Entity with ID=#{entity_id} and its associated data deleted successfully."
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in DeleteEntityTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue McpGraphMemErrors::OperationFailed
      raise
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

# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_entity"
  end

  description "Destroy one entity and cascade-delete its observations and relations. Pass required `entity_id` (integer); " \
    "optional `reason` (string, audit log). Do not use when the entity is a duplicate of another; use `merge_entities` instead. " \
    "Do not use to obsolete a single fact; use `delete_observation` instead. " \
    "Do not use to remove a single edge; use `delete_relation` instead. " \
    "Do not use to change metadata without deleting; use `update_entity` instead. " \
    "Do not use to leave this client's project scope; use `clear_context` instead."

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
        raise McpGraphMemErrors::OperationFailed.new(
          error_message,
          category: "validation",
          next_move: "Call `merge_entities` to combine this Project with another, or retry `delete_entity` with a non-Project entity."
        )
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
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search_entities` or `list_entities`, then retry `delete_entity` with a known id."
      )
    rescue McpGraphMemErrors::OperationFailed
      raise
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "OperationFailed in DeleteEntityTool: Failed to delete entity with ID=#{entity_id}: #{e.message}"
      raise McpGraphMemErrors::OperationFailed.new(
        "Failed to delete entity with ID=#{entity_id}.",
        next_move: "Retry `delete_entity` once, then escalate to a human if it fails again."
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue StandardError => e
      logger.error "DeleteEntityTool unexpected error: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

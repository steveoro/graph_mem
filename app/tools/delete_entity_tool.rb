# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_entity"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Destroy one entity and cascade-delete its observations and relations. Pass required `entity_id` (integer); " \
    "optional `reason` (string, audit log). Do not use when the entity is a duplicate of another; use `graph_delete` instead. " \
    "Do not use to obsolete a single fact; use `graph_delete` instead. " \
    "Do not use to remove a single edge; use `graph_delete` instead. " \
    "Do not use to change metadata without deleting; use `graph_edit` instead. " \
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
      GraphDeleteService.execute_one("delete_entity", entity_id: entity_id, reason: reason)
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in DeleteEntityTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search`, then retry `graph_delete` with a known id."
      )
    rescue McpGraphMemErrors::OperationFailed
      raise
    rescue McpGraphMemErrors::ResourceNotFound, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue ActiveRecord::RecordNotDestroyed => e
      logger.error "OperationFailed in DeleteEntityTool: Failed to delete entity with ID=#{entity_id}: #{e.message}"
      raise McpGraphMemErrors::OperationFailed.new(
        "Failed to delete entity with ID=#{entity_id}.",
        next_move: "Retry `graph_delete` once, then escalate to a human if it fails again."
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue StandardError => e
      logger.error "DeleteEntityTool unexpected error: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

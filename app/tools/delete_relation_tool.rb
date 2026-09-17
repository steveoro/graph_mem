# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_relation"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Delete one graph edge by id without deleting either entity. Pass required `relation_id` (integer); " \
    "optional `reason` (string, audit log). Do not use if you lack a relation_id; use `traverse_graph` first. " \
    "Do not use to remove an entity and its relations; use `graph_delete` instead. " \
    "Do not use for queued duplicate-relation cleanup; use `apply_maintenance_review` instead. " \
    "Do not use to add an edge; use `graph_write` instead."

  arguments do
    required(:relation_id).filled(:integer).description("The ID of the relation to delete.")
    optional(:reason).maybe(:string).description("Optional reason for deletion, e.g., 'duplicate' or 'API/operator'.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  # Needed as actual argument manifest/publication, otherwise the LLM will not figure out the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: {
        relation_id: { type: "integer", description: "The ID of the relation to delete." },
        reason: { type: "string", description: "Optional reason for deletion, e.g., 'duplicate' or 'API/operator'." }
      },
      required: [ "relation_id" ]
    }
  end

  # Output: Success message object

  def call(relation_id:, reason: nil)
    logger.info "Performing DeleteRelationTool with relation_id: #{relation_id}, reason: #{reason}"
    begin
      GraphDeleteService.execute_one(
        "delete_relation",
        relation_id: relation_id,
        reason: reason
      )
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue ActiveRecord::RecordNotDestroyed => e
      error_message = "Failed to delete relation with ID=#{relation_id}."
      logger.error "OperationFailed in DeleteRelationTool: #{error_message} (#{e.class}: #{e.message})"
      raise McpGraphMemErrors::OperationFailed.new(
        error_message,
        next_move: "Call `traverse_graph` or `get_entities` to confirm the relation, then retry `graph_delete`."
      )
    rescue StandardError => e
      logger.error "InternalServerError in DeleteRelationTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

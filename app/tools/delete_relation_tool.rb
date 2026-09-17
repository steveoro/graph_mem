# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_relation"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Delete one graph edge by id without deleting either entity. Pass required `relation_id` (integer); " \
    "optional `reason` (string, audit log). Do not use if you lack a relation_id; use `traverse_graph` first. " \
    "Do not use to remove an entity and its relations; use `delete_entity` instead. " \
    "Do not use for queued duplicate-relation cleanup; use `apply_maintenance_review` instead. " \
    "Do not use to add an edge; use `create_relation` instead."

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
      relation = MemoryRelation.find_by(id: relation_id)
      unless relation
        raise McpGraphMemErrors::ResourceNotFound.new(
          "Relation with ID=#{relation_id} not found.",
          next_move: "Call `traverse_graph` or `get_entities` to obtain a relation_id, then retry `delete_relation`."
        )
      end

      relation_attributes = relation.attributes # Capture attributes before destroy
      begin
        Current.deletion_reason = reason
        relation.destroy!
      ensure
        Current.deletion_reason = nil
      end

      # Return the attributes of the deleted relation as a simple hash, plus a success message
      {
        relation_id: relation_attributes["id"],
        from_entity_id: relation_attributes["from_entity_id"],
        to_entity_id: relation_attributes["to_entity_id"],
        relation_type: relation_attributes["relation_type"],
        weight: relation_attributes["weight"],
        confidence: relation_attributes["confidence"],
        properties: relation_attributes["properties"] || {},
        created_at: relation_attributes["created_at"].iso8601(3),
        updated_at: relation_attributes["updated_at"].iso8601(3),
        message: "Relation with ID=#{relation_id} deleted successfully."
      }
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
      raise
    rescue ActiveRecord::RecordNotDestroyed => e
      error_message = "Failed to delete relation with ID=#{relation_id}."
      logger.error "OperationFailed in DeleteRelationTool: #{error_message} (#{e.class}: #{e.message})"
      raise McpGraphMemErrors::OperationFailed.new(
        error_message,
        next_move: "Call `traverse_graph` or `get_entities` to confirm the relation, then retry `delete_relation`."
      )
    rescue StandardError => e
      logger.error "InternalServerError in DeleteRelationTool: #{e.class}: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end

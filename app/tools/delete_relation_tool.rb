# frozen_string_literal: true

class DeleteRelationTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "delete_relation"
  end

  description "Delete a specific relation by ID."

  arguments do
    required(:relation_id).filled(:integer).description("The ID of the relation to delete.")
  end

  # Defines the input schema for this tool. Overrides the shared behavior from ApplicationTool
  # Needed as actual argument manifest/publication, otherwise the LLM will not figure out the input schema for this tool.
  def input_schema_to_json
    {
      type: "object",
      properties: { relation_id: { type: "integer", description: "The ID of the relation to delete." } },
      required: [ "relation_id" ]
    }
  end

  # Output: Success message object

  def call(relation_id:)
    logger.info "Performing DeleteRelationTool with relation_id: #{relation_id}"
    begin
      # Find and destroy the relation
      relation = MemoryRelation.find(relation_id)
      relation_attributes = relation.attributes # Capture attributes before destroy
      relation.destroy!

      # Return the attributes of the deleted relation as a simple hash, plus a success message
      {
        relation_id: relation_attributes["id"],
        from_entity_id: relation_attributes["from_entity_id"],
        to_entity_id: relation_attributes["to_entity_id"],
        relation_type: relation_attributes["relation_type"],
        created_at: relation_attributes["created_at"].iso8601(3),
        updated_at: relation_attributes["updated_at"].iso8601(3),
        message: "Relation with ID=#{relation_id} deleted successfully."
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Relation with ID=#{relation_id} not found."
      logger.error "ResourceNotFound in DeleteRelationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound, error_message
    rescue ActiveRecord::RecordNotDestroyed => e
      error_message = "Failed to delete relation with ID=#{relation_id}: #{e.message}"
      logger.error "OperationFailed in DeleteRelationTool: #{error_message}"
      raise McpGraphMemErrors::OperationFailed, error_message
    rescue StandardError => e
      logger.error "InternalServerError in DeleteRelationTool: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in DeleteRelationTool: #{e.message}"
    end
  end
end

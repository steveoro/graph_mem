# frozen_string_literal: true

class DeleteEntityTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'delete_entity'
  end

  description "Delete an entity from the graph memory database."

  tool_input_schema({
    type: "object",
    properties: {
      entity_id: {
        type: "string",
        description: "The ID of the entity to delete."
      }
    },
    required: ["entity_id"]
  })

  # Output: Success message object

  def call(entity_id:)
    logger.info "Deleting entity with ID: #{entity_id}"

    # Validate inputs
    return validation_error("Entity ID cannot be blank") if entity_id.blank?

    # Find the entity
    entity = MemoryEntity.find_by(id: entity_id)
    return not_found_error("Entity", entity_id) unless entity

    entity_name = entity.name
    entity.destroy!

    logger.info "Deleted entity: #{entity_name} (ID: #{entity_id})"

    result = {
      message: "Entity '#{entity_name}' deleted successfully",
      deleted_entity_id: entity_id
    }

    success_response(result)
  rescue StandardError => e
    logger.error "Error in DeleteEntityTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An internal server error occurred while deleting the entity: #{e.message}")
  end
end

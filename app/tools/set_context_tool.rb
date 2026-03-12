# frozen_string_literal: true

class SetContextTool < ApplicationTool
  def self.tool_name
    "set_context"
  end

  description "Set the active project context. Subsequent search operations will prioritize entities related to this project."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to set as the active context.")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: {
        entity_id: { type: "integer", description: "The ID of the entity to set as the active context." }
      },
      required: [ "entity_id" ]
    }
  end

  def call(entity_id:)
    entity = MemoryEntity.find_by(id: entity_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound, "Entity with ID #{entity_id} not found."
    end

    GraphMemContext.current_project_id = entity_id

    {
      status: "context_set",
      entity_id: entity.id,
      entity_name: entity.name,
      entity_type: entity.entity_type
    }
  rescue McpGraphMemErrors::ResourceNotFound
    raise
  rescue StandardError => e
    logger.error "SetContextTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end

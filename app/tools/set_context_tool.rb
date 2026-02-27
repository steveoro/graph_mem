# frozen_string_literal: true

class SetContextTool < ApplicationTool
  def self.tool_name
    "set_context"
  end

  description "Set the active project context. Subsequent search operations will prioritize entities related to this project."

  arguments do
    required(:project_id).filled(:integer).description("The ID of the project entity to scope to.")
  end

  def input_schema_to_json
    {
      type: "object",
      properties: {
        project_id: { type: "integer", description: "The ID of the project entity to scope to." }
      },
      required: [ "project_id" ]
    }
  end

  def call(project_id:)
    entity = MemoryEntity.find_by(id: project_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound, "Entity with ID #{project_id} not found."
    end

    GraphMemContext.current_project_id = project_id

    {
      status: "context_set",
      project_id: entity.id,
      project_name: entity.name,
      project_type: entity.entity_type
    }
  rescue McpGraphMemErrors::ResourceNotFound
    raise
  rescue StandardError => e
    logger.error "SetContextTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end

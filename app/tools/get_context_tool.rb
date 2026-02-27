# frozen_string_literal: true

class GetContextTool < ApplicationTool
  def self.tool_name
    "get_context"
  end

  description "Get the currently active project context, if any."

  def call
    project_id = GraphMemContext.current_project_id

    unless project_id
      return { status: "no_context", message: "No project context is currently set." }
    end

    entity = MemoryEntity.find_by(id: project_id)
    unless entity
      GraphMemContext.clear!
      return { status: "context_cleared", message: "Previously set project (ID #{project_id}) no longer exists. Context cleared." }
    end

    {
      status: "context_active",
      project_id: entity.id,
      project_name: entity.name,
      project_type: entity.entity_type,
      description: entity.description
    }
  rescue StandardError => e
    logger.error "GetContextTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end

# frozen_string_literal: true

class GetContextTool < ApplicationTool
  def self.tool_name
    "get_context"
  end

  description "Get the currently active project context, if any."

  def call
    context = graph_mem_context
    project_id = context.current_project_id

    unless project_id
      return { status: "no_context", message: "No project context is currently set." }
    end

    entity = MemoryEntity.find_by(id: project_id)
    unless entity
      context.clear!
      return { status: "context_cleared", message: "Previously set project (ID #{project_id}) no longer exists. Context cleared." }
    end

    scope = context.scoped_entity_scope

    {
      status: "context_active",
      entity_id: entity.id,
      entity_name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      scope_entity_count: scope.entity_ids.size,
      scope_truncated: scope.truncated,
      scope_max_entities: scope.max_entities
    }
  rescue StandardError => e
    logger.error "GetContextTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end

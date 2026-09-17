# frozen_string_literal: true

class GetContextTool < ApplicationTool
  def self.tool_name
    "get_context"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Read this MCP client's active project context (entity and scope fields, or status no_context); " \
    "auto-clears if the project entity is gone. Takes no arguments. " \
    "Do not use to activate or switch projects; use `set_context` instead. " \
    "Do not use to wipe context so searches span all projects; use `clear_context` instead. " \
    "Do not use to load an entity's observations or relations; use `get_entity` instead."

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
      context_set_at: context.context_set_at&.iso8601,
      scope_entity_count: scope.entity_ids.size,
      scope_truncated: scope.truncated,
      scope_max_entities: scope.max_entities
    }.merge(shared_client_id_warning || {})
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "GetContextTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

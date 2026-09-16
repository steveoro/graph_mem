# frozen_string_literal: true

class SetContextTool < ApplicationTool
  def self.tool_name
    "set_context"
  end

  description "Set this MCP client's active project so `search_entities` and `search_subgraph` boost in-context " \
    "entities without hard-filtering results. Pass required `entity_id` (integer; also accepts an entity-name string). " \
    "Do not use to read the current project; use `get_context` instead. " \
    "Do not use to search across all projects; use `clear_context` instead. " \
    "Do not use to change entity fields or create a project; use `update_entity` or `create_entity` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to set as the active context.")
  end

  def call(entity_id:)
    entity = MemoryEntity.find_by(id: entity_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Entity with ID=#{entity_id} not found.",
        next_move: "Call `search_entities` to find a valid entity id, then retry `set_context`."
      )
    end

    displaced = graph_mem_context.set_project!(entity_id)

    {
      status: "context_set",
      entity_id: entity.id,
      entity_name: entity.name,
      entity_type: entity.entity_type
    }.merge(shared_client_id_warning(displaced_project: displaced) || {})
  rescue McpGraphMemErrors::ResourceNotFound
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "SetContextTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

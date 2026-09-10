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
      raise McpGraphMemErrors::ResourceNotFound, "Entity with ID #{entity_id} not found."
    end

    graph_mem_context.current_project_id = entity_id

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

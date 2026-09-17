# frozen_string_literal: true

class MergeEntitiesTool < ApplicationTool
  def self.tool_name
    "merge_entities"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Merge a source entity into a target: transfer observations, re-parent relations, add the source name " \
    "to target aliases, then delete the source. Pass required `source_entity_id` and `target_entity_id` (integers). " \
    "Do not use to find merge candidates; use `suggest_merges` instead. " \
    "Do not use to apply a queued review by item_id; use `apply_maintenance_review` instead. " \
    "Do not use to destroy an entity without transferring knowledge; use `graph_delete` instead."

  arguments do
    required(:source_entity_id).filled(:integer)
      .description("The entity to merge from (will be deleted).")
    required(:target_entity_id).filled(:integer)
      .description("The entity to merge into (will be kept).")
  end

  def call(source_entity_id:, target_entity_id:)
    GraphDeleteService.execute_one(
      "merge_entities",
      source_entity_id: source_entity_id,
      target_entity_id: target_entity_id
    )
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "MergeEntitiesTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

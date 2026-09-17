# frozen_string_literal: true

class GraphEditTool < ApplicationTool
  MAX_OPERATIONS = GraphMutationBatch::MAX_OPERATIONS

  def self.tool_name
    "graph_edit"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Atomically edit graph data with up to #{MAX_OPERATIONS} type-discriminated `operations`. " \
    "Use update_entity with entity_id and metadata fields, or update_observation with observation_id, fields, " \
    "and optional supersede/reason. Every operation rolls back if any operation fails. " \
    "Do not use to create data; use `graph_write` instead. " \
    "Do not use to obsolete, delete, or merge data; use `graph_delete` instead."

  arguments do
    required(:operations).array(:hash).description("update_entity or update_observation operations.")
  end

  def call(operations:)
    GraphEditService.call(operations: operations)
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "GraphEditTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

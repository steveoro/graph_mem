# frozen_string_literal: true

class GraphDeleteTool < ApplicationTool
  MAX_OPERATIONS = GraphMutationBatch::MAX_OPERATIONS

  def self.tool_name
    "graph_delete"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    read_only_hint: false,
    destructive_hint: true,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Atomically remove or merge graph data with up to #{MAX_OPERATIONS} type-discriminated `operations`. " \
    "Supported types are delete_entity, delete_observation (marks obsolete), delete_relation, and merge_entities. " \
    "Hard deletes accept per-operation reason; merge preserves duplicate audit semantics. Every operation rolls back " \
    "if any operation fails. Do not use to create data; use `graph_write` instead. " \
    "Do not use to update retained data; use `graph_edit` instead."

  arguments do
    required(:operations).array(:hash).description(
      "delete_entity, delete_observation, delete_relation, or merge_entities operations."
    )
  end

  def call(operations:)
    GraphDeleteService.call(operations: operations)
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue McpGraphMemErrors::Error, FastMcp::Tool::InvalidArgumentsError
    raise
  rescue StandardError => e
    logger.error "GraphDeleteTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

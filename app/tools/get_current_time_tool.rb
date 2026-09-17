# frozen_string_literal: true

class GetCurrentTimeTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "get_current_time"
  end

  mcp_metadata(
    profiles: %i[default readonly maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Return the current server time as an ISO 8601 string. Takes no arguments; software version is " \
    "included in every successful response. " \
    "Do not use for graph health metrics; use `get_graph_stats` instead. " \
    "Do not use to set observation validity windows; use `graph_write` or `graph_edit` instead."

  # No arguments are needed for this tool.

  # Execute the tool's logic
  # @return [Hash] The output of the tool.
  def call
    { timestamp: Time.now.utc.iso8601 }
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "InternalServerError in GetCurrentTimeTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end
end

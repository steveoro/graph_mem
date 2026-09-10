# frozen_string_literal: true

class ClearContextTool < ApplicationTool
  def self.tool_name
    "clear_context"
  end

  description "Remove this MCP client's active project context so searches are unscoped across all projects; " \
    "does not delete entities. Takes no arguments. " \
    "Do not use to inspect the current scope; use `get_context` instead. " \
    "Do not use to switch to a project; use `set_context` instead. " \
    "Do not use to delete a project or other entity; use `delete_entity` instead."

  def call
    context = graph_mem_context
    was_set = context.current_project_id.present?
    context.clear!

    {
      status: "context_cleared",
      was_active: was_set
    }
  rescue StandardError => e
    logger.error "ClearContextTool error: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, e.message
  end
end

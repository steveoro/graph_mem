# frozen_string_literal: true

class ClearContextTool < ApplicationTool
  def self.tool_name
    "clear_context"
  end

  description "Clear the currently active project context. Searches will return results across all projects."

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

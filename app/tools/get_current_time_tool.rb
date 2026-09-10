# frozen_string_literal: true

class GetCurrentTimeTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "get_current_time"
  end

  description "Return the current server time as an ISO 8601 string. Takes no arguments. " \
    "Do not use for software version; use `get_version` instead. " \
    "Do not use for graph health metrics; use `get_graph_stats` instead. " \
    "Do not use to set observation validity windows; use `create_observation` or `update_observation` instead."

  # No arguments are needed for this tool.

  # Defines the output schema for this tool as an instance method.
  # While not always strictly required by FastMcp for execution,
  # it's good practice for documentation and potential future use.
  def tool_output_schema
    {
      type: "object",
      properties: {
        timestamp: {
          type: "string",
          format: "date-time",
          description: "The current server time in ISO 8601 format."
        }
      },
      required: [ "timestamp" ]
    }
  end

  # Execute the tool's logic
  # @return [Hash] The output of the tool (conforming to tool_output_schema).
  def call
    { timestamp: Time.now.utc.iso8601 }
  rescue StandardError => e
    logger.error "InternalServerError in GetCurrentTimeTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "Error in GetCurrentTimeTool: #{e.message}"
  end
end

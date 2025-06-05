# frozen_string_literal: true

class GetCurrentTimeTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'get_current_time'
  end

  description 'Returns the current server time as an ISO 8601 string.'

  # No input arguments needed for this tool
  tool_input_schema({
    type: "object",
    properties: {},
    required: []
  })


  def self.call(**args)
    result = { timestamp: Time.now.utc.iso8601 }
    Rails.logger.info "GetCurrentTimeTool executed successfully"

    MCP::Tool::Response.new([{
      type: "text",
      text: result.to_json
    }])
  rescue StandardError => e
    Rails.logger.error "Error in GetCurrentTimeTool: #{e.message} - #{e.backtrace.join("\n")}"

    MCP::Tool::Response.new([{
      type: "text",
      text: "Error: An error occurred while getting the current time: #{e.message}"
    }])
  end
end

# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  attr_accessor :server # Allow server instance to be set on tool instances

  # write your custom logic to be shared across all tools here

  def logger
    Rails.logger
  end

  def tool_name
    self.class.tool_name
  end
end

# frozen_string_literal: true

module GraphMem
  # Raised when a tool's arguments don't match its schema (or are otherwise invalid input); the MCP
  # layer answers it with the ToolError envelope, category "validation".
  class InvalidArgumentsError < StandardError; end
end

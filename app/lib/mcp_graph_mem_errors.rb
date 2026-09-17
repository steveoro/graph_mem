# frozen_string_literal: true

# Custom error classes for the GraphMem MCP application.
# Each error carries routing metadata (category, retriable, next_move) that
# ToolError serializes into the MCP isError envelope.
module McpGraphMemErrors
  class Error < StandardError
    CATEGORY = "system_error"
    RETRIABLE = false
    NEXT_MOVE = "Escalate to a human. Do not retry blindly."

    attr_reader :category, :retriable, :next_move

    def initialize(message = nil, category: nil, retriable: nil, next_move: nil)
      super(message)
      @category = category || self.class::CATEGORY
      @retriable = retriable.nil? ? self.class::RETRIABLE : retriable
      @next_move = next_move || self.class::NEXT_MOVE
    end
  end

  # Raised when a resource (e.g., an ActiveRecord model) cannot be found.
  class ResourceNotFound < Error
    CATEGORY = "not_found"
    NEXT_MOVE = "Call `search` to verify the identifier, then retry with a known id."
  end

  # Raised when an operation fails for reasons other than missing records or invalid arguments.
  class OperationFailed < Error
    CATEGORY = "system_error"
    NEXT_MOVE = "Escalate to a human. Do not retry blindly."
  end

  # Raised for unexpected internal failures.
  class InternalServerError < Error
    CATEGORY = "system_error"
    NEXT_MOVE = "Escalate to a human. Do not retry blindly."
  end
end

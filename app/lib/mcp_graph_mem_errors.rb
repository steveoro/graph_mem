# frozen_string_literal: true

# Custom error classes for the GraphMem MCP application
module McpGraphMemErrors
  class Error < StandardError; end

  # Raised when a resource (e.g., an ActiveRecord model) cannot be found.
  # Corresponds to situations like ActiveRecord::RecordNotFound.
  class ResourceNotFound < McpGraphMemErrors::Error; end

  # Raised when an operation (e.g., creating or destroying a record) fails for reasons other than validation.
  # Corresponds to situations like ActiveRecord::RecordNotSaved, ActiveRecord::RecordNotDestroyed.
  class OperationFailed < McpGraphMemErrors::Error; end

  # Raised for general internal server errors not fitting other categories.
  class InternalServerError < McpGraphMemErrors::Error; end
end

# frozen_string_literal: true

# Custom error classes for the GraphMem MCP application.
# Each error carries routing metadata (category, retriable, next_move) that
# ToolError serializes into the MCP isError envelope.
module McpGraphMemErrors
  class Error < StandardError
    CATEGORY = "system_error"
    RETRIABLE = false
    NEXT_MOVE = "Escalate to a human. Do not retry blindly."

    attr_reader :category, :retriable, :next_move, :code

    # @param message [String, nil]
    # @param category [String, nil] envelope category; defaults to the class's CATEGORY
    # @param retriable [Boolean, nil] defaults to the class's RETRIABLE
    # @param next_move [String, nil] defaults to the class's NEXT_MOVE
    # @param code [String, Symbol, nil] optional machine-readable reason, added to the envelope as `code`
    def initialize(message = nil, category: nil, retriable: nil, next_move: nil, code: nil)
      super(message)
      @category = category || self.class::CATEGORY
      @retriable = retriable.nil? ? self.class::RETRIABLE : retriable
      @next_move = next_move || self.class::NEXT_MOVE
      @code = code&.to_s
    end
  end

  # Raised when the arguments are well-formed but refused by a policy the caller can act on
  # (e.g. a scan folder outside the scan filter). Carries a `code` naming the reason.
  class InvalidArguments < Error
    CATEGORY = "validation"
    NEXT_MOVE = "Correct the argument format required by the tool schema and retry."
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

  # Raised when a name resolves to entities in several projects and no
  # project context disambiguates it. The message lists every candidate
  # (entity_id, name, entity_type, project_id) so the caller can retry
  # with an explicit entity_id — resolution never guesses.
  class AmbiguousReference < Error
    CATEGORY = "ambiguous_name"
    NEXT_MOVE = "Call `set_context` with the intended project, or retry with the numeric entity_id of the candidate you meant."

    def initialize(name, candidates)
      list = candidates.map { |c| "{entity_id: #{c.id}, name: #{c.name.inspect}, entity_type: #{c.entity_type.inspect}, project_id: #{c.project_id.inspect}}" }
      super("Name '#{name}' is ambiguous — declared in #{candidates.size} projects: #{list.join(', ')}")
    end
  end
end

# frozen_string_literal: true

require "json"
require "timeout"
require "net/http"

# Maps tool exceptions to the structured MCP error envelope.
class ToolError
  ENVELOPE_KEYS = %w[error category retriable next_move message tool].freeze

  CATEGORY_NOT_FOUND = "not_found"
  CATEGORY_VALIDATION = "validation"
  CATEGORY_PERMISSION = "permission"
  CATEGORY_TIMEOUT = "timeout"
  CATEGORY_RATE_LIMIT = "rate_limit"
  CATEGORY_SYSTEM = "system_error"

  NAME_NOT_FOUND = /entity not found by name/i

  DEFAULT_NEXT_MOVES = {
    CATEGORY_NOT_FOUND => "Call `search_entities` or `list_entities` to verify the identifier, then retry with a known id.",
    CATEGORY_VALIDATION => "Correct the argument format required by the tool schema and retry.",
    CATEGORY_PERMISSION => "Escalate to a human. This client is not authorized to call this tool.",
    CATEGORY_TIMEOUT => "Retry the tool once, then inform the user of the delay.",
    CATEGORY_RATE_LIMIT => "Wait and retry with backoff.",
    CATEGORY_SYSTEM => "Escalate to a human. Do not retry blindly."
  }.freeze

  TIMEOUT_CLASSES = [
    Timeout::Error,
    (Net::OpenTimeout if defined?(Net::OpenTimeout)),
    (Net::ReadTimeout if defined?(Net::ReadTimeout))
  ].compact.freeze

  class << self
    def envelope(error, tool_name: nil)
      category = category_for(error)
      {
        "error" => true,
        "category" => category,
        "retriable" => retriable_for(error, category),
        "next_move" => next_move_for(error, category),
        "message" => message_for(error),
        "tool" => tool_name
      }
    end

    def dump(error, tool_name: nil)
      JSON.generate(envelope(error, tool_name: tool_name))
    end

    def dump_unauthorized(tool_name: nil)
      JSON.generate(
        {
          "error" => true,
          "category" => CATEGORY_PERMISSION,
          "retriable" => false,
          "next_move" => DEFAULT_NEXT_MOVES[CATEGORY_PERMISSION],
          "message" => "Unauthorized",
          "tool" => tool_name
        }
      )
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    private

    def category_for(error)
      return error.category if error.respond_to?(:category) && error.category.present?
      return CATEGORY_TIMEOUT if timeout?(error)
      return CATEGORY_NOT_FOUND if name_not_found?(error)
      return CATEGORY_VALIDATION if validation?(error)

      CATEGORY_SYSTEM
    end

    def retriable_for(error, category)
      return error.retriable if error.is_a?(McpGraphMemErrors::Error)

      category.in?([ CATEGORY_TIMEOUT, CATEGORY_RATE_LIMIT ])
    end

    def next_move_for(error, category)
      custom = error.next_move if error.respond_to?(:next_move)
      return custom if custom.present?

      DEFAULT_NEXT_MOVES.fetch(category, DEFAULT_NEXT_MOVES[CATEGORY_SYSTEM])
    end

    def message_for(error)
      if error.is_a?(McpGraphMemErrors::Error) || validation?(error) || timeout?(error)
        error.message.to_s
      else
        "An unexpected error occurred."
      end
    end

    def validation?(error)
      error.is_a?(FastMcp::Tool::InvalidArgumentsError)
    end

    def name_not_found?(error)
      validation?(error) && error.message.to_s.match?(NAME_NOT_FOUND)
    end

    def timeout?(error)
      TIMEOUT_CLASSES.any? { |klass| error.is_a?(klass) }
    end
  end
end

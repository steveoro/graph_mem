# frozen_string_literal: true

module Llm
  # Whether a cloud answer to a JSON task has the structure its caller parses (agent-CLI PR5). It is
  # structural only: the callers keep their own domain checks. Llm::CloudCall uses it to retry a
  # wrong-shaped answer once; Ollama answers are never checked.
  #
  #   Llm::JsonShape.valid?(:scan, '{"architecture": []}')      # => true
  #   Llm::JsonShape.valid?(:judge, '{"verdicts": [], "n": 2}')  # => true (one array value)
  #   Llm::JsonShape.valid?(:judge, '"ok"')                      # => false
  module JsonShape
    TASKS = %i[scan judge].freeze

    module_function

    # @param task [Symbol]
    # @return [Boolean] whether answers to the task are checked
    def checked?(task)
      TASKS.include?(task)
    end

    # @param task [Symbol] :scan (one JSON object, what ExtractionPrompt asks for) or :judge (an
    #   array, or an object whose only Array value is the list, what FactSupersede::Judge parses)
    # @param text [String, nil] the (masked, normalized) answer
    # @return [Boolean]
    def valid?(task, text)
      doc = JSON.parse(text.to_s)
      case task
      when :scan then doc.is_a?(Hash)
      when :judge then doc.is_a?(Array) || (doc.is_a?(Hash) && doc.values.count { |value| value.is_a?(Array) } == 1)
      else true
      end
    rescue JSON::ParserError, TypeError
      false
    end
  end
end

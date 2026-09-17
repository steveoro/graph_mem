# frozen_string_literal: true

module GraphMutationBatch
  MAX_OPERATIONS = 50

  module_function

  # Converts external operation hashes into the indexed internal representation.
  #
  # @param operations [Array<#to_h>, nil] type-discriminated operation objects
  # @return [Array<Hash>] hashes containing `index`, normalized `type`, and
  #   symbol-keyed `attributes`
  def normalize_operations(operations)
    Array(operations).map.with_index do |operation, index|
      attributes = operation.to_h.deep_symbolize_keys
      type = attributes.delete(:type).to_s.strip.downcase
      attributes.delete(:index)
      { index: index, type: type, attributes: attributes }
    end
  end

  # Validates batch presence, size, and operation discriminators.
  #
  # @param operations [Array<Hash>] normalized operations
  # @param allowed_types [Array<String>] accepted discriminator values
  # @param tool_name [String] canonical tool name used in error messages
  # @return [void]
  # @raise [FastMcp::Tool::InvalidArgumentsError] when validation fails
  def validate_operations!(operations, allowed_types:, tool_name:)
    if operations.empty?
      raise FastMcp::Tool::InvalidArgumentsError,
            "#{tool_name} requires at least one operation."
    end
    if operations.size > MAX_OPERATIONS
      raise FastMcp::Tool::InvalidArgumentsError,
            "#{tool_name} accepts at most #{MAX_OPERATIONS} operations; received #{operations.size}."
    end

    operations.each do |operation|
      next if operation[:type].in?(allowed_types)

      raise FastMcp::Tool::InvalidArgumentsError,
            "#{tool_name} operation[#{operation[:index]}] has unknown type #{operation[:type].inspect}; " \
            "expected one of: #{allowed_types.join(', ')}."
    end
  end

  # Executes one normalized operation and adds its type/index to known errors.
  #
  # @param operation [Hash] normalized operation from `.normalize_operations`
  # @yieldparam attributes [Hash] operation-specific attributes
  # @return [Object] the block result
  # @raise [FastMcp::Tool::InvalidArgumentsError, McpGraphMemErrors::Error]
  #   with indexed context while preserving the original error category
  def execute(operation)
    yield(operation[:attributes])
  rescue FastMcp::Tool::InvalidArgumentsError => e
    raise FastMcp::Tool::InvalidArgumentsError,
          "#{operation[:type]}[#{operation[:index]}]: #{e.message}"
  rescue McpGraphMemErrors::Error => e
    raise e.class.new(
      "#{operation[:type]}[#{operation[:index]}]: #{e.message}",
      category: e.category,
      retriable: e.retriable,
      next_move: e.next_move
    )
  rescue ActiveRecord::RecordInvalid => e
    raise FastMcp::Tool::InvalidArgumentsError,
          "#{operation[:type]}[#{operation[:index]}]: #{e.record.errors.full_messages.join(', ')}"
  rescue ActiveRecord::RecordNotFound => e
    raise McpGraphMemErrors::ResourceNotFound,
          "#{operation[:type]}[#{operation[:index]}]: #{e.message}"
  rescue ActiveRecord::RecordNotUnique => e
    raise McpGraphMemErrors::OperationFailed.new(
      "#{operation[:type]}[#{operation[:index]}]: #{e.message}",
      category: "validation"
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    raise McpGraphMemErrors::OperationFailed,
          "#{operation[:type]}[#{operation[:index]}]: #{e.message}"
  end

  # Wraps an operation payload for a canonical batch response.
  #
  # @param operation [Hash] normalized operation containing `index` and `type`
  # @param payload [Object] operation-specific result
  # @return [Hash] `{ index:, type:, result: payload }`
  def result(operation, payload)
    {
      index: operation[:index],
      type: operation[:type],
      result: payload
    }
  end
end

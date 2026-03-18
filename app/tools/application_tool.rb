# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  attr_accessor :server

  class << self
    # Provide a default schema JSON for tools that don't use the arguments DSL
    # (e.g. VersionTool, GetCurrentTimeTool). FastMcp returns nil when no
    # arguments block is defined; handle_tools_list needs a valid hash.
    def input_schema_to_json
      super || { type: "object", properties: {}, required: [] }
    end
  end

  # Normalize incoming parameters (camelCase, entity names, operations array)
  # before schema validation and dispatch.
  def call_with_schema_validation!(**args)
    normalized = ParameterNormalizer.normalize(tool_name, args)
    arg_validation = self.class.input_schema.call(normalized)
    if arg_validation.errors.any?
      raise FastMcp::Tool::InvalidArgumentsError, arg_validation.errors.to_h.to_json
    end
    [ call(**normalized), _meta ]
  end

  def call(...)
    Current.actor = "mcp:#{tool_name}"
    super
  end

  def logger
    Rails.logger
  end

  def tool_name
    self.class.tool_name
  end

  def description
    if self.class.respond_to?(:description)
      self.class.description
    else
      "#{tool_name} - A general purpose tool."
    end
  end
end

# frozen_string_literal: true

class ApplicationTool < FastMcp::Tool
  attr_accessor :server # Allow server instance to be set on tool instances

  class << self
    # Centralized input schema definition for schema validation
    # This is called by FastMcp::Tool#call_with_schema_validation! via self.class.input_schema
    def input_schema
      if respond_to?(:schema) && (dsl_schema = schema)
        # If the specific tool class (e.g., ListEntitiesTool) has defined 'arguments',
        # it will have a 'schema' class method returning the Dry::Schema::Processor.
        dsl_schema
      else
        # Default for tools that don't use the 'arguments' DSL
        # (e.g., VersionTool, GetCurrentTimeTool)
        Dry::Schema.JSON
      end
    end
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

  # Expected by FastMcp::Server for tools/list
  def description
    if self.class.respond_to?(:description)
      self.class.description
    else
      "#{tool_name} - A general purpose tool."
    end
  end

  # Expected by FastMcp::Server for tools/list
  def input_schema_to_json
    # Corresponds to `tool.input_schema_to_json || { type: 'object', properties: {}, required: [] }`
    # in FastMcp::Server#handle_tools_list
    # Individual tools can override this if they have a specific input schema.
    if self.class.respond_to?(:tool_input_schema)
      self.class.tool_input_schema
    else
      { type: "object", properties: {}, required: [] }
    end
  end

  # Optional: Convenience class method for tools to define their description
  def self.tool_description(desc = nil)
    @tool_description = desc if desc
    @tool_description || "#{tool_name} - A general purpose tool."
  end

  # Optional: Convenience class method for tools to define their input schema
  def self.tool_input_schema(schema = nil)
    @tool_input_schema = schema if schema
    @tool_input_schema || { type: "object", properties: {}, required: [] }
  end
end

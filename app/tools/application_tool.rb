# frozen_string_literal: true

require 'mcp'

# Base class for graph_mem tools - inherits directly from MCP::Tool
class ApplicationTool < MCP::Tool
  class << self
    # Tool name - must be implemented by subclasses
    def tool_name
      raise NotImplementedError, "Subclasses must implement tool_name"
    end

    # Tool description - can be overridden by subclasses
    def description_text
      "#{tool_name} - A general purpose tool."
    end

    # Tool input schema in JSON Schema format
    def tool_input_schema
      { type: "object", properties: {}, required: [] }
    end
  end

  # Access to Rails logger
  def logger
    Rails.logger
  end

  def tool_name
    self.class.tool_name
  end

  # Expected by the conversion layer
  def description
    self.class.description
  end

  # Expected by the conversion layer
  def input_schema_to_json
    self.class.tool_input_schema
  end

  # Main tool execution method - must be implemented by subclasses
  def call(*args)
    raise NotImplementedError, "Subclasses must implement call method"
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

  # DSL method to define description
  def self.description(desc = nil)
    @description = desc if desc
    @description || tool_description
  end

  protected

  # Helper method to format successful responses
  def success_response(data)
    if data.is_a?(Hash)
      data.to_json
    elsif data.is_a?(String)
      data
    else
      data.to_s
    end
  end

  # Helper method to format error responses
  def error_response(message)
    { error: message }.to_json
  end

  # Helper method for validation errors
  def validation_error(message)
    error_response("Validation Error: #{message}")
  end

  # Helper method for not found errors
  def not_found_error(resource, identifier = nil)
    msg = identifier ? "#{resource} with identifier '#{identifier}' not found" : "#{resource} not found"
    error_response(msg)
  end
end

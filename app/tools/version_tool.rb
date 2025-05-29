# frozen_string_literal: true

class VersionTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'get_version'
  end

  description "Returns the current Graph-Memory backend implementation version"

  # No arguments are needed for this tool.
  # def self.input_schema
  #   Dry::Schema.JSON
  # end

  def call
    begin
      { version: GraphMem::VERSION.to_s }
    rescue NameError => e
      # This handles the case where GraphMem::VERSION might not be defined
      logger.error "Version constant not found: #{e.message}"
      raise McpGraphMemErrors::InternalServerError, "Version information is currently unavailable."
    rescue => e
      logger.error "Unexpected error in VersionTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "Internal Server Error: #{e.message}"
    end
  end
end

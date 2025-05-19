# frozen_string_literal: true

class VersionTool < ApplicationTool
  description "Returns the current Graph-Memory backend version"

  # No arguments are needed for this tool.

  def call
    begin
      { version: GraphMem::VERSION.to_s }
    rescue NameError => e
      # This handles the case where GraphMem::VERSION might not be defined
      logger.error "Version constant not found: #{e.message}"
      raise FastMcp::Errors::InternalError, "Version information is currently unavailable."
    rescue => e
      logger.error "Unexpected error in VersionTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end

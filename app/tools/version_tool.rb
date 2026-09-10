# frozen_string_literal: true

class VersionTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    "get_version"
  end

  description "Return the GraphMem server software version as {version: string}. Takes no arguments. " \
    "Do not use for wall-clock time; use `get_current_time` instead. " \
    "Do not use for graph health metrics; use `get_graph_stats` instead. " \
    "Do not use for compaction job status; use `dream_state_status` instead."

  # No arguments are needed for this tool.

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

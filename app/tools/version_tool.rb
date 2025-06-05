# frozen_string_literal: true

class VersionTool < ApplicationTool
  # Provide a custom tool name:
  def self.tool_name
    'version'
  end

  description 'Returns the current version of the GraphMem server.'

  tool_input_schema({
    type: "object",
    properties: {},
    required: []
  })

  def call
    version = defined?(GraphMem::VERSION) ? GraphMem::VERSION.to_s : '0.6.2'
    result = {
      version: version,
      server_name: 'graph-mem',
      ruby_version: RUBY_VERSION,
      rails_version: Rails.version
    }

    logger.info "VersionTool executed successfully"
    success_response(result)
  rescue StandardError => e
    logger.error "Error in VersionTool: #{e.message} - #{e.backtrace.join("\n")}"
    error_response("An error occurred while getting version information: #{e.message}")
  end
end

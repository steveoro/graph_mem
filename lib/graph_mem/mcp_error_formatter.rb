# frozen_string_literal: true

module GraphMem
  # Adapts GraphMem's ToolError envelope to FastMCP's error formatter hook.
  class McpErrorFormatter
    # Installs the GraphMem error envelope on a FastMCP server.
    #
    # @param server [FastMcp::Server]
    # @return [FastMcp::Server]
    def self.install(server)
      server.error_formatter do |message:, tool_name:, error:|
        call(message: message, tool_name: tool_name, error: error)
      end
      server
    end

    # Formats one failed or unauthorized tool call.
    #
    # @param message [String] fallback message when no exception is available
    # @param tool_name [String, nil] protocol tool name
    # @param error [Exception, nil] failure supplied by FastMCP
    # @return [String] JSON-encoded ToolError envelope
    def self.call(message:, tool_name:, error:)
      if error.is_a?(FastMcp::Server::UnauthorizedError)
        ToolError.dump_unauthorized(tool_name: tool_name)
      else
        ToolError.dump(error || StandardError.new(message), tool_name: tool_name)
      end
    end
  end
end

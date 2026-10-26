# frozen_string_literal: true

require "mcp"

module GraphMem
  # graph_mem's MCP layer on the official MCP Ruby SDK (`mcp` gem); see
  # docs/guides/migrating-fast-mcp-to-mcp-gem.md.
  module OfficialMcp
    # Errors on the gem's own -32603 path (tool errors are answered by ToolWrapper instead).
    EXCEPTION_REPORTER = lambda do |exception, context|
      Rails.error.report(exception, handled: true, context: { mcp: context.to_h })
    end

    # The configuration shared by every graph_mem server (D8, D9): tools validate their own
    # arguments (aliases are normalised first), and gem-side failures reach Rails.error.
    #
    # @return [MCP::Configuration]
    def self.configuration
      @configuration ||= MCP::Configuration.new(validate_tool_call_arguments: false, exception_reporter: EXCEPTION_REPORTER)
    end

    # Who may reach /mcp (GRAPH_MEM_MCP_TOKEN, GRAPH_MEM_MCP_ALLOWED_IPS); see docs/mcp_access_control.md.
    #
    # @return [GraphMem::McpAccessPolicy]
    def self.access_policy
      @access_policy ||= GraphMem::McpAccessPolicy.from_env(logger: Rails.logger)
    end

    # Rebuilds the access policy and the transports from the current environment on next use.
    def self.reset!
      @access_policy = nil
      Transports.reset!
    end

    # Request-body and stdio line cap, in bytes (D7).
    #
    # @return [Integer]
    def self.max_request_bytes
      Integer(ENV.fetch("GRAPH_MEM_MCP_MAX_REQUEST_BYTES", 4 * 1024 * 1024))
    end
  end
end

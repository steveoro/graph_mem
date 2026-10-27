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

    # Who may reach /mcp and bearer /api/v1 (GRAPH_MEM_MCP_TOKEN, GRAPH_MEM_MCP_ALLOWED_IPS plus the
    # Settings › MCP access additions); see docs/mcp_access_control.md.
    #
    # @return [GraphMem::McpAccessPolicy]
    def self.access_policy
      @access_policy ||= GraphMem::McpAccessPolicy.from_env(logger: Rails.logger,
                                                            extra_ips: McpAccessLists.extra_entries!(:ips))
    rescue McpAccessLists::ReadError
      # ENV only, and not cached: the next request reads the settings again.
      GraphMem::McpAccessPolicy.from_env(logger: Rails.logger)
    end

    # Rebuilds the access policy and the transports from the current environment on next use.
    def self.reset!
      @access_policy = nil
      Transports.reset!
    end

    # Applies a change to the MCP allowlists (Settings › MCP access, a restored backup) without a
    # restart. The policy is rebuilt on next use. The transports cache the allowed hosts and origins
    # when they are built, so a hosts or origins change rebuilds them too, which closes every open
    # MCP session; an IPs-only change keeps them. In-process only: with several Puma workers a
    # change would reach the others at their next restart.
    #
    # @param transports [Boolean] true when the allowed hosts or origins changed
    def self.refresh_access!(transports:)
      @access_policy = nil
      Transports.reset! if transports
    end

    # Request-body and stdio line cap, in bytes (D7).
    #
    # @return [Integer]
    def self.max_request_bytes
      Integer(ENV.fetch("GRAPH_MEM_MCP_MAX_REQUEST_BYTES", 4 * 1024 * 1024))
    end
  end
end

# frozen_string_literal: true

require_relative "mcp_profile"
require_relative "mcp_instructions"

module GraphMem
  # FastMcp::Server options shared by the HTTP server (config/initializers/fast_mcp.rb) and the
  # stdio runner (bin/mcp_stdio_runner.rb).
  #
  # @example
  #   FastMcp::Server.new(name: "graph-mem", version: GraphMem::VERSION, **GraphMem::McpServerOptions.for_http)
  module McpServerOptions
    # graph_mem never sends resources/updated or list_changed notifications (its tool and resource
    # lists are fixed at boot), so it advertises none (mcp plan PR-2 §2.18, D-15). fast-mcp merges
    # capabilities one level deep, so every group is spelled out.
    CAPABILITIES = {
      resources: { subscribe: false, listChanged: false },
      tools: { listChanged: false },
      prompts: { listChanged: false }
    }.freeze

    module_function

    # Per-request instructions: the profile comes from the request path (/mcp, /mcp/readonly,
    # /mcp/maintenance), or from GRAPH_MEM_MCP_PROFILE when there is no request.
    #
    # @return [Hash] +capabilities:+ and +instructions:+ for FastMcp::Server.new
    def for_http
      {
        capabilities: CAPABILITIES,
        instructions: ->(request) { McpInstructions.for(request ? McpProfile.from_request(request) : McpProfile.from_env) }
      }
    end

    # @param profile [Symbol] the stdio runner's profile
    # @return [Hash] +capabilities:+ and +instructions:+ for FastMcp::Server.new
    def for_stdio(profile)
      { capabilities: CAPABILITIES, instructions: ->(_request) { McpInstructions.for(profile) } }
    end
  end
end

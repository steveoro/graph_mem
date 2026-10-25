# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Builds one MCP::Server per profile (default, readonly, maintenance).
    #
    # @example
    #   ServerFactory.for(:readonly).tools.keys # => the 9 read tools
    module ServerFactory
      # graph_mem sends no list_changed, resources/updated or logging notifications (its lists are
      # fixed at boot), so it advertises none; the gem's default would.
      CAPABILITIES = {
        resources: { subscribe: false, listChanged: false },
        tools: { listChanged: false },
        prompts: { listChanged: false }
      }.freeze

      # @param profile [Symbol, String] one of GraphMem::McpProfile::NAMES
      # @return [MCP::Server]
      def self.for(profile)
        profile = GraphMem::McpProfile.normalize(profile)
        GraphMem::McpToolRegistry.load_all!
        resources = GraphMem::McpToolRegistry.resource_classes

        server = MCP::Server.new(
          name: "graph-mem",
          version: GraphMem::VERSION.to_s,
          instructions: GraphMem::McpInstructions.for(profile),
          capabilities: CAPABILITIES,
          tools: GraphMem::McpToolRegistry.tool_classes_for(profile).select(&:mcp_advertised?).map { |klass| ToolWrapper.build(klass) },
          prompts: GraphMem::McpToolRegistry.prompt_classes_for(profile).map { |klass| PromptWrapper.build(klass) },
          resource_templates: ResourceCatalog.templates(resources),
          configuration: OfficialMcp.configuration
        )
        server.resources_read_handler { |params| ResourceCatalog.read(resources, params[:uri].to_s) }
        server
      end
    end
  end
end

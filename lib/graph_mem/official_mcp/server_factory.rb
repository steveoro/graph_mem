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

      # The capabilities a server declares: CAPABILITIES, plus the MCP Apps extension
      # (io.modelcontextprotocol/ui) when the views are on. A plain Hash on purpose: an
      # MCP::Server::Capabilities object would drop the explicit false values.
      #
      # @param apps_enabled [Boolean]
      # @return [Hash]
      def self.capabilities(apps_enabled:)
        apps_enabled ? CAPABILITIES.merge(extensions: MCP::Apps.capability) : CAPABILITIES
      end

      # @param profile [Symbol, String] one of GraphMem::McpProfile::NAMES
      # @param apps_enabled [Boolean] declare the MCP Apps extension and list the profile's views
      # @return [MCP::Server]
      def self.for(profile, apps_enabled: GraphMem::McpApps.enabled?)
        profile = GraphMem::McpProfile.normalize(profile)
        GraphMem::McpToolRegistry.load_all!
        providers = [ TemplateResourceProvider.new(GraphMem::McpToolRegistry.resource_classes) ]
        providers << GraphMem::McpApps::Views.provider_for(profile) if apps_enabled
        views = apps_enabled ? GraphMem::McpApps::Views.uris_for(profile) : []

        server = MCP::Server.new(
          name: "graph-mem",
          version: GraphMem::VERSION.to_s,
          instructions: GraphMem::McpInstructions.for(profile),
          capabilities: capabilities(apps_enabled: apps_enabled),
          tools: GraphMem::McpToolRegistry.tool_classes_for(profile).select(&:mcp_advertised?).map { |klass| ToolWrapper.build(klass, views: views) },
          prompts: GraphMem::McpToolRegistry.prompt_classes_for(profile).map { |klass| PromptWrapper.build(klass) },
          resources: ResourceCatalog.resources(providers),
          resource_templates: ResourceCatalog.templates(providers),
          configuration: OfficialMcp.configuration
        )
        server.resources_read_handler { |params| ResourceCatalog.read(providers, params[:uri].to_s) }
        server
      end
    end
  end
end

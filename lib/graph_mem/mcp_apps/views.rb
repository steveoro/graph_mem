# frozen_string_literal: true

module GraphMem
  module McpApps
    # The ui:// views graph_mem serves (MCP Apps, 1.87.0), as a StaticResourceProvider per profile.
    # A view's document is the HTML shell plus its scripts, built by ViewBuilder (1.88.0). A view is registered on a profile only when that profile advertises every tool the
    # view calls, so a host never gets a view whose calls the server would refuse.
    #
    # @example
    #   Views.uris_for(:readonly)            # => ["ui://graph-mem/graph"]
    #   Views.provider_for(:readonly).read(Views::GRAPH_URI)
    #   # => [{ uri:, mimeType: "text/html;profile=mcp-app", _meta: { ui: { prefersBorder: true } }, text: "<!doctype html>…" }]
    module Views
      GRAPH_URI = "ui://graph-mem/graph"

      # uri, listing fields, the content item's _meta.ui (no csp, permissions or domain: the host's
      # restrictive default CSP applies), the HTML shell and scripts (ViewBuilder) and the tools the
      # view may call.
      VIEWS = [
        {
          uri: GRAPH_URI, name: "graph_view", title: "Graph view",
          description: "Interactive view of graph_mem tool results (MCP Apps). Opened by hosts that support the extension.",
          meta: { ui: { prefersBorder: true } }.freeze,
          source: "graph.html", scripts: %w[bridge.js host.js adapter.js loader.js interaction.js graph_view.js].freeze,
          calls: %w[search get_entities traverse_graph find_shortest_path get_context].freeze
        }.freeze
      ].freeze

      # @param profile [Symbol, String]
      # @return [Array<String>] the URIs of the views registered on that profile
      def self.uris_for(profile) = views_for(profile).map { |view| view[:uri] }

      # @param profile [Symbol, String]
      # @return [GraphMem::OfficialMcp::StaticResourceProvider]
      def self.provider_for(profile)
        entries = views_for(profile).map do |view|
          { uri: view[:uri], name: view[:name], title: view[:title], description: view[:description],
            mime_type: MCP::Apps::RESOURCE_MIME_TYPE, meta: view[:meta], body: -> { ViewBuilder.document(shell: view[:source], scripts: view[:scripts]) } }
        end
        GraphMem::OfficialMcp::StaticResourceProvider.new(entries, listing: lambda { |entry|
          MCP::Apps.ui_resource(**entry.slice(:uri, :name, :title, :description, :mime_type))
        })
      end

      def self.views_for(profile)
        GraphMem::McpToolRegistry.load_all!
        advertised = GraphMem::McpToolRegistry.tool_classes_for(GraphMem::McpProfile.normalize(profile))
                                              .select(&:mcp_advertised?).map(&:tool_name)
        VIEWS.select { |view| (view[:calls] - advertised).empty? }
      end
      private_class_method :views_for
    end
  end
end

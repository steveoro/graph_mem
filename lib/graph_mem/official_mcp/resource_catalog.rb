# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # The resources a server lists and reads, from an ordered list of providers. A provider answers
    # `resources` (static listings), `templates`, `match?(uri)` and `read(uri)` (the `contents` of a
    # resources/read result); TemplateResourceProvider is one. resources/read asks the providers in
    # order, so a later provider registers without touching the read path.
    #
    # @example
    #   providers = [ TemplateResourceProvider.new(GraphMem::McpToolRegistry.resource_classes) ]
    #   ResourceCatalog.templates(providers) # => [MCP::ResourceTemplate, …]
    #   ResourceCatalog.read(providers, uri) # => [{ uri:, mimeType:, text: }]
    module ResourceCatalog
      # @param providers [Array<#resources>]
      # @return [Array<MCP::Resource>] the static listings, for MCP::Server.new(resources:)
      def self.resources(providers) = providers.flat_map(&:resources)

      # @param providers [Array<#templates>]
      # @return [Array<MCP::ResourceTemplate>]
      def self.templates(providers) = providers.flat_map(&:templates)

      # @param providers [Array<#match?, #read>]
      # @param uri [String]
      # @return [Array<Hash>] the `contents` of the resources/read result
      # @raise [MCP::Server::ResourceNotFoundError] when no provider matches
      def self.read(providers, uri)
        provider = providers.find { |candidate| candidate.match?(uri) }
        raise MCP::Server::ResourceNotFoundError.new(uri) unless provider

        provider.read(uri)
      end
    end
  end
end

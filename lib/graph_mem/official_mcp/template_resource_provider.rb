# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # The ApplicationResource URI templates (memory_graph{?…} and friends) as a ResourceCatalog
    # provider: no static listings, one gem template per templated class, and resources/read
    # dispatched to the class whose template matches the URI.
    #
    # @example
    #   provider = TemplateResourceProvider.new(GraphMem::McpToolRegistry.resource_classes)
    #   provider.match?("memory://graph") # => true when a template matches
    #   provider.read("memory://graph")   # => [{ uri:, mimeType:, text: }]
    class TemplateResourceProvider
      # @param resource_classes [Array<Class<ApplicationResource>>]
      def initialize(resource_classes)
        @resource_classes = resource_classes
      end

      # @return [Array<MCP::Resource>] none: templates only
      def resources = []

      # @return [Array<MCP::ResourceTemplate>]
      def templates
        @resource_classes.select(&:templated?).map do |klass|
          MCP::ResourceTemplate.new(uri_template: klass.uri, name: klass.resource_name, description: klass.description, mime_type: klass.mime_type)
        end
      end

      # @param uri [String]
      # @return [Boolean]
      def match?(uri) = !klass_for(uri).nil?

      # @param uri [String] a URI this provider matches
      # @return [Array<Hash>] the `contents` of the resources/read result
      def read(uri)
        klass = klass_for(uri)
        instance = klass.initialize_from_uri(uri)
        content = { uri: uri }
        content[:mimeType] = klass.mime_type if klass.mime_type
        [ instance.binary? ? content.merge(blob: Base64.strict_encode64(instance.content)) : content.merge(text: instance.content) ]
      end

      private

      def klass_for(uri) = @resource_classes.find { |candidate| candidate.match(uri) }
    end
  end
end

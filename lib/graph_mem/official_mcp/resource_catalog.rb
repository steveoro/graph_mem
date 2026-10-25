# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # The ApplicationResource templates as gem resource templates, plus the resources/read
    # dispatch from a URI to the resource class whose template matches it.
    module ResourceCatalog
      # @param resource_classes [Array<Class<ApplicationResource>>]
      # @return [Array<MCP::ResourceTemplate>]
      def self.templates(resource_classes)
        resource_classes.select(&:templated?).map do |klass|
          MCP::ResourceTemplate.new(uri_template: klass.uri, name: klass.resource_name, description: klass.description, mime_type: klass.mime_type)
        end
      end

      # @param resource_classes [Array<Class<ApplicationResource>>]
      # @param uri [String]
      # @return [Array<Hash>] the `contents` of the resources/read result
      # @raise [MCP::Server::ResourceNotFoundError] when no resource matches
      def self.read(resource_classes, uri)
        klass = resource_classes.find { |candidate| candidate.match(uri) }
        raise MCP::Server::ResourceNotFoundError.new(uri) unless klass

        instance = klass.initialize_from_uri(uri)
        content = { uri: uri }
        content[:mimeType] = klass.mime_type if klass.mime_type
        [ instance.binary? ? content.merge(blob: Base64.strict_encode64(instance.content)) : content.merge(text: instance.content) ]
      end
    end
  end
end

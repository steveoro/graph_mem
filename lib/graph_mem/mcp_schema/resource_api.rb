# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # The resource class API: a `uri` (an RFC 6570 template when it has variables), `resource_name`,
    # `description`, `mime_type`, and `#content` built from the URI's `params`.
    #
    # @example
    #   class NoteResource
    #     include GraphMem::McpSchema::ResourceApi
    #     uri "notes{?id}"
    #     mime_type "application/json"
    #     def content = { id: params[:id] }.to_json
    #   end
    #   NoteResource.initialize_from_uri("notes?id=7").content # => "{\"id\":\"7\"}"
    module ResourceApi
      def self.included(base)
        base.extend(ClassMethods)
        base.attr_reader(:params)
      end

      # Class-level declarations, inherited by subclasses.
      module ClassMethods
        def uri(value = nil)
          @uri = value if value
          @uri || (superclass.respond_to?(:uri) ? superclass.uri : nil)
        end

        def resource_name(value = nil)
          @resource_name = value if value
          @resource_name || (superclass.respond_to?(:resource_name) ? superclass.resource_name : nil)
        end

        def description(value = nil)
          @description = value if value
          @description || (superclass.respond_to?(:description) ? superclass.description : nil)
        end

        def mime_type(value = nil)
          @mime_type = value if value
          @mime_type || (superclass.respond_to?(:mime_type) ? superclass.mime_type : nil)
        end

        # @return [Addressable::Template]
        def addressable_template
          @addressable_template ||= Addressable::Template.new(uri)
        end

        # @return [Boolean] whether the URI has template variables
        def templated?
          addressable_template.variables.any?
        end

        # @return [Addressable::Template::MatchData, nil]
        def match(uri)
          addressable_template.match(uri)
        end

        # @return [Object] an instance with the URI's template variables as params
        def initialize_from_uri(uri)
          new(match(uri).mapping.transform_keys(&:to_sym))
        end
      end

      # @param params [Hash{Symbol => String}] the URI's template variables
      def initialize(params = {})
        @params = params
      end

      # @return [String] the resource's content
      def content
        raise NotImplementedError, "Subclasses must implement content"
      end

      # @return [Boolean] whether the content is binary (anything but text, JSON, XML or JavaScript)
      def binary?
        mime_type = self.class.mime_type
        return false if mime_type.nil?

        !(mime_type.start_with?("text/") || %w[application/json application/xml application/javascript].include?(mime_type))
      end
    end
  end
end

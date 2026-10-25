# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # The tool class API: an `arguments` dry-schema (its JSON Schema is what `tools/list` shows),
    # `description`, `annotations`, an optional output schema, and a call validated against the
    # arguments schema.
    #
    # @example
    #   class EchoTool
    #     include GraphMem::McpSchema::ToolApi
    #     def self.tool_name = "echo"
    #     description "Echoes its text."
    #     arguments { required(:text).filled(:string).description("Text to echo") }
    #     def call(text:) = text
    #   end
    #   EchoTool.input_schema_to_json # => { type: "object", properties: { text: { type: "string", minLength: 1, description: "Text to echo" } }, required: ["text"] }
    module ToolApi
      def self.included(base)
        base.extend(ClassMethods)
        base.attr_accessor(:_meta)
        base.attr_reader(:headers)
      end

      # Class-level declarations.
      module ClassMethods
        # Declares the arguments with the dry-schema JSON DSL; `.description(text)` documents a key.
        def arguments(&block)
          metadata_context = MetadataContext.new
          @input_schema = MetadataContext.with_context(metadata_context) { Dry::Schema.JSON(&block) }
          @collected_metadata = metadata_context.metadata
        end

        # Declares an output schema with the same DSL.
        #
        # @return [Dry::Schema::JSON]
        def output(&block)
          metadata_context = MetadataContext.new
          @output_schema = MetadataContext.with_context(metadata_context) { Dry::Schema.JSON(&block) }
          @collected_output_metadata = metadata_context.metadata
          @output_schema
        end

        # Sets (with a Hash) or returns the output schema.
        #
        # @param schema [Hash, nil] a static JSON Schema
        # @return [Hash, Dry::Schema::JSON, nil]
        def output_schema(schema = nil)
          @static_output_schema = schema if schema
          @static_output_schema || @output_schema
        end

        # @return [Hash, nil] the output JSON Schema for tools/list
        def output_schema_to_json
          return @static_output_schema if @static_output_schema
          return unless @output_schema

          MetadataProcessor.process(@output_schema, @collected_output_metadata || {})
        end

        # @return [Dry::Schema::JSON] the arguments schema (empty when none was declared)
        def input_schema
          @input_schema ||= Dry::Schema.JSON
        end

        # @return [Hash, nil] the arguments JSON Schema for tools/list
        def input_schema_to_json
          MetadataProcessor.process(@input_schema, @collected_metadata || {})
        end

        # Sets or returns the tool name: letters, digits, "_" and "-", at most 64 characters.
        def tool_name(name = nil)
          name = @name || self.name if name.nil?
          return if name.nil?

          @name = name.gsub(/[^a-zA-Z0-9_-]/, "")[0, 64]
        end

        # Sets (with a value) or returns the description.
        def description(description = nil)
          return @description if description.nil?

          @description = description
        end

        # Sets (with a Hash) or returns the annotations (read_only_hint, …).
        #
        # @return [Hash]
        def annotations(annotations_hash = nil)
          return @annotations || {} if annotations_hash.nil?

          @annotations = annotations_hash
        end

        def call(**)
          raise NotImplementedError, "Subclasses must implement the call method"
        end
      end

      # @param headers [Hash{String => String}] the request headers the tool may read
      def initialize(headers: {})
        @_meta = {}
        @headers = headers
      end

      # Validates the arguments against the arguments schema, then calls the tool.
      #
      # @return [Array(Object, Hash)] the tool's result and its `_meta`
      # @raise [GraphMem::InvalidArgumentsError] when the arguments don't match the schema
      def call_with_schema_validation!(**args)
        validation = self.class.input_schema.call(args)
        raise GraphMem::InvalidArgumentsError, validation.errors.to_h.to_json if validation.errors.any?

        [ call(**args), _meta ]
      end
    end
  end
end

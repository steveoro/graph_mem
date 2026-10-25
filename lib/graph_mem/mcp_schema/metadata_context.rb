# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # Collects key metadata (description, hidden) with its full dotted path while an `arguments`
    # block is evaluated, so nested keys keep their own descriptions.
    class MetadataContext
      THREAD_KEY = :graph_mem_mcp_schema_metadata_context

      # @return [Hash{String => Hash}] dotted key path => metadata
      attr_reader :metadata

      def initialize
        @metadata = {}
        @nesting_stack = []
      end

      def store(property_name, meta_key, value)
        full_path = (current_path + [ property_name.to_s ]).join(".")
        @metadata[full_path] ||= {}
        @metadata[full_path][meta_key] = value
      end

      def with_nested(parent_property)
        @nesting_stack.push(parent_property.to_s)
        yield
      ensure
        @nesting_stack.pop
      end

      def current_path
        @nesting_stack.dup
      end

      # @return [MetadataContext, nil] the context of the block being evaluated on this thread
      def self.current
        Thread.current[THREAD_KEY]
      end

      def self.with_context(context)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = context
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end
  end
end

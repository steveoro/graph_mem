# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # Adds `.description(text)` and `.hidden` to dry-schema's key macros, and records them as
    # metadata on the schema DSL (and on the current MetadataContext for nested keys), so
    # MetadataProcessor can put them into the JSON Schema.
    module DrySchemaExtensions
      # `description` and `hidden` for the Value, Required and Optional macros.
      module Describable
        def description(text)
          schema_dsl.meta(name.to_sym, :description, text)
          self
        end

        def hidden(hidden = true) # rubocop:disable Style/OptionalBooleanParameter
          schema_dsl.meta(name.to_sym, :hidden, hidden)
          self
        end
      end

      # The Hash macro: the same, and its nested block runs inside the parent key's metadata path.
      module DescribableHash
        def description(text)
          schema_dsl.meta(name.to_sym, :description, text)
          @has_metadata = true
          self
        end

        def hidden(hidden = true) # rubocop:disable Style/OptionalBooleanParameter
          schema_dsl.meta(name.to_sym, :hidden, hidden)
          @has_metadata = true
          self
        end

        def call(&block)
          context = MetadataContext.current
          return super unless block && context

          context.with_nested(name) { super }
        end
      end

      # Stores metadata on the schema DSL and in the current MetadataContext.
      module DslMetadata
        def meta(key_name, meta_key, value)
          @meta ||= {}
          @meta[key_name] ||= {}
          @meta[key_name][meta_key] = value
          MetadataContext.current&.store(key_name, meta_key, value)
        end

        def meta_data
          @meta || {}
        end
      end

      # Installs the extensions once. Prepended, so they win over any other definition of the same
      # methods (e.g. another gem's copy still loaded).
      def self.install!
        return if @installed

        [ Dry::Schema::Macros::Value, Dry::Schema::Macros::Required, Dry::Schema::Macros::Optional ].each { |macro| macro.prepend(Describable) }
        Dry::Schema::Macros::Hash.prepend(DescribableHash)
        Dry::Schema::DSL.prepend(DslMetadata)
        @installed = true
      end
    end
  end
end

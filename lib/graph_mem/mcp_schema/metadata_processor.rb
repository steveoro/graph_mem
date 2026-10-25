# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # Turns a dry-schema JSON schema plus the collected key metadata into the JSON Schema tools
    # advertise: descriptions added, hidden keys (and their `required` entries) removed.
    module MetadataProcessor
      # @param schema [Dry::Schema::JSON, nil]
      # @param collected_metadata [Hash{String => Hash}] from a MetadataContext
      # @return [Hash, nil] JSON Schema without `$schema`
      def self.process(schema, collected_metadata = {})
        return nil unless schema

        base_schema = schema.json_schema.tap { _1.delete(:$schema) }
        apply_metadata_to_schema(base_schema, merge_metadata(extract_metadata(schema), collected_metadata))
      end

      def self.extract_metadata(schema)
        schema.instance_variable_get(:@schema_dsl)&.meta_data || {}
      end

      def self.merge_metadata(traditional, collected)
        merged = traditional.dup
        collected.reject { |key, _| key.to_s.start_with?("_") }.each { |path, metadata| merged[path] = metadata }
        merged
      end

      def self.apply_metadata_to_schema(base_schema, metadata)
        return base_schema if !base_schema[:properties] || metadata.empty?

        base_schema[:properties] = process_properties_recursively(base_schema[:properties], metadata, [])
        base_schema[:required] = filter_required_properties(base_schema[:required], base_schema[:properties])
        base_schema
      end

      def self.process_properties_recursively(properties, metadata, path_prefix = [])
        filtered_properties = {}

        properties.each do |property_name, property_schema|
          current_path = (path_prefix + [ property_name.to_s ]).join(".")
          property_metadata = metadata[property_name.to_sym] || metadata[current_path]
          next if property_metadata&.dig(:hidden)

          property_schema[:description] = property_metadata[:description] if property_metadata&.dig(:description)

          if property_schema[:type] == "object" && property_schema[:properties]
            nested_path = path_prefix + [ property_name.to_s ]
            property_schema[:properties] = process_properties_recursively(property_schema[:properties], metadata, nested_path)
            property_schema[:required] = filter_required_properties(property_schema[:required], property_schema[:properties])
          elsif property_schema[:type] == "array" && property_schema.dig(:items, :type) == "object" && property_schema.dig(:items, :properties)
            nested_path = path_prefix + [ property_name.to_s ]
            property_schema[:items][:properties] = process_properties_recursively(property_schema[:items][:properties], metadata, nested_path)
            property_schema[:items][:required] =
              filter_required_properties(property_schema[:items][:required], property_schema[:items][:properties])
          end

          filtered_properties[property_name] = property_schema
        end

        filtered_properties
      end

      def self.filter_required_properties(required_array, properties)
        return [] unless required_array

        required_array.select { |required_prop| properties.key?(required_prop.to_sym) || properties.key?(required_prop.to_s) }
      end

      private_class_method :extract_metadata, :merge_metadata, :apply_metadata_to_schema,
                           :process_properties_recursively, :filter_required_properties
    end
  end
end

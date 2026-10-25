# frozen_string_literal: true

# Normalizes incoming MCP tool parameters to graph_mem's canonical format.
# Accepts both graph_mem's snake_case/ID-based conventions and the
# @modelcontextprotocol/server-memory camelCase/name-based conventions.
module ParameterNormalizer
  # Standard-server field aliases that map to graph_mem canonical names.
  # Applied AFTER camelCase→snake_case conversion.
  FIELD_ALIASES = {
    "content" => "text_content",
    "name_of_entity" => "entity_name"
  }.freeze

  # Fields where a string value should be resolved to an entity ID.
  ENTITY_NAME_FIELDS = {
    "entity_name" => "entity_id",
    "from_entity"  => "from_entity_id",
    "to_entity"    => "to_entity_id",
    "from"         => "from_entity_id",
    "to"           => "to_entity_id"
  }.freeze

  GRAPH_WRITE_TYPE_ALIASES = {
    "entity" => "create_entity",
    "observation" => "create_observation",
    "add_observation" => "create_observation",
    "relation" => "create_relation"
  }.freeze

  class << self
    def normalize(tool_name, params, project_id: nil)
      params = deep_snake_case_keys(params)
      params = apply_field_aliases(params)

      params = normalize_graph_write(params) if tool_name == "graph_write"
      params = normalize_typed_operations(params) if tool_name.in?(%w[graph_edit graph_delete])
      params = normalize_search(params) if tool_name == "search"
      params = normalize_get_entities(params, project_id: project_id) if tool_name == "get_entities"

      params = resolve_entity_names(params, project_id: project_id)
      params
    end

    private

    # Name → entity under project-scoped names: the `set_context` project
    # first, then the global (NULL-project) namespace. Several declaring
    # projects and no context match → AmbiguousReference listing the
    # candidates; never guesses.
    def find_entity_scoped(name, project_id)
      ImportEntityResolver.find_by_name(name, project_id: project_id)
    end

    # Recursively convert camelCase hash keys to snake_case.
    def deep_snake_case_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(key, val), acc|
          snake_key = underscore(key.to_s)
          acc[snake_key.to_sym] = deep_snake_case_keys(val)
        end
      when Array
        obj.map { |item| deep_snake_case_keys(item) }
      else
        obj
      end
    end

    def underscore(str)
      str.gsub(/::/, "/")
         .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .downcase
    end

    # Rename known aliases to canonical field names (top-level only).
    def apply_field_aliases(params)
      result = params.dup
      FIELD_ALIASES.each do |from, to|
        from_sym = from.to_sym
        to_sym   = to.to_sym
        if result.key?(from_sym) && !result.key?(to_sym)
          result[to_sym] = result.delete(from_sym)
        end
      end
      result
    end

    def normalize_search(params)
      result = params.dup
      result[:per_page] = result[:limit] if result[:per_page].blank? && result[:limit].present?
      result.delete(:limit)
      result
    end

    def normalize_graph_write(params)
      result = normalize_typed_operations(params, type_aliases: GRAPH_WRITE_TYPE_ALIASES)
      result[:observations] = Array(result[:observations]).map { |item| apply_field_aliases(item) } if result.key?(:observations)
      result
    end

    def normalize_typed_operations(params, type_aliases: {})
      result = params.dup
      return result unless result[:operations].is_a?(Array)

      result[:operations] = result[:operations].flat_map do |raw_operation|
        operation = apply_field_aliases(raw_operation.to_h)
        operation[:from_entity_id] ||= operation.delete(:from) if operation.key?(:from)
        operation[:to_entity_id] ||= operation.delete(:to) if operation.key?(:to)
        type = operation[:type].to_s.strip.downcase
        operation[:type] = type_aliases.fetch(type, type)

        if operation[:type] == "create_observation" && operation[:contents].is_a?(Array)
          operation.delete(:contents).map { |content| operation.merge(text_content: content) }
        else
          operation
        end
      end
      result
    end

    def normalize_get_entities(params, project_id: nil)
      result = params.dup
      if result[:entity_ids].blank? && result[:entity_id].present?
        result[:entity_ids] = [ result[:entity_id] ]
      end
      result.delete(:entity_id)
      return result unless result[:entity_ids].is_a?(Array)

      result[:entity_ids] = result[:entity_ids].map do |value|
        next value unless value.is_a?(String) && value.present?

        entity = find_entity_scoped(value, project_id)
        next entity.id if entity

        raise McpGraphMemErrors::ResourceNotFound.new(
          "Entity not found by name: '#{value}'. Provide a valid entity name or use an integer entity_id.",
          next_move: "Call `search` to find a matching name, then retry `get_entities` with known ids."
        )
      end
      result
    end

    # Resolve entity-name fields to entity IDs. Only triggered when the
    # field value is a string and the target ID field is not already set.
    def resolve_entity_names(params, project_id: nil)
      return params unless params.is_a?(Hash)

      result = params.dup
      ENTITY_NAME_FIELDS.each do |name_field, id_field|
        name_sym = name_field.to_sym
        id_sym   = id_field.to_sym
        next unless result.key?(name_sym)
        next if result.key?(id_sym) && result[id_sym].present?

        entity_name = result.delete(name_sym)
        next unless entity_name.is_a?(String) && entity_name.present?

        entity = find_entity_scoped(entity_name, project_id)
        if entity
          result[id_sym] = entity.id
        else
          raise McpGraphMemErrors::ResourceNotFound.new(
            "Entity not found by name: '#{entity_name}'. Use entity_id (integer) or verify the entity name.",
            next_move: "Call `search` to find a matching name, then retry with a known id."
          )
        end
      end

      %i[entity_id start_entity_id from_entity_id to_entity_id].each do |id_field|
        val = result[id_field]
        next unless val.is_a?(String) && val.present?

        entity = find_entity_scoped(val, project_id)
        if entity
          result[id_field] = entity.id
        else
          raise McpGraphMemErrors::ResourceNotFound.new(
            "Entity not found by name: '#{val}'. Provide a valid entity name or use an integer entity_id.",
            next_move: "Call `search` to find a matching name, then retry with a known id."
          )
        end
      end

      result
    end
  end
end

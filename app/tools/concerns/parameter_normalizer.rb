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

  # Operation type strings accepted in the `operations` array, mapped
  # to the canonical bulk_update bucket they belong to.
  OPERATION_TYPE_MAP = {
    "create_entity"      => :entities,
    "entity"             => :entities,
    "create_observation" => :observations,
    "add_observation"    => :observations,
    "observation"        => :observations,
    "create_relation"    => :relations,
    "relation"           => :relations
  }.freeze

  class << self
    def normalize(tool_name, params)
      params = deep_snake_case_keys(params)
      params = apply_field_aliases(params)

      if tool_name == "bulk_update"
        params = normalize_bulk_update(params)
      end

      params = resolve_entity_names(params)
      params
    end

    private

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

    # Convert an `operations` array into the canonical three-array format.
    def normalize_bulk_update(params)
      operations = params.delete(:operations)
      return params unless operations.is_a?(Array) && operations.any?

      entities     = params[:entities]     || []
      observations = params[:observations] || []
      relations    = params[:relations]    || []

      operations.each do |op|
        op = apply_field_aliases(op)
        op = resolve_entity_names(op, lenient: true)
        type_key = op.delete(:type)&.to_s&.strip&.downcase
        bucket = OPERATION_TYPE_MAP[type_key]

        case bucket
        when :entities
          entities << normalize_entity_op(op)
        when :observations
          observations.concat(normalize_observation_op(op))
        when :relations
          relations << normalize_relation_op(op)
        end
      end

      params.merge(entities: entities, observations: observations, relations: relations)
    end

    def normalize_entity_op(op)
      {
        name:         op[:name],
        entity_type:  op[:entity_type],
        aliases:      op[:aliases],
        description:  op[:description],
        observations: normalize_contents_to_array(op)
      }.compact
    end

    def normalize_observation_op(op)
      entity_id = op[:entity_id]
      texts = normalize_contents_to_array(op)

      if texts.any?
        texts.map { |t| { entity_id: entity_id, text_content: t } }
      elsif op[:text_content]
        [ { entity_id: entity_id, text_content: op[:text_content] } ]
      else
        []
      end
    end

    def normalize_relation_op(op)
      {
        from_entity_id: op[:from_entity_id],
        to_entity_id:   op[:to_entity_id],
        relation_type:  op[:relation_type]
      }
    end

    # The standard server uses `contents` (array of strings) and/or
    # `observations` (array of strings on entity operations).
    # Normalize both to a flat array of strings.
    def normalize_contents_to_array(op)
      result = []
      result.concat(Array(op[:contents]))       if op[:contents]
      result.concat(Array(op[:observations]))    if op[:observations]
      result.push(op[:text_content])             if op[:text_content] && result.empty?
      result
    end

    # Resolve entity-name fields to entity IDs. Only triggered when the
    # field value is a string and the target ID field is not already set.
    # When lenient is true (used inside bulk_update operations parsing),
    # unresolvable names are silently skipped instead of raising errors --
    # the entity may be created earlier in the same transaction.
    def resolve_entity_names(params, lenient: false)
      return params unless params.is_a?(Hash)

      result = params.dup
      ENTITY_NAME_FIELDS.each do |name_field, id_field|
        name_sym = name_field.to_sym
        id_sym   = id_field.to_sym
        next unless result.key?(name_sym)
        next if result.key?(id_sym) && result[id_sym].present?

        entity_name = result.delete(name_sym)
        next unless entity_name.is_a?(String) && entity_name.present?

        entity = MemoryEntity.find_by(name: entity_name)
        if entity
          result[id_sym] = entity.id
        elsif lenient
          next
        else
          raise FastMcp::Tool::InvalidArgumentsError,
                "Entity not found by name: '#{entity_name}'. Use entity_id (integer) or verify the entity name."
        end
      end

      %i[entity_id from_entity_id to_entity_id].each do |id_field|
        val = result[id_field]
        next unless val.is_a?(String) && val.present?

        entity = MemoryEntity.find_by(name: val)
        if entity
          result[id_field] = entity.id
        elsif lenient
          next
        else
          raise FastMcp::Tool::InvalidArgumentsError,
                "Entity not found by name: '#{val}'. Provide a valid entity name or use an integer entity_id."
        end
      end

      result
    end
  end
end

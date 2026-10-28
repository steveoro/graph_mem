# frozen_string_literal: true

# What a search may match, applied inside every channel before ranking: one Project (the root
# and its members), a list of entity types, and which fields the query is matched against. Built
# and validated once per request by GraphSearch, the REST search endpoint and the Search page.
#
#   filter = SearchFilter.build(project_id: 12, entity_types: [ "Component" ], search_in_observations: false)
#   filter.entity_scope # => MemoryEntity relation (id = 12 OR project_id = 12) AND entity_type IN (...)
#   filter.fields       # => [:name, :entity_type, :aliases]
#   SearchFilter.build.default? # => true (every channel runs exactly as without a filter)
class SearchFilter
  MAX_ENTITY_TYPES = 20
  MAX_ENTITY_TYPE_LENGTH = 100
  # search_in_* flag => the field it enables, in the order the flags are declared
  FLAG_FIELDS = { search_in_name: :name, search_in_type: :entity_type, search_in_aliases: :aliases,
                  search_in_observations: :observations }.freeze
  # The entity text fields (EntitySearchStrategy's LIKE columns); observations are separate
  TEXT_FIELDS = %i[name entity_type aliases].freeze

  attr_reader :project_id, :entity_types, :fields

  # @param project_id [Integer, String, nil] id of a Project root entity
  # @param entity_types [Array<String>, nil] 1-20 types, exact and case-insensitive; [] = omitted
  # @param search_in_name [Boolean] and the other three flags: which fields the query matches
  # @return [SearchFilter] frozen
  # @raise [GraphMem::InvalidArgumentsError] with the tool's validation messages
  def self.build(project_id: nil, entity_types: nil, search_in_name: true, search_in_type: true,
                 search_in_aliases: true, search_in_observations: true)
    flags = { search_in_name: search_in_name, search_in_type: search_in_type,
              search_in_aliases: search_in_aliases, search_in_observations: search_in_observations }
    new(project_id: normalize_project_id(project_id), entity_types: normalize_entity_types(entity_types),
        fields: FLAG_FIELDS.filter_map { |flag, field| field unless flags[flag] == false })
  end

  def self.normalize_project_id(value)
    return nil if value.nil?

    id = value.is_a?(Integer) ? value : Integer(value.to_s, 10, exception: false)
    project = id&.positive? && MemoryEntity.find_by(id: id, project_id: nil, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
    raise GraphMem::InvalidArgumentsError, "project_id must be the id of a Project entity." unless project

    project.id
  end

  def self.normalize_entity_types(value)
    return [] if value.nil? || (value.respond_to?(:empty?) && value.empty?)

    types = value.is_a?(Array) && value.all?(String) ? value.map(&:strip).uniq(&:downcase) : nil
    unless types&.size&.between?(1, MAX_ENTITY_TYPES) && types.all? { |type| type.length.between?(1, MAX_ENTITY_TYPE_LENGTH) }
      raise GraphMem::InvalidArgumentsError, "entity_types must be a list of 1 to #{MAX_ENTITY_TYPES} non-blank entity types."
    end

    types
  end
  private_class_method :new, :normalize_project_id, :normalize_entity_types

  def initialize(project_id:, entity_types:, fields:)
    if fields.empty?
      raise GraphMem::InvalidArgumentsError, "At least one search field (name, type, aliases, observations) must be enabled."
    end

    @project_id = project_id
    @entity_types = entity_types.freeze
    @fields = fields.freeze
    freeze
  end

  # @return [Boolean] true when nothing is narrowed: no project, no types, every field on
  def default?
    project_id.nil? && entity_types.empty? && fields == FLAG_FIELDS.values
  end

  # @return [ActiveRecord::Relation, nil] the entities the filter allows, or nil when neither
  #   project nor types is set (no entity restriction)
  def entity_scope
    return nil if project_id.nil? && entity_types.empty?

    scope = MemoryEntity.all
    scope = scope.where(id: project_id).or(MemoryEntity.where(project_id: project_id)) if project_id
    scope = scope.where(entity_type: entity_types) if entity_types.any?
    scope
  end

  # @return [Array<Symbol>] the enabled entity text fields (subset of TEXT_FIELDS)
  def text_fields
    fields & TEXT_FIELDS
  end

  # @return [Boolean] whether the text and entity-vector channels run (any entity text field on)
  def entity_text?
    text_fields.any?
  end

  # @return [Boolean] whether the observation channels run
  def observations?
    fields.include?(:observations)
  end

  # @return [Hash, nil] `retrieval.filters`: `{ project_id:, entity_types:, search_in: [...] }`, nil when default
  def diagnostic
    return nil if default?

    { project_id: project_id, entity_types: entity_types,
      search_in: FLAG_FIELDS.filter_map { |flag, field| flag.to_s.delete_prefix("search_in_") if fields.include?(field) } }
  end
end

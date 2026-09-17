# frozen_string_literal: true

class RelationQueryService
  def self.call(**args)
    new(**args).call
  end

  def initialize(from_entity_id: nil, to_entity_id: nil, relation_type: nil, relation_types: nil)
    @from_entity_id = from_entity_id
    @to_entity_id = to_entity_id
    @relation_types = Array(relation_types.presence || relation_type).compact_blank
  end

  def call
    validate_entity!(@from_entity_id, "from_entity_id")
    validate_entity!(@to_entity_id, "to_entity_id")

    relation_scope.order(:id).map { |relation| GraphTraversalSerializer.relation_json(relation) }
  end

  private

  def validate_entity!(entity_id, field)
    return if entity_id.blank? || MemoryEntity.exists?(id: entity_id)

    raise McpGraphMemErrors::ResourceNotFound.new(
      "Entity with ID=#{entity_id} not found.",
      next_move: "Call `search`, then retry `traverse_graph` with a known #{field}."
    )
  end

  def relation_scope
    scope = MemoryRelation.all
    scope = scope.where(from_entity_id: @from_entity_id) if @from_entity_id.present?
    scope = scope.where(to_entity_id: @to_entity_id) if @to_entity_id.present?
    if @relation_types.any?
      canonical_types = @relation_types.map { |type| MemoryRelation.canonical_relation_type(type) }.uniq
      scope = scope.where(relation_type: canonical_types)
    end
    scope
  end
end

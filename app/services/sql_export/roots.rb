# frozen_string_literal: true

module SqlExport
  # The roots Projects › Exports offers and GET /data_exchange/root_nodes lists (from the retired
  # ExportStrategy, 1.94.0): Projects (they are roots even when part of another Project), then entities
  # with no outgoing part_of relation, each group by name. One query (NOT EXISTS), capped.
  #
  # Only part_of makes a child (Dream State R1b): scope follows part_of alone, so an entity with an
  # outgoing depends_on but no parent is global and the root of its own subtree, such as a library
  # after its swap that depends on another library.
  #
  #   SqlExport::Roots.list(query: "synth")       # => [#<MemoryEntity name: "SynthPrj" ...>, ...]
  #   SqlExport::Roots.list(limit: Roots::LIMIT + 1).size > Roots::LIMIT # => whether the list was cut
  module Roots
    # The export picker's list caps here; the picker's filter narrows by name.
    LIMIT = 500
    # An outgoing edge of these types makes an entity a child, not a root.
    CHILD_RELATION_TYPES = %w[part_of].freeze

    module_function

    # @param query [String, nil] keep only names containing this text
    # @param limit [Integer]
    # @return [Array<MemoryEntity>]
    def list(query: nil, limit: LIMIT)
      project = NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      children = MemoryRelation.where(relation_type: CHILD_RELATION_TYPES).where("memory_relations.from_entity_id = memory_entities.id")
      scope = MemoryEntity.where("memory_entities.entity_type = ? OR NOT EXISTS (#{children.select(1).to_sql})", project)
      scope = scope.where("memory_entities.name LIKE ?", "%#{MemoryEntity.sanitize_sql_like(query.to_s.strip)}%") if query.present?
      scope.order(Arel.sql(MemoryEntity.sanitize_sql_array([ "memory_entities.entity_type = ? DESC", project ])), :name)
           .limit(limit).to_a
    end
  end
end

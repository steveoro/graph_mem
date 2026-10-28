# frozen_string_literal: true

class ExploreEdits
  # Add and remove relations from the canvas (drag menu, edge menu) and the panel.
  module Relations
    UNKNOWN_RELATION_TYPE = "Pick a relation type from the list."
    DUPLICATE_RELATION = "That relation already exists."

    # @param from [MemoryEntity]
    # @param to [MemoryEntity]
    # @param relation_type [String] one of GraphVocabulary::RELATION_TYPES
    # @return [Hash]
    def add_relation(from, to, relation_type)
      relation_type = relation_type.to_s
      return refused(UNKNOWN_RELATION_TYPE) unless GraphVocabulary::RELATION_TYPES.include?(relation_type)
      # A part_of edge from a root would put it under a parent: the same as a move.
      return refused(ROOT_MOVE) if relation_type == "part_of" && project_root?(from)
      return refused(DUPLICATE_RELATION) if MemoryRelation.exists?(from_entity_id: from.id, to_entity_id: to.id, relation_type: relation_type)

      RelationSemantics.validate_create!(from_entity_id: from.id, to_entity_id: to.id, relation_type: relation_type)
      record("explore.relation_add", from, "added '#{from.name} #{relation_type} #{to.name}'") do
        GraphWriteService.execute_one("create_relation", { from_entity_id: from.id, to_entity_id: to.id, relation_type: relation_type })
        done("Added '#{from.name} #{relation_type} #{to.name}'.", from, changed: [ from.id, to.id ])
      end
    rescue RelationSemantics::ValidationError => e
      refused(e.message)
    rescue ActiveRecord::RecordNotUnique
      refused(DUPLICATE_RELATION)
    end

    # Undo re-creates the relation with its original id (the audit row's snapshot).
    #
    # @param relation [MemoryRelation]
    # @return [Hash]
    def remove_relation(relation)
      from = relation.from_entity
      to = relation.to_entity
      label = "#{from.name} #{relation.relation_type} #{to.name}"
      record("explore.relation_remove", from, "removed '#{label}'") do
        GraphDeleteService.execute_one("delete_relation", { relation_id: relation.id })
        done("Removed '#{label}'.", from, changed: [ from.id, to.id ])
      end
    end
  end
end

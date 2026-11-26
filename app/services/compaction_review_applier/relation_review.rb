# frozen_string_literal: true

class CompactionReviewApplier
  # A `relation_review` row (Dream State R1c): a fact of a project says that an entity the Project
  # still depends_on, or holds by part_of, was removed, replaced or dropped (RemovalEvidence). In R1
  # the row is informational: it is dismissed or snoozed, never applied. Apply (the MCP tool, the
  # Review page, a policy) answers a validation error, MESSAGE, and writes nothing; R2's relation
  # lifecycle gives it an apply (end the relation, the fact as the reason).
  #
  # Payload keys: `relation_id`, `relation_type`, `from_entity_id`, `from_name`, `to_entity_id`,
  # `to_name`, `evidence` (`observation_id`, `entity_id`, `entity_name`, `excerpt`) and `reason`.
  # One row per (relation, fact): the signature is "relation_review|<relation id>|<observation id>".
  #
  #   RelationReview.item(relation, fact)
  #   # => { kind: "relation_review", relation_id: 41, relation_type: "depends_on", from_name: "SynthApp", ... }
  #   RelationReview.apply(effective) # => { success: false, error: MESSAGE, validation: true }
  module RelationReview
    KIND = "relation_review"
    MESSAGE = "ending a relation arrives with the relation lifecycle; remove the relation by hand if it is wrong"
    NEXT_MOVE = "This row is informational: dismiss or snooze it with `dismiss_maintenance_review`. If the relation " \
                "is wrong, delete it by relation_id with `graph_delete`."

    module_function

    # @param relation [MemoryRelation] a candidate edge (RemovalEvidence.edges), both ends loaded
    # @param fact [MemoryObservation] the removal fact (RemovalEvidence.facts)
    # @return [Hash] the item for CompactionReviewService.seed_report
    def item(relation, fact)
      project, entity = RemovalEvidence.ends(relation)
      owner_name = fact.memory_entity&.name
      { id: SecureRandom.uuid, kind: KIND, relation_id: relation.id, relation_type: relation.relation_type,
        from_entity_id: relation.from_entity_id, from_name: relation.from_entity.name,
        to_entity_id: relation.to_entity_id, to_name: relation.to_entity.name,
        evidence: { observation_id: fact.id, entity_id: fact.memory_entity_id, entity_name: owner_name, excerpt: RemovalEvidence.excerpt(fact) },
        reason: "A fact of '#{project.name}' (##{fact.id} on '#{owner_name}') says '#{entity.name}' was removed, replaced or " \
                "dropped, but '#{project.name}' still #{relation.relation_type == RemovalEvidence::PART_OF ? 'holds it by part_of' : 'depends_on it'}" }
    end

    # @param _effective [Hash] the row's effective payload
    # @return [Hash] the refusal: `{ success: false, error:, validation: true, next_move: }`
    def apply(_effective)
      { success: false, error: MESSAGE, validation: true, next_move: NEXT_MOVE }
    end

    # @return [Hash] see Preview: not ok, MESSAGE as its warning
    def preview(_effective)
      Preview.result(false, warnings: [ MESSAGE ], undo: nil)
    end
  end
end

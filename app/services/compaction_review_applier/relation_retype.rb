# frozen_string_literal: true

class CompactionReviewApplier
  # Applies a `relation_retype` review row (R1a), queued by RelationTypeSweep when a stored variant
  # canonicalizes to `part_of`. The payload keys are fixed (the MCP review tools return them):
  # `operation`, `relation_id`, `from_entity_id`, `from_name`, `to_entity_id`, `to_name`,
  # `old_type`, `new_type`, `reason`.
  #
  # `operation` is "retype" in this release (same endpoints, the variant becomes `new_type`); R1b
  # adds "swap" and "add", so an unknown operation is refused as a validation error.
  #
  # Retype runs under the membership lock (CompactionReviewService.apply takes it before the row's
  # transaction; taken again here, reentrant, as the other part_of writers do) in a savepoint: the
  # variant row is deleted, then the `new_type` edge is created through MemoryRelation.create!
  # (RelationSemantics.validate_create!: one parent, no cycle) with the variant's weight, confidence
  # and properties, then ProjectMembership.sync!. A validation failure or a name collision rolls
  # the savepoint back and comes back as a "Cannot retype …" error. Stale rows (the relation is
  # already `new_type`, or a `new_type` twin exists, which the next sweep merges into) succeed with
  # nothing written. Undo is the generic audit undo: the created edge is destroyed (membership
  # synced) and the variant re-inserted with its stored type (MemoryRelation#keep_stored_type).
  #
  #   RelationRetype.apply({ operation: "retype", relation_id: 41, new_type: "part_of", … })
  #   # => { success: true, message: "Relation #41 'child_of' replaced by part_of #57" }
  module RelationRetype
    OPERATIONS = %w[retype].freeze
    DELETION_REASON = "relation type canonicalized: replaced through review"

    module_function

    # @param effective [Hash] the row's effective payload (indifferent access)
    # @param _action_params [Hash] unused: a retype row takes no overrides
    # @return [Hash] `{ success:, message: }` or `{ success: false, error: }`
    def apply(effective, _action_params = {})
      problem = operation_problem(effective)
      return { success: false, error: problem } if problem

      relation = MemoryRelation.lock.find_by(id: effective[:relation_id].to_i)
      stale = stale_reason(relation, effective)
      return stale if stale

      retype!(relation, effective[:new_type].to_s)
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "Cannot retype relation ##{effective[:relation_id]}: #{e.record.errors.full_messages.to_sentence}" }
    rescue ActiveRecord::RecordNotUnique, ProjectMembership::Collision => e
      { success: false, error: "Cannot retype relation ##{effective[:relation_id]}: #{e.message}" }
    end

    # @return [Hash] `{ ok:, effects:, warnings:, undo: }` (see Preview)
    def preview(effective, _action_params = {})
      problem = operation_problem(effective)
      return Preview.result(false, warnings: [ problem ]) if problem

      relation = MemoryRelation.find_by(id: effective[:relation_id].to_i)
      stale = stale_reason(relation, effective)
      return preview_retype(relation, effective[:new_type].to_s) unless stale

      stale[:success] ? Preview.result(true, effects: [ stale[:message] ]) : Preview.result(false, warnings: [ stale[:error] ])
    end

    # @return [String, nil] why the row's operation can't be applied
    def operation_problem(effective)
      operation = effective[:operation].to_s
      return nil if OPERATIONS.include?(operation)

      "Invalid relation_retype operation '#{operation}': only #{OPERATIONS.join(', ')} can be applied in this release"
    end

    # @return [Hash, nil] the answer for a row that no longer needs (or allows) the retype, nil when it applies
    def stale_reason(relation, effective)
      relation_id = effective[:relation_id]
      return { success: false, error: "Cannot retype relation ##{relation_id}: it no longer exists; dismiss this row" } unless relation

      new_type = effective[:new_type].to_s
      if RelationTypeSweep.stored_as?(relation.id, new_type)
        return { success: true, message: "Nothing to do: relation ##{relation.id} is already #{new_type}" }
      end
      if RelationTypeSweep.twin_id(relation.from_entity_id, relation.to_entity_id, new_type, except_id: relation.id)
        return { success: true, message: "Nothing to do: a #{new_type} relation with the same endpoints exists; " \
                                         "the next relation type sweep merges ##{relation.id} into it" }
      end
      target = RelationTypeSweep.target_type(relation.relation_type)
      return nil if MemoryRelation.fold_relation_type(target) == MemoryRelation.fold_relation_type(new_type)

      { success: false, error: "Cannot retype relation ##{relation.id}: '#{relation.relation_type}' no longer maps to " \
                               "#{new_type} (now #{target}); dismiss this row" }
    end

    def retype!(relation, new_type)
      created = ProjectMembership.with_membership_lock do
        ActiveRecord::Base.transaction(requires_new: true) do
          Current.set(deletion_reason: DELETION_REASON) { relation.destroy! }
          edge = MemoryRelation.create!(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                        relation_type: new_type, weight: relation.weight, confidence: relation.confidence,
                                        properties: relation.properties.is_a?(Hash) ? relation.properties : {})
          ProjectMembership.sync!(MemoryEntity.find(relation.from_entity_id)) if RelationTypeSweep.part_of?(new_type)
          edge
        end
      end
      { success: true, message: "Relation ##{relation.id} '#{relation.relation_type}' replaced by #{created.relation_type} ##{created.id}" }
    end

    def preview_retype(relation, new_type)
      names = MemoryEntity.where(id: [ relation.from_entity_id, relation.to_entity_id ]).pluck(:id, :name).to_h
      from = names[relation.from_entity_id]
      to = names[relation.to_entity_id]
      begin
        RelationSemantics.validate_create!(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                           relation_type: new_type)
      rescue RelationSemantics::ValidationError => e
        return Preview.result(false, warnings: [ "Cannot retype relation ##{relation.id}: #{e.message}" ])
      end

      effects = [ "Replaces '#{from}' #{relation.relation_type} '#{to}' (##{relation.id}) with '#{from}' #{new_type} '#{to}'" ]
      if RelationTypeSweep.part_of?(new_type)
        size = 1 + ProjectMembership.member_ids(relation.from_entity_id).size
        effects << "'#{from}' (#{size} entit#{size == 1 ? 'y' : 'ies'}) joins " \
                   "#{Preview.project_label(ProjectMembership.project_id_for_parent(MemoryEntity.find(relation.to_entity_id)))}"
      end
      Preview.result(true, effects: effects)
    end
  end
end

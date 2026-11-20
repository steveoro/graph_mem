# frozen_string_literal: true

# Updates or deletes one relation the way `graph_write` / `graph_delete` do when the write moves
# membership: an edge that reads as part_of in SQL (MemoryRelation.reads_as_part_of?) is a
# membership edge, so creating, retyping or removing one takes the membership lock BEFORE the
# transaction (the advisory-first rule), checks the create-time rules for a retype into part_of
# (one parent, no cycle: RelationSemantics.validate_create!) and syncs the child in the same
# transaction, so a ProjectMembership::Collision rolls the write back. Any other write is plain:
# no lock, no sync. Used by the REST relation endpoints and the operator's data-exchange actions;
# neither can move a relation's endpoints, so only the type is checked.
#
#   RelationMembershipWrite.update!(relation, relation_type: "part_of", weight: 0.5)
#   RelationMembershipWrite.destroy!(relation, reason: "wrong parent")
module RelationMembershipWrite
  module_function

  # @param relation [MemoryRelation]
  # @param attributes [Hash] columns to change; `relation_type` may be any spelling (the model
  #   canonicalizes it)
  # @return [MemoryRelation] the updated relation
  # @raise [ActiveRecord::RecordInvalid, RelationSemantics::ValidationError, ProjectMembership::Collision,
  #   ProjectMembership::LockTimeout] nothing is written
  def update!(relation, attributes)
    attributes = attributes.to_h.with_indifferent_access
    was_part_of = MemoryRelation.reads_as_part_of?(relation.relation_type)
    new_type = attributes[:relation_type].presence && MemoryRelation.canonical_relation_type(attributes[:relation_type])
    moves = new_type.present? && was_part_of != MemoryRelation.reads_as_part_of?(new_type)
    with_lock_if(moves) do
      ActiveRecord::Base.transaction do
        if moves && !was_part_of
          RelationSemantics.validate_create!(from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                             relation_type: new_type)
        end
        relation.update!(attributes)
        ProjectMembership.sync!(relation.from_entity) if moves
      end
    end
    relation
  end

  # @param relation [MemoryRelation]
  # @param reason [String, nil] recorded on the audit row (Current.deletion_reason)
  # @return [MemoryRelation] the destroyed relation
  # @raise [ActiveRecord::RecordNotDestroyed, ProjectMembership::Collision, ProjectMembership::LockTimeout]
  #   nothing is deleted
  def destroy!(relation, reason: nil)
    part_of = MemoryRelation.reads_as_part_of?(relation.relation_type)
    with_lock_if(part_of) do
      ActiveRecord::Base.transaction do
        Current.set(deletion_reason: reason) { relation.destroy! }
        # Removing the parent edge un-roots the child (and its subtree): typically back to global.
        child = part_of && MemoryEntity.find_by(id: relation.from_entity_id)
        ProjectMembership.sync!(child) if child
      end
    end
    relation
  end

  # @return [Object] the block's value, under the membership lock when `needed`
  def with_lock_if(needed, &block)
    needed ? ProjectMembership.with_membership_lock(&block) : yield
  end
end

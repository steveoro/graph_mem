# frozen_string_literal: true

module RelationMembershipWrite
  # Deletes one entity the way every delete path does (REST, `graph_delete`, a `delete_entity`
  # review row, the data-exchange delete_node): its `part_of` children move one level up, under
  # the deleted entity's own parent, with their subtrees; when it had no parent they become
  # global, and a name already taken at global scope refuses the delete with nothing changed.
  #
  # `dependent: :destroy` on MemoryEntity removes the entity's edges, so each child gets a new
  # part_of edge to that parent through the validating create path (one parent, no cycle) and is
  # synced (ProjectMembership.sync!) in the same savepoint: a ProjectMembership::Collision rolls the
  # whole delete back. Every delete takes the membership lock first (the advisory-first rule), even
  # for an entity without part_of children: whether it has children is read under the lock, so a
  # child attached meanwhile is still moved and synced in the right order. The lock is reentrant,
  # so callers already under it (graph_delete, a review apply) just raise its refcount, and entity
  # deletes are rare enough that a childless one waiting on it costs little.
  #
  # A `reference_stub` park edge is not ownership (ProjectMembership::OWNED_EDGE_SQL): a parked
  # stub child stays where it is (global) and is not moved, and an entity whose only parent edge
  # is a stub counts as having no parent.
  #
  #   plan = RelationMembershipWrite::EntityDelete.new(entity).plan
  #   plan.summary # => "2 child entities move under 'Alpha Project' (#4)"
  #   RelationMembershipWrite::EntityDelete.new(entity).destroy!(reason: "obsolete")
  class EntityDelete
    # Where an entity's children go when it is deleted.
    # @!attribute child_ids [Array<Integer>] the part_of children that move (stub children excluded)
    # @!attribute parent [MemoryEntity, nil] their new parent; nil when they become global
    Plan = Data.define(:child_ids, :parent) do
      # @return [Integer]
      def child_count = child_ids.size

      # @param past [Boolean] past tense (a result message) instead of present (a preview)
      # @return [String, nil] one line for previews and messages; nil without children
      def summary(past: false)
        return nil if child_ids.empty?

        count = child_ids.size
        noun = count == 1 ? "child entity" : "child entities"
        if parent
          verb = past ? "moved" : (count == 1 ? "moves" : "move")
          "#{count} #{noun} #{verb} under '#{parent.name}' (##{parent.id})"
        else
          verb = past ? (count == 1 ? "was made" : "were made") : (count == 1 ? "becomes" : "become")
          "#{count} #{noun} #{verb} global"
        end
      end

      # The first name a moving child's subtree already holds in the scope it moves to, or nil.
      # Read-only: a preview warns with it, the delete refuses on it.
      # @return [String, nil]
      def collision_name
        target = ProjectMembership.project_id_for_parent(parent)
        MemoryEntity.where(id: child_ids).find_each do |child|
          name = ProjectMembership.collision_name(child, target)
          return name if name
        end
        nil
      end
    end

    # @param entity [MemoryEntity] the entity to delete
    def initialize(entity)
      @entity = entity
    end

    # @return [Plan] where the children would go, read now
    def plan
      Plan.new(child_ids: owned_edges.where(to_entity_id: @entity.id).order(:from_entity_id).distinct.pluck(:from_entity_id),
               parent: parent)
    end

    # @param reason [String, nil] recorded on the audit rows (Current.deletion_reason)
    # @return [Plan] where the children went
    # @raise [ProjectMembership::Collision] a child's name is taken where it moves; nothing deleted
    # @raise [ProjectMembership::LockTimeout] nothing deleted
    # @raise [ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed] nothing deleted
    def destroy!(reason: nil)
      ProjectMembership.with_membership_lock do
        # A savepoint: a caller inside its own transaction (a review apply under its row lock)
        # rescues a refusal and records it, so only this delete may roll back.
        ActiveRecord::Base.transaction(requires_new: true) do
          moves = plan
          Current.set(deletion_reason: reason) { @entity.destroy! }
          MemoryEntity.where(id: moves.child_ids).order(:id).each { |child| reattach(child, moves.parent) }
          moves
        end
      end
    end

    private

    def owned_edges
      MemoryRelation.where(relation_type: "part_of").where(ProjectMembership::OWNED_EDGE_SQL)
    end

    def parent
      parent_id = owned_edges.where(from_entity_id: @entity.id).order(:id).pick(:to_entity_id)
      parent_id && MemoryEntity.find_by(id: parent_id)
    end

    # A child that still has a parent (a second part_of edge, which the single-parent rule forbids)
    # keeps it; a cycle partner that is the parent itself just loses the edge.
    def reattach(child, parent)
      if parent && parent.id != child.id && !MemoryRelation.exists?(from_entity_id: child.id, relation_type: "part_of")
        MemoryRelation.create!(from_entity_id: child.id, to_entity_id: parent.id, relation_type: "part_of")
      end
      ProjectMembership.sync!(child)
    end
  end
end

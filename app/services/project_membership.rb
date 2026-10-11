# frozen_string_literal: true

# Keeps `memory_entities.project_id` in sync with the part_of tree: an
# entity's project is the Project root reachable through its (single)
# part_of parent — or NULL when it has no parent or the tree is unrooted.
#
# When an entity's part_of edge is re-pointed under a different project's
# tree, project_id MUST follow (an entity is a member of exactly the project
# its part_of chain reaches). `reassign!` moves the entity AND its whole
# part_of subtree to the target project, refusing on a name collision: the
# UNIQUE(project_scope, name) key would fail anyway, and surfacing the
# offending name up front beats a mid-transaction index error.
class ProjectMembership
  class Collision < StandardError; end

  # Advisory lock serializing every subtree stamp: the backfill's
  # compute+apply, ProjectMembership.reassign!, and every part_of writer
  # that routes through them. Without it a re-parent landing between the
  # backfill's compute and apply steps gets stamped under its OLD project
  # (probed: move X under PB mid-run → X stamped PA). MariaDB GET_LOCK is
  # reentrant on the same session, so nested writers inside a locked run
  # just raise the refcount.
  LOCK_NAME = "graph_mem.project_membership"
  LOCK_TIMEOUT_SECONDS = 60

  class << self
    # Runs `block` while holding the named advisory lock; other sessions
    # taking the same lock wait up to LOCK_TIMEOUT_SECONDS.
    def with_membership_lock(timeout: LOCK_TIMEOUT_SECONDS)
      conn = ActiveRecord::Base.connection
      acquired = conn.select_value("SELECT GET_LOCK(#{conn.quote(LOCK_NAME)}, #{timeout.to_i})")
      unless acquired == 1 || acquired == true
        raise Collision, "could not acquire #{LOCK_NAME} within #{timeout}s — " \
                         "another import/backfill/graph mutation is running"
      end
      begin
        yield
      ensure
        conn.select_value("SELECT RELEASE_LOCK(#{conn.quote(LOCK_NAME)})")
      end
    end

    # The project implied by a part_of parent: a Project parent means the
    # entity is a direct member of it; any other parent means the entity
    # inherits the parent's own project (NULL when the parent is unrooted).
    def project_id_for_parent(parent)
      return nil unless parent

      parent.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE ? parent.id : parent.project_id
    end

    # Recompute and apply an entity's project from its CURRENT part_of
    # parent. Call after any change to the entity's part_of edge (move,
    # claim, delete of the parent edge).
    def sync!(entity)
      parent_id = MemoryRelation.where(from_entity_id: entity.id, relation_type: "part_of")
                                .pick(:to_entity_id)
      parent = parent_id && MemoryEntity.find_by(id: parent_id)
      reassign!(entity, project_id_for_parent(parent))
    end

    # Move `entity` + its part_of subtree to `target_project_id`
    # (nil = global). Refuses when any member's name already exists in the
    # target scope — re-pointing a subtree into a project that already holds
    # a same-name entity is an operator-level conflict, not a merge.
    # @raise [Collision] when the move would violate UNIQUE(project_scope, name)
    def reassign!(entity, target_project_id)
      with_membership_lock { reassign_locked!(entity, target_project_id) }
    end

    def reassign_locked!(entity, target_project_id)
      return if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      subtree_ids = [ entity.id ] + RelationSemantics.descendant_ids(entity.id).to_a
      subtree_names = MemoryEntity.where(id: subtree_ids).pluck(:name)
      collision = MemoryEntity.where(project_id: target_project_id, name: subtree_names)
                              .where.not(id: subtree_ids).pluck(:name).first
      if collision
        raise Collision,
              "cannot move '#{entity.name}' into project #{target_project_id.inspect}: " \
              "'#{collision}' already exists there"
      end

      # `where.not(project_id: x)` drops NULL rows (SQL NULL != x →
      # UNKNOWN) — spell out the NULL case or stubs are never stamped;
      # a NULL target (move to global) means "any non-NULL row".
      scope = MemoryEntity.where(id: subtree_ids)
      scope = target_project_id.nil? ? scope.where.not(project_id: nil)
                                     : scope.where("project_id IS NULL OR project_id <> ?", target_project_id)
      scope.update_all(project_id: target_project_id)
    end
  end
end

# frozen_string_literal: true

# Keeps `memory_entities.project_id` in sync with the part_of tree: an
# entity's project is the Project root reachable through its (single)
# part_of parent — or NULL when it has no parent or the tree is unrooted.
#
# When an entity's part_of edge is re-pointed under a different project's
# tree, project_id MUST follow (an entity is a member of exactly the project
# its part_of chain reaches). `reassign!` moves the entity AND its member
# subtree to the target project, refusing on a name collision: the
# UNIQUE(project_scope, name) key would fail anyway, and surfacing the
# offending name up front beats a mid-transaction index error.
class ProjectMembership
  # A same-name entity already occupies the target scope.
  class Collision < StandardError; end

  # The advisory membership lock could not be acquired in time — a
  # concurrent import/backfill/move holds it. Retryable: unlike a
  # Collision this is not a name conflict, so callers map it to a
  # "retry shortly" outcome, never to "rename the entity".
  class LockTimeout < StandardError; end

  # Advisory lock serializing every subtree stamp: the backfill's
  # compute+apply, ProjectMembership.reassign!, and every part_of writer
  # that routes through them. Without it a re-parent landing between the
  # backfill's compute and apply steps gets stamped under its OLD project
  # (probed: move X under PB mid-run → X stamped PA). MariaDB GET_LOCK is
  # reentrant on the same session, so nested writers inside a locked run
  # just raise the refcount.
  #
  # LOCK ORDERING (hard rule — a mid-transaction GET_LOCK deadlocks):
  # every membership writer acquires this lock BEFORE opening its
  # transaction / taking row locks. Holding row locks and then blocking
  # on GET_LOCK (while the backfill holds the lock and waits on those
  # very rows) forms a cycle InnoDB cannot see — it surfaces as a ~50s
  # ActiveRecord::LockWaitTimeout on the WRITER. The entry points that
  # wrap their work in with_membership_lock:
  # - imports and the backfill: ImportExecutionStrategy (whole execute),
  #   ProjectIdBackfill.run;
  # - the graph tools: GraphWriteService entity/relation writes,
  #   GraphDeleteService call/execute_one (part_of deletes + merges);
  # - moves, merges and deletes: NodeOperationsStrategy move_node/
  #   merge_into/delete_node, RelationMembershipWrite (update!, destroy!,
  #   destroy_entity!, with_lock_if: the REST and data-exchange writers, the
  #   scan validator, GraphIntegrityService's dangling part_of delete),
  #   RelationIntegrityRepairer, ChangeSetUndo, CompactionReviewService and
  #   CompactionReviewApplier (review applies, relation_retype);
  # - scans: ProjectScanner::MembershipSync (once, after the reconcile
  #   commits: the reconcile's transaction runs LLM and embedding calls, so
  #   the lock can't be taken around or inside it) and ProjectScanSkill
  #   (ensure_part_of: lock, then one savepoint for create + sync);
  # - dream state: DreamStateCompactor.with_membership_lock (the orphans and
  #   tree_walk phases, around each entity's transaction) and
  #   DreamStateCompactionJob (around run.with_lock, whose transaction wraps
  #   the whole batch);
  # - the rake tasks data:migrate_json / data:append_json (whole run, before
  #   any write); data:merge_entity and tools:create_relation reach it
  #   through merge_into and GraphWriteService.
  # FactSupersede::Bulk takes it too, only to order itself against the
  # review applies. reassign! itself takes the lock too so stray callers
  # stay safe (reentrant on the same session).
  #
  # The lock is never held across a network call. The models' inline
  # embeddings are deferred to the outermost block's exit
  # (EmbeddingService::InlineDeferral), so an interactive write is still
  # embedded before it returns; the bulk paths (imports, dream state, the
  # JSON tasks, undo) suppress them and embed later.
  LOCK_NAME_PREFIX = "graph_mem.project_membership"
  LOCK_TIMEOUT_SECONDS = 60
  # How many with_membership_lock blocks this thread is inside (the lock is reentrant).
  LOCK_DEPTH_KEY = :gmem_membership_lock_depth

  # The part_of edges membership follows: every one except a `reference_stub` park edge (see
  # member_ids). COALESCE: edges with NULL properties or no reference_stub key must NOT be filtered
  # out — `NOT(JSON_EXTRACT = ...)` evaluates NULL for them and would drop them along with the stubs.
  OWNED_EDGE_SQL = "COALESCE(JSON_UNQUOTE(JSON_EXTRACT(properties, '$.reference_stub')), 'false') <> 'true'"

  class << self
    # Runs `block` while holding the named advisory lock; other sessions
    # taking the same lock wait up to LOCK_TIMEOUT_SECONDS. The name is
    # namespaced by database so a dev DB and the test DB on the same
    # server never serialize against each other.
    #
    # The lock is never held across a network call: inside it the models' inline embeddings are
    # deferred, and the outermost block embeds them after its RELEASE_LOCK, on every exit (see
    # EmbeddingService::InlineDeferral; suppressed ones are not deferred). A nested block embeds
    # nothing itself.
    # @param timeout [Integer] seconds to wait for the lock
    # @yieldreturn [Object]
    # @return [Object] the block's value
    # @raise [LockTimeout] when the lock stays busy for `timeout` seconds
    def with_membership_lock(timeout: LOCK_TIMEOUT_SECONDS, &block)
      EmbeddingService.defer_inline_embeddings { hold_membership_lock(timeout, &block) }
    end

    # @return [Boolean] whether this thread is inside a with_membership_lock block (the depth is kept
    #   per execution context, like the connection that holds the session's lock)
    def membership_lock_held?
      ActiveSupport::IsolatedExecutionState[LOCK_DEPTH_KEY].to_i.positive?
    end

    def hold_membership_lock(timeout)
      conn = ActiveRecord::Base.connection
      name = lock_name(conn)
      # Both lock statements MUST bypass the ActiveRecord query cache: inside
      # a request (or any executor-wrapped block) SELECTs are query-cached,
      # and the nested sequence acquire → write (clears the cache) → inner
      # release → outer release would serve the outer RELEASE_LOCK from the
      # cache. The statement never reaches MariaDB and the pooled session
      # keeps the lock until the connection is recycled — every other
      # writer then waits out the full timeout.
      acquired = conn.uncached do
        conn.select_value("SELECT GET_LOCK(#{conn.quote(name)}, #{timeout.to_i})")
      end
      unless acquired == 1 || acquired == true
        raise LockTimeout, "could not acquire #{name} within #{timeout}s — " \
                           "another import, backfill, move or merge holds the membership lock"
      end
      state = ActiveSupport::IsolatedExecutionState
      depth = state[LOCK_DEPTH_KEY].to_i
      state[LOCK_DEPTH_KEY] = depth + 1
      begin
        yield
      ensure
        state[LOCK_DEPTH_KEY] = depth
        conn.uncached do
          conn.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})")
        end
      end
    end
    private :hold_membership_lock

    def lock_name(conn = ActiveRecord::Base.connection)
      "#{LOCK_NAME_PREFIX}:#{conn.current_database}"
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

    # Move `entity` + its member subtree to `target_project_id`
    # (nil = global). Refuses when any member's name already exists in the
    # target scope — re-pointing a subtree into a project that already holds
    # a same-name entity is an operator-level conflict, not a merge.
    # @raise [Collision] when the move would violate UNIQUE(project_scope, name)
    # @raise [LockTimeout] when the advisory lock cannot be acquired
    def reassign!(entity, target_project_id)
      with_membership_lock { reassign_locked!(entity, target_project_id) }
    end

    # The first name of `entity`'s subtree (itself and its members) already taken in the target
    # scope by an entity outside the subtree, or nil. Read-only: a preview asks it, reassign! refuses on it.
    # @param entity [MemoryEntity]
    # @param target_project_id [Integer, nil] nil = the global scope
    # @param subtree_ids [Array<Integer>, nil] the subtree when the caller has it already
    # @return [String, nil]
    def collision_name(entity, target_project_id, subtree_ids: nil)
      subtree_ids ||= [ entity.id ] + member_ids(entity.id).to_a
      subtree_names = MemoryEntity.where(id: subtree_ids).pluck(:name)
      MemoryEntity.where(project_id: target_project_id, name: subtree_names).where.not(id: subtree_ids).pick(:name)
    end

    def reassign_locked!(entity, target_project_id)
      return if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

      subtree_ids = [ entity.id ] + member_ids(entity.id).to_a
      collision = collision_name(entity, target_project_id, subtree_ids: subtree_ids)
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

    # Member ids of a scope rooted at `root_id`, walking part_of edges
    # breadth-first — NOT RelationSemantics.descendant_ids: two
    # edge/entity kinds stop the walk (the SAME rule the backfill
    # applies, so a re-parent stamps exactly the rows the backfill
    # recomputes):
    # (a) `reference_stub: true` edges park an unresolved target in the
    #     GLOBAL namespace for whichever project declares it first — the
    #     referencing project does not own it. Following them stamps the
    #     stub into the referencer's scope, after which it can never be
    #     claimed and the declarer creates a duplicate.
    # (b) Nested Project children: a Project inside another project's
    #     tree starts its OWN scope (nearest-Project wins, matching
    #     project_id_for_parent). Its row stays NULL — Projects are
    #     global — and its members belong to ITS scope, not the outer
    #     one; stamping them under the moved entity's new project makes
    #     them unreachable by their real root.
    def member_ids(root_id)
      ids = Set.new
      queue = [ root_id ]
      until queue.empty?
        current = queue.shift
        MemoryRelation.where(to_entity_id: current, relation_type: "part_of").where(OWNED_EDGE_SQL)
          .pluck(:from_entity_id).each do |child_id|
            next if ids.include?(child_id)
            next if project_entity_ids.include?(child_id) # nested Project: its own scope

            ids.add(child_id)
            queue << child_id
          end
      end
      ids
    end

    # Fresh every call — a memoized set goes stale when Projects are
    # created/destroyed between membership operations (and across spec
    # resets), which would treat a new nested Project as a member of the
    # outer scope and stamp it.
    def project_entity_ids
      MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).pluck(:id).to_set
    end
  end
end

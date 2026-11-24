# frozen_string_literal: true

class ProjectScanner
  # The project moves of the part_of edges the model emitted (private methods of ProjectScanner;
  # they read and set its instance variables). A part_of moves its child, with the child's subtree,
  # into its parent's project (ProjectMembership.sync!), and that takes the membership lock, which
  # must come before any transaction (the advisory-first rule, ProjectMembership::LOCK_NAME_PREFIX)
  # and is never held across an LLM or other network call. #reconcile's transaction runs inline LLM
  # word batches and embedding calls between its writes, so the lock can be neither taken around it
  # nor inside it: #reconcile_relation creates the edge there without a sync, and
  # #sync_part_of_children! syncs each child after the commit, under one lock, one transaction each.
  #
  # A child whose move collides (its name, or a member's, is taken in the parent's project) stays
  # in the scanned project: its model edge is replaced by a containment edge to the root, as
  # Containment gives an entity the model left without a parent, and the conflict is recorded in
  # the scan's errors. Until the sync runs, the child keeps the project the scan stamped.
  module MembershipSync
    COLLISION_REASON = "project scan: the part_of target's project already holds the name"

    private

    # @param relation [MemoryRelation] a part_of edge #reconcile_relation created
    def defer_part_of_sync(relation)
      (@part_of_relation_ids ||= []) << relation.id
    end

    # After #reconcile commits: lock, then sync each child whose part_of the model emitted.
    def sync_part_of_children!
      return if @part_of_relation_ids.blank?

      ProjectMembership.with_membership_lock do
        MemoryRelation.where(id: @part_of_relation_ids).includes(:from_entity).find_each { |relation| sync_part_of_child!(relation) }
      end
    rescue StandardError => e
      # A busy lock (or a failed write) leaves the stamps the scan wrote; the backfill repairs them.
      @logger.warn "ProjectScanner: part_of sync failed: #{e.class}: #{e.message}"
      @errors << "Project scope not synced for #{@part_of_relation_ids.size} part_of edge(s): #{e.message}; " \
                 "run bin/rails graph_mem:backfill_project_ids"
    end

    def sync_part_of_child!(relation)
      child = relation.from_entity
      ActiveRecord::Base.transaction(requires_new: true) { ProjectMembership.sync!(child) }
    rescue ProjectMembership::Collision => e
      keep_in_project!(relation, child)
      @errors << "Project scope conflict for #{child.name}: #{e.message}; kept under #{@project_entity.name}"
    end

    # The refused sync wrote nothing, so the child still carries the root's stamp: under the root,
    # it needs no sync (Containment).
    def keep_in_project!(relation, child)
      ActiveRecord::Base.transaction(requires_new: true) do
        Current.set(deletion_reason: COLLISION_REASON) { relation.destroy! }
        @relations_created_count -= 1 # the containment edge below takes its place in the count
        attach_to_root!([ child ])
      end
    end
  end
end

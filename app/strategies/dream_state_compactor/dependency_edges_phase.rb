# frozen_string_literal: true

class DreamStateCompactor
  # Phase `dependency_edges` (Dream State R1b), after `relation_types` and before `orphans`: queues
  # a `relation_retype` row with `operation: "swap"` for each `part_of` edge from an entity of a
  # dependency-like type (DependencyLikeTypes, the setting) to a Project, so the operator (or the
  # auto_apply_relation_retype policy) can turn it into the Project's `depends_on` it. Its evidence
  # is the entity's type and the project's facts that say it uses or used the entity
  # (DependencyEvidence, bounded, no LLM). A row pending, applied or dismissed with the same
  # signature (one per edge) is never queued again (CompactionReviewService.suppressed?; the seed
  # dedupes too).
  #
  # It writes nothing but review rows, so it takes no membership lock. It walks the candidate edges
  # by relation id, BATCH_SIZE per job, its cursor in the run's stats ("dependency_cursor_id"); a
  # blank setting has no candidates. Pause is checked after each batch. The run counts the rows it
  # seeded in "dependency_swaps_queued".
  #
  # Once the swap pass is done ("dependency_pass" in the stats), the same job goes on with R1c's
  # removal pass (RemovalEvidencePass), and the phase ends when that pass is done too.
  #
  # The module also holds phase `orphans`' side of R1b (#queue_dependency_add): a dependency-like
  # orphan gets an "add" row ("dependency_adds_queued") instead of a parent.
  module DependencyEdgesPhase
    PHASE = "dependency_edges"
    BATCH_SIZE = 200

    private

    # @return [Symbol] :continued, :paused or :completed (as #process_batch!)
    def process_dependency_edges_batch!
      stats = @run.stats || {}
      return process_removal_batch! if stats["dependency_pass"] == RemovalEvidencePass::PASS

      cursor = stats["dependency_cursor_id"].to_i
      edges = dependency_candidates(cursor)
      edges.each { |relation| queue_swap(relation) }
      flush_review_queue!
      @run.merge_stats!("dependency_cursor_id" => edges.last&.id || cursor,
                        "dependency_edges_checked" => stats["dependency_edges_checked"].to_i + edges.size)
      broadcast_progress(PHASE, step: 0, message: "Checked #{edges.size} dependency-like part_of edge(s)") if edges.any?

      return start_removal_pass! if edges.size < BATCH_SIZE

      pause_or_continue!
    end

    # The swap pass is done: R1c's removal pass starts in the same job.
    def start_removal_pass!
      @run.merge_stats!("dependency_pass" => RemovalEvidencePass::PASS)
      process_removal_batch!
    end

    def pause_or_continue!
      if @run.reload.pause_requested?
        @run.pause!
        broadcast_operation(message: "Compaction paused")
        return :paused
      end
      :continued
    end

    # The part_of edges after `cursor` from a dependency-like entity to a Project, by id.
    # @return [Array<MemoryRelation>]
    def dependency_candidates(cursor)
      types = dependency_types
      return [] if types.empty? || types.stored_types.empty?

      MemoryRelation.where(relation_type: RelationTypeSweep::PART_OF).where("memory_relations.id > ?", cursor)
                    .where(from_entity_id: MemoryEntity.where(entity_type: types.stored_types).select(:id))
                    .where(to_entity_id: MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE, project_id: nil).select(:id))
                    .includes(:from_entity, :to_entity).order(:id).limit(BATCH_SIZE).to_a
    end

    def queue_swap(relation)
      library = relation.from_entity
      project = relation.to_entity
      names = { library.id => library.name, project.id => project.name }
      item = CompactionReviewApplier::RelationRetypeDependency.swap_item(relation, names,
                                                                          evidence: DependencyEvidence.for_swap(library, project))
      @review_items << item unless CompactionReviewService.suppressed?(item[:kind], item)
    end

    def finish_dependency_edges!
      advance_phase!(PHASE)
      broadcast_operation(message: @run.completed? ? "Compaction completed" : "Completed #{PHASE} phase")
      @run.reload.completed? ? :completed : :continued
    end

    # Phase `orphans` for a dependency-like orphan: an "add" row (the best-matching Project
    # depends_on it) instead of an auto-parent or an orphan_parent row. Deliberately not a
    # relationship_proposal, which AutoApplyRelationships could apply unattended.
    # @param orphan [MemoryEntity]
    # @param best [Hash] the best OrphanMatchingStrategy match (`project:`, `score:`, `matched_tokens:`)
    def queue_dependency_add(orphan, best)
      evidence = { entity_type: orphan.entity_type, score: best[:score], matched_tokens: best[:matched_tokens] }
      item = CompactionReviewApplier::RelationRetypeDependency.add_item(best[:project], orphan, evidence: evidence)
      @review_items << item unless CompactionReviewService.suppressed?(item[:kind], item)
    end

    # The setting, read once per compactor (one batch).
    def dependency_types
      @dependency_types ||= DependencyLikeTypes.current
    end
  end
end

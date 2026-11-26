# frozen_string_literal: true

class DreamStateCompactor
  # The second pass of phase `dependency_edges` (Dream State R1c), once the swap pass is done: queues
  # an informational `relation_review` row when a fact of a project says that an entity the Project
  # still depends_on, or holds by a direct part_of, was removed, replaced or dropped
  # (RemovalEvidence, deterministic, no LLM). It reads the same edges as the swap pass (a Project's
  # dependencies) and the same project facts as the swap's evidence, so it shares its phase rather
  # than adding one.
  #
  # One row per (relation, fact), at most MAX_FACTS new ones per relation and run; a row pending,
  # applied or dismissed with the same signature is never queued again. It writes nothing but review
  # rows and takes no membership lock. It walks the edges by relation id, BATCH_SIZE per job, its
  # cursor in the run's stats ("removal_cursor_id"); pause is checked after each batch. The run
  # counts the edges it read in "removal_edges_checked" and the rows it seeded in
  # "relation_reviews_queued".
  module RemovalEvidencePass
    PASS = "removal"
    BATCH_SIZE = 200
    MAX_FACTS = 3

    private

    # @return [Symbol] :continued, :paused or :completed (as #process_batch!)
    def process_removal_batch!
      stats = @run.stats || {}
      cursor = stats["removal_cursor_id"].to_i
      edges = RemovalEvidence.edges(after_id: cursor, limit: BATCH_SIZE)
      edges.each { |relation| queue_relation_reviews(relation) }
      flush_review_queue!
      @run.merge_stats!("removal_cursor_id" => edges.last&.id || cursor,
                        "removal_edges_checked" => stats["removal_edges_checked"].to_i + edges.size)
      broadcast_progress(DependencyEdgesPhase::PHASE, step: 0, message: "Checked #{edges.size} edge(s) for removal facts") if edges.any?

      return finish_dependency_edges! if edges.size < BATCH_SIZE

      pause_or_continue!
    end

    def queue_relation_reviews(relation)
      RemovalEvidence.facts(relation).lazy
                     .map { |fact| CompactionReviewApplier::RelationReview.item(relation, fact) }
                     .reject { |item| CompactionReviewService.suppressed?(item[:kind], item) }
                     .first(MAX_FACTS).each { |item| @review_items << item }
    end
  end
end

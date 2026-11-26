# frozen_string_literal: true

# Compacts the knowledge graph during dream-state background runs:
# - Relation-types phase: canonicalize stored relation types (RelationTypesPhase, RelationTypeSweep)
# - Dependency-edges phase: queue a relation_retype "swap" row for each dependency-like entity
#   part_of a Project (DependencyEdgesPhase, R1b)
# - Orphan phase: auto-parent high-confidence matches, queue the rest; a dependency-like orphan
#   gets an "add" row (Project depends_on it) instead (R1b)
# - Tree-walk phase: dedupe identical observations, auto-merge very similar entities
#
# Every write is attributed to the run: the auto-parent and the auto-merge are change sets
# (`compaction.auto_parent`, `compaction.auto_merge`) whose audit rows carry the actor
# `compaction:<run id>`, as the relation-types phase's do, and so do the observation dedupe's.
class DreamStateCompactor
  include RelationTypesPhase
  include DependencyEdgesPhase

  AUTO_MERGE_DISTANCE = 0.10
  REVIEW_MERGE_DISTANCE = 0.30
  AUTO_ORPHAN_SCORE = OrphanMatchingStrategy::AUTO_PARENT_SCORE
  BATCH_SIZE = ENV.fetch("DREAM_STATE_BATCH_SIZE", "1").to_i.clamp(1, 50)
  # The phases whose per-entity work can move an entity (an orphan's auto-parent) or merge one
  # (tree_walk's auto-merge): both take the membership lock.
  MEMBERSHIP_PHASES = %w[orphans tree_walk].freeze

  # @param phase [String, Symbol, nil] a run's phase
  # @return [Boolean] true when the phase can move or merge entities, so it needs the membership lock
  def self.membership_phase?(phase)
    MEMBERSHIP_PHASES.include?(phase.to_s)
  end

  # Runs the block under the membership lock when +phase+ can move or merge entities, so the lock is
  # taken before any transaction the block opens (the advisory-first rule, see
  # ProjectMembership::LOCK_NAME_PREFIX); merge_into and move_to_parent then re-enter it. Used around
  # each entity's transaction, and by DreamStateCompactionJob around run.with_lock, whose transaction
  # wraps the whole batch. Inline embeddings are suppressed inside (unattended batch work), not
  # deferred to the lock's exit as an interactive merge's are: the embedding backfill re-embeds a
  # merge survivor (enqueued after an auto-merge). These phases make no LLM call (orphan and merge
  # evidence come from the database).
  #
  # @param phase [String, nil] the run's phase
  # @return [Object] the block's value
  def self.with_membership_lock(phase, &block)
    return yield unless membership_phase?(phase)

    ProjectMembership.with_membership_lock { EmbeddingService.suppress_inline_embeddings(&block) }
  end

  def initialize(
    run:,
    traversal: CompactionTraversal.new,
    orphan_matcher: OrphanMatchingStrategy.new,
    node_ops: NodeOperationsStrategy.new,
    relationship_discovery: RelationshipDiscoveryStrategy.new
  )
    @run = run
    @traversal = traversal
    @orphan_matcher = orphan_matcher
    @node_ops = node_ops
    @relationship_discovery = relationship_discovery
    @review_items = []
  end

  # Process one batch for the current run. Returns :paused, :completed, or :continued.
  def process_batch!
    @run.reload
    return :paused if @run.paused?

    phase = @run.phase.presence || CompactionTraversal::PHASES.first
    @run.update!(phase: phase, status: "running", started_at: @run.started_at || Time.current) unless @run.running?
    return process_relation_types_batch! if phase == RelationTypesPhase::PHASE
    return process_dependency_edges_batch! if phase == DependencyEdgesPhase::PHASE

    entity_ids = @traversal.entity_ids_for_phase(phase)
    start_idx = cursor_start_index(entity_ids)

    if start_idx >= entity_ids.length
      advance_phase!(phase)
      return @run.reload.status == "completed" ? :completed : :continued
    end

    entity_ids[start_idx, BATCH_SIZE].each do |entity_id|
      @run.update!(cursor_entity_id: entity_id)
      @run.increment_stat!("entities_processed")

      begin
        self.class.with_membership_lock(phase) do
          ActiveRecord::Base.transaction(requires_new: true) do
            process_entity_for_phase(phase, entity_id)
          end
        end
      rescue StandardError => e
        log_entity_error(entity_id, phase, e)
        @run.increment_stat!("entity_errors")
      end

      flush_review_queue!
      broadcast_progress(phase, entity_id)

      if @run.reload.pause_requested?
        @run.pause!
        flush_review_queue!
        broadcast_operation(message: "Compaction paused")
        return :paused
      end
    end

    if start_idx + BATCH_SIZE >= entity_ids.length
      advance_phase!(phase)
      broadcast_operation(message: @run.completed? ? "Compaction completed" : "Completed #{phase} phase")
      return @run.reload.status == "completed" ? :completed : :continued
    end

    flush_review_queue!
    :continued
  end

  private

  def cursor_start_index(entity_ids)
    return 0 if @run.cursor_entity_id.blank?

    idx = entity_ids.index(@run.cursor_entity_id)
    return idx + 1 if idx

    # Cursor entity may have been deleted (e.g. merged away). Resume after its id.
    entity_ids.bsearch_index { |id| id > @run.cursor_entity_id } || entity_ids.length
  end

  def advance_phase!(phase)
    flush_review_queue!

    next_phase = @traversal.next_phase_after(phase)
    if next_phase
      @run.update!(phase: next_phase, cursor_entity_id: nil)
    else
      @run.mark_completed!
    end
  end

  # @param step [Integer] how many items the batch processed (relations count one each)
  def broadcast_progress(phase, entity_id = nil, step: 1, message: nil)
    operation = @run.operation_progress
    return unless operation

    operation.update_progress!(
      current: operation.current_count.to_i + step,
      total: operation.total_count,
      phase: phase,
      message: message || (entity_id ? "Processed entity ##{entity_id}" : "Processing #{phase}"),
      counters: @run.reload.stats
    )
    OperationProgressBroadcaster.call(operation)
  end

  def broadcast_operation(message:)
    operation = @run.operation_progress
    return unless operation

    if @run.completed?
      operation.complete!(current: operation.total_count, message: message, counters: @run.reload.stats)
    elsif @run.paused?
      operation.pause!(message: message)
    else
      operation.update!(message: message, phase: @run.phase, counters: @run.reload.stats)
    end
    OperationProgressBroadcaster.call(operation)
  end

  def process_entity_for_phase(phase, entity_id)
    case phase
    when "orphans"
      process_orphan(entity_id)
    when "tree_walk"
      process_entity_merges(entity_id)
      dedupe_observations_for_entity(entity_id)
    when "relationship_discovery"
      process_relationship_discovery(entity_id)
    end
  end

  def process_relationship_discovery(entity_id)
    project_id = ProjectSubtree.ancestor_project_id(entity_id)
    scope_ids = project_id ? ProjectSubtree.resolve(project_id).entity_ids : [ entity_id ]

    @relationship_discovery.proposals_for_entity(entity_id, scope_entity_ids: scope_ids).each do |proposal|
      next if CompactionReviewService.suppressed?(proposal[:kind], proposal)

      @review_items << proposal
    end
  end

  def process_orphan(entity_id)
    orphan = MemoryEntity.find_by(id: entity_id)
    return unless orphan

    matches = @orphan_matcher.match_to_projects(orphan)
    best = matches.first
    return unless best # no suggestion: stays an orphan, visible on Explore
    # R1b: a project uses a dependency-like entity rather than owns it: no part_of, an "add" row.
    return queue_dependency_add(orphan, best) if dependency_types.entity?(orphan)

    if @orphan_matcher.auto_parent_match?(matches)
      # One change set per auto-parent, attributed to the run (undoable like an auto-merge).
      result = record_compaction_change("compaction.auto_parent", orphan) { @node_ops.move_to_parent(orphan.id, best[:project].id) }
      if result[:success]
        @run.increment_stat!("orphans_parented")
      else
        queue_orphan_review(orphan, matches, error: result[:error])
      end
    else
      queue_orphan_review(orphan, matches)
    end
  end

  def queue_orphan_review(orphan, matches, error: nil)
    item = {
      id: SecureRandom.uuid,
      kind: "orphan_parent",
      entity_id: orphan.id,
      entity_name: orphan.name,
      entity_type: orphan.entity_type,
      suggested_parents: matches.first(3).map do |m|
        {
          project_id: m[:project].id,
          project_name: m[:project].name,
          score: m[:score],
          matched_tokens: m[:matched_tokens]
        }
      end,
      error: error
    }.compact

    return false if CompactionReviewService.suppressed?(item[:kind], item)

    @review_items << item
    true
  end

  def dedupe_observations_for_entity(entity_id)
    return unless MemoryEntity.exists?(id: entity_id)

    duplicates = MemoryObservation.active
      .where(memory_entity_id: entity_id)
      .select(:content)
      .group(:content)
      .having("COUNT(*) > 1")
      .pluck(:content)

    duplicates.each do |content|
      observations = MemoryObservation.active
        .where(memory_entity_id: entity_id, content: content)
        .order(:id)
        .to_a

      next if observations.size <= 1

      begin
        Current.deletion_reason = "duplicate"
        Current.set(actor: compaction_actor) { observations.drop(1).each(&:destroy!) }
      ensure
        Current.deletion_reason = nil
      end
      @run.increment_stat!("observations_deduped", observations.size - 1)
    end
  end

  def embedding_sql_literal(entity)
    return if entity.embedded_at.blank?

    vector = entity.embedding.to_s.unpack("e*")
    return if vector.empty?

    text = "[#{vector.join(',')}]"
    quoted = ActiveRecord::Base.connection.quote(text)
    "VEC_FromText(#{quoted})"
  rescue StandardError
    nil
  end

  def process_entity_merges(entity_id)
    entity = MemoryEntity.find_by(id: entity_id)
    return unless entity
    return if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE

    candidates = EntityMergeEvidence.candidates_for(entity)
    return if candidates.empty?

    best = candidates.first
    # Near-identical embeddings plus composite lexical/shared evidence.
    if best.distance < AUTO_MERGE_DISTANCE && best.score >= EntityMergeEvidence::AUTO_SCORE
      merged, survivor = EntityMergeEvidence.pick_survivor(best.source, best.target)
      # One change set per auto-merge, attributed to the run (undoable for 7 days).
      result = record_compaction_change("compaction.auto_merge", survivor) { @node_ops.merge_into(merged.id, survivor.id) }
      if result[:success]
        @run.increment_stat!("merges_auto")
        enqueue_embedding_backfill
        return
      end

      queue_merge_review(best.source, best.target, best.distance, best.score, error: result[:error])
      return
    end

    queue_merge_review(best.source, best.target, best.distance, best.score)
  end

  # The survivor's aliases changed with inline embeddings off (with_membership_lock): re-embedding it
  # is the backfill's job. Queued once every open transaction commits (at once when none is open):
  # the queue can live in its own database, and a backfill that ran before the merge committed would
  # not see the survivor's cleared embedding. A failed enqueue never undoes the merge.
  def enqueue_embedding_backfill
    ActiveRecord.after_all_transactions_commit do
      EmbeddingsMaintenanceEnqueuer.enqueue!("backfill")
    rescue StandardError => e
      Rails.logger.warn "[DreamState] could not enqueue the embedding backfill: #{e.message}"
    end
  end

  def queue_merge_review(entity_a, entity_b, distance, score, error: nil)
    item = {
      id: SecureRandom.uuid,
      kind: "entity_merge",
      entity_a: { entity_id: entity_a.id, name: entity_a.name, entity_type: entity_a.entity_type },
      entity_b: { entity_id: entity_b.id, name: entity_b.name, entity_type: entity_b.entity_type },
      cosine_distance: distance.round(4),
      score: score,
      recommendation: "review_manually",
      error: error
    }.compact

    return false if CompactionReviewService.suppressed?(item[:kind], item)

    @review_items << item
    true
  end

  # @return [String] the actor of every write of this run ("compaction:<run id>")
  def compaction_actor = "compaction:#{@run.id}"

  # Runs a write as one change set of `kind`, attributed to the run: the set's actor and, through
  # Current.actor, every audit row it writes.
  def record_compaction_change(kind, subject, &block)
    Current.set(actor: compaction_actor) { ChangeSet.record(kind: kind, actor: compaction_actor, subject: subject, &block) }
  end

  def log_entity_error(entity_id, phase, error)
    message = "[DreamState] entity #{entity_id} in phase #{phase} failed: #{error.class} - #{error.message}"
    Rails.logger.error(message)

    @review_items << {
      id: SecureRandom.uuid,
      kind: "entity_error",
      entity_id: entity_id,
      phase: phase,
      error_class: error.class.name,
      error_message: error.message
    }
  end

  # Run stats for the kinds the compactor queues, keyed by row kind; relation_retype rows by
  # operation (R1b: "swap" from dependency_edges, "add" from orphans).
  QUEUED_STATS = { "entity_merge" => "merges_queued", "relationship_proposal" => "relationships_queued",
                   "orphan_parent" => "orphans_queued" }.freeze
  QUEUED_RETYPE_STATS = { "swap" => "dependency_swaps_queued", "add" => "dependency_adds_queued" }.freeze

  # Seeds the buffered items; the *_queued stats count the rows actually seeded (after suppression,
  # dedupe, the per-run cap and the backlog ceiling), not the candidates.
  def flush_review_queue!
    rows = CompactionReviewService.seed_report(
      report_type: "compaction_review",
      source: "compaction_run",
      source_ref: @run.id,
      items: @review_items
    )
    rows.group_by { |row| queued_stat(row) }.each do |stat, seeded|
      @run.increment_stat!(stat, seeded.size) if stat
    end
    @review_items.clear
  end

  def queued_stat(row)
    return QUEUED_STATS[row.kind] unless row.kind == RelationTypeSweep::REVIEW_KIND

    QUEUED_RETYPE_STATS[row.payload["operation"].to_s]
  end
end

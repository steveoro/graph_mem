# frozen_string_literal: true

# Compacts the knowledge graph during dream-state background runs:
# - Orphan phase: auto-parent high-confidence matches, queue the rest
# - Tree-walk phase: dedupe identical observations, auto-merge very similar entities
class DreamStateCompactor
  AUTO_MERGE_DISTANCE = 0.10
  REVIEW_MERGE_DISTANCE = 0.30
  AUTO_ORPHAN_SCORE = 10
  BATCH_SIZE = 1

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
        ActiveRecord::Base.transaction(requires_new: true) do
          process_entity_for_phase(phase, entity_id)
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
    idx ? idx + 1 : 0
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

  def broadcast_progress(phase, entity_id = nil)
    operation = @run.operation_progress
    return unless operation

    operation.update_progress!(
      current: operation.current_count.to_i + 1,
      total: operation.total_count,
      phase: phase,
      message: entity_id ? "Processed entity ##{entity_id}" : "Processing #{phase}",
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
    @relationship_discovery.proposals_for_entity(entity_id).each do |proposal|
      @review_items << proposal
      @run.increment_stat!("relationships_queued")
    end
  end

  def process_orphan(entity_id)
    orphan = MemoryEntity.find_by(id: entity_id)
    return unless orphan

    matches = @orphan_matcher.match_to_projects(orphan)
    best = matches.first
    return queue_orphan_review(orphan, matches) unless best

    if best[:score] >= AUTO_ORPHAN_SCORE
      result = @node_ops.move_to_parent(orphan.id, best[:project].id)
      if result[:success]
        @run.increment_stat!("orphans_parented")
      else
        queue_orphan_review(orphan, matches, error: result[:error])
      end
    else
      queue_orphan_review(orphan, matches)
      @run.increment_stat!("orphans_queued")
    end
  end

  def queue_orphan_review(orphan, matches, error: nil)
    @review_items << {
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
  end

  def dedupe_observations_for_entity(entity_id)
    return unless MemoryEntity.exists?(id: entity_id)

    duplicates = MemoryObservation
      .where(memory_entity_id: entity_id)
      .select(:content)
      .group(:content)
      .having("COUNT(*) > 1")
      .pluck(:content)

    duplicates.each do |content|
      observations = MemoryObservation
        .where(memory_entity_id: entity_id, content: content)
        .order(:id)
        .to_a

      next if observations.size <= 1

      observations.drop(1).each(&:destroy!)
      @run.increment_stat!("observations_deduped", observations.size - 1)
    end
  end

  def embedding_sql_literal(entity)
    return if entity.embedding.blank?

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
    return if entity.embedding.blank?

    source_vector_sql = embedding_sql_literal(entity)
    return unless source_vector_sql

    candidates = MemoryEntity
      .where.not(id: entity.id)
      .where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
      .where.not(embedding: nil)
      .where("id > ?", entity.id)
      .select("memory_entities.*, VEC_DISTANCE_COSINE(embedding, #{source_vector_sql}) AS vec_distance")
      .having("vec_distance < ?", REVIEW_MERGE_DISTANCE)
      .order(Arel.sql("vec_distance ASC"))
      .limit(3)
      .to_a

    candidates.each do |candidate|
      distance = candidate[:vec_distance].to_f

      if distance < AUTO_MERGE_DISTANCE
        result = @node_ops.merge_into(entity.id, candidate.id)
        if result[:success]
          @run.increment_stat!("merges_auto")
          return
        end
      else
        queue_merge_review(entity, candidate, distance)
        @run.increment_stat!("merges_queued")
      end
    end
  end

  def queue_merge_review(entity_a, entity_b, distance)
    @review_items << {
      id: SecureRandom.uuid,
      kind: "entity_merge",
      entity_a: { entity_id: entity_a.id, name: entity_a.name, entity_type: entity_a.entity_type },
      entity_b: { entity_id: entity_b.id, name: entity_b.name, entity_type: entity_b.entity_type },
      cosine_distance: distance.round(4),
      recommendation: "review_manually"
    }
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

  def flush_review_queue!
    return if @review_items.empty?

    MaintenanceReport.create!(
      report_type: "compaction_review",
      data: {
        run_id: @run.id,
        phase: @run.phase,
        count: @review_items.size,
        items: @review_items.first(100)
      }
    )
    @review_items.clear
  end
end

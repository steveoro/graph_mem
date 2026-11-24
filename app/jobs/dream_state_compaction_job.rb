# frozen_string_literal: true

class DreamStateCompactionJob < ApplicationJob
  queue_as :default

  # How long a batch waits to run again when the membership lock stayed busy.
  LOCK_RETRY_WAIT = 1.minute

  # Re-enqueue while work remains so recurring triggers can also resume paused runs.
  def perform(run_id = nil)
    unless AppSettings.dream_state_compactor_enabled?
      Rails.logger.info("[DreamState] Skipping compaction — dream-state compactor is disabled")
      return
    end

    run = resolve_run(run_id)
    return unless run
    return if run.status.in?(%w[completed failed])

    if preflight_pending?(run)
      begin
        result = GraphIntegrityService.call
        queue_integrity_issues(run, result)
        log_integrity_summary(result)
      rescue StandardError => e
        Rails.logger.error "[DreamState] Pre-flight integrity sweep failed: #{e.message}"
      end
      run.merge_stats!("integrity_sweep_done" => true)
    end

    # run.with_lock's transaction wraps the batch, so a batch that can move or merge entities takes
    # the membership lock before it (DreamStateCompactor.with_membership_lock). The phase is read
    # fresh for that choice; if an overlapping slice still advanced the run into a membership phase
    # before the row lock, this slice runs again instead of taking the lock inside the transaction.
    locked_phase = run.reload.phase
    DreamStateCompactor.with_membership_lock(locked_phase) do
      run.with_lock do
        run.reload
        return if run.status.in?(%w[completed failed])

        if DreamStateCompactor.membership_phase?(run.phase) && !DreamStateCompactor.membership_phase?(locked_phase)
          self.class.perform_later(run.id)
          return
        end

        compactor = DreamStateCompactor.new(run: run)
        result = compactor.process_batch!

        case result
        when :continued
          self.class.perform_later(run.id)
        when :paused, :completed
          Rails.logger.info "[DreamState] run #{run.id} #{result}"
          enqueue_review_policies(run) if result == :completed
        end
      end
    end
  rescue ProjectMembership::LockTimeout => e
    # An import, backfill or merge holds the lock: the batch runs later and the run isn't failed.
    Rails.logger.warn "[DreamState] run #{run&.id} waits for the membership lock: #{e.message}"
    self.class.set(wait: LOCK_RETRY_WAIT).perform_later(run.id) if run
  rescue StandardError => e
    run&.mark_failed!(e)
    if run&.operation_progress
      run.operation_progress.fail!(e)
      OperationProgressBroadcaster.call(run.operation_progress)
    end
    Rails.logger.error "[DreamState] run #{run_id} failed: #{e.message}"
    raise
  end

  private

  # Once per run, before its first batch. The relation_types phase (first since R1a) keeps its
  # cursor in the stats, not in cursor_entity_id, so the run records that the sweep ran; a run
  # started before R1a has no flag and still runs it only while nothing was processed.
  def preflight_pending?(run)
    stats = run.stats || {}
    return false if stats["integrity_sweep_done"]

    run.cursor_entity_id.blank? && stats["entities_processed"].to_i.zero? && stats["relations_processed"].to_i.zero?
  end

  # Policies run after a completed compaction run that seeded review rows (any flush or the sweep).
  def enqueue_review_policies(run)
    reports = MaintenanceReport.by_type("compaction_review").where("JSON_VALUE(data, '$.source_ref') = ?", run.id.to_s)
    ReviewPolicyJob.enqueue_if_seeded(trigger: "compaction",
                                      seeded: MaintenanceReportRow.where(maintenance_report_id: reports.select(:id)).exists?)
  end

  def resolve_run(run_id)
    run_id ? CompactionRun.find_by(id: run_id) : CompactionRunner.acquire_run!
  end

  def queue_integrity_issues(run, result)
    review_items = []

    (result.dig(:embeddings_backfilled, :failed) || []).each do |failed|
      review_items << {
        id: SecureRandom.uuid,
        kind: "embedding_backfill_failed",
        entity_id: failed[:entity_id],
        entity_name: failed[:name],
        issue: "Embedding backfill failed — Ollama may be unavailable"
      }
    end

    (result[:observation_lifecycle_issues] || []).each do |issue|
      review_items << issue.merge(id: SecureRandom.uuid)
    end

    return if review_items.empty?

    CompactionReviewService.seed_report(
      report_type: "compaction_review",
      source: "integrity_sweep",
      source_ref: run.id,
      items: review_items
    )
  end

  def log_integrity_summary(result)
    Rails.logger.info "[DreamState] Pre-flight: " \
      "backfilled #{result.dig(:embeddings_backfilled, :backfilled) || 0} embeddings, " \
      "repaired #{result[:counters_repaired]} counters, " \
      "removed #{result[:dangling_relations_removed]} dangling relations, " \
      "found #{(result[:observation_lifecycle_issues] || []).size} lifecycle issues"
  end
end

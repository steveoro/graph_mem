# frozen_string_literal: true

# Canonicalizes the stored relation types (RelationTypeSweep, R1a) in the background, with an
# OperationProgress (`relation_type_sweep`) updated after each batch. Queued by System ›
# Background jobs' "Canonicalize relation types" (after its dry run), which refuses while
# .running?. One sweep at a time; a second enqueue while one is queued or running is discarded. Like every graph mutation, it asks a
# running dream-state run to pause first (CompactionValve).
#
#   RelationTypeSweepJob.perform_later(actor: "operator:synth@127.0.0.1")
class RelationTypeSweepJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "relation_type_sweep", duration: 1.hour, on_conflict: :discard

  # A running progress row older than this is a sweep that died (a shutdown): it no longer counts
  # as running. A batch updates the row every BATCH_SIZE relations.
  STALE_AFTER = 15.minutes

  # Whether a sweep is queued or running: an unfinished, unfailed job in Solid Queue, or a running
  # progress row updated within STALE_AFTER (the only signal outside Solid Queue, e.g. in tests).
  #
  # @return [Boolean]
  def self.running?
    recent = OperationProgress.where(operation_type: "relation_type_sweep", status: "running", updated_at: STALE_AFTER.ago..)
    return true if recent.exists?
    return false unless queue_adapter_name.to_s == "solid_queue"

    SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution).exists?
  end

  # @param actor [String, nil] recorded on the audit rows and change sets (default RelationTypeSweep::DEFAULT_ACTOR)
  # @return [Hash] RelationTypeSweep's summary
  def perform(actor: nil)
    CompactionValve.request_pause_if_running!
    progress = OperationProgress.start!(operation_type: "relation_type_sweep", total_count: MemoryRelation.count,
                                        phase: "sweeping", message: "Canonicalizing relation types")
    summary = RelationTypeSweep.call(actor: actor.presence || RelationTypeSweep::DEFAULT_ACTOR, source: "operator",
                                     progress: ->(sweep) { report_progress(progress, sweep) })
    progress.complete!(current: summary[:counts]["scanned"], message: completion_message(summary[:counts]),
                       counters: summary[:counts], details: { report_id: summary[:report_id] })
    OperationProgressBroadcaster.call(progress)
    summary
  rescue StandardError => e
    if progress
      progress.fail!(e)
      OperationProgressBroadcaster.call(progress)
    end
    raise
  end

  private

  def report_progress(progress, sweep)
    progress.update_progress!(current: sweep.counts["scanned"], message: "Checked #{sweep.counts['scanned']} relation(s)",
                              counters: sweep.counts.to_h)
    OperationProgressBroadcaster.call(progress)
  end

  def completion_message(counts)
    "#{counts['retyped'].to_i + counts['case_only'].to_i} retyped, #{counts['merged'].to_i} merged, " \
      "#{counts['queued'].to_i} queued for review, of #{counts['scanned'].to_i} relation(s)"
  end
end

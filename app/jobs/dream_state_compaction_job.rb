# frozen_string_literal: true

class DreamStateCompactionJob < ApplicationJob
  queue_as :default

  # Re-enqueue while work remains so recurring triggers can also resume paused runs.
  def perform(run_id = nil)
    unless AppSettings.dream_state_compactor_enabled?
      Rails.logger.info("[DreamState] Skipping compaction — dream-state compactor is disabled")
      return
    end

    run = resolve_run(run_id)
    return unless run
    return if run.status.in?(%w[completed failed])

    if run.cursor_entity_id.blank? && (run.stats["entities_processed"].to_i == 0)
      begin
        GraphIntegrityService.call
      rescue StandardError => e
        Rails.logger.error "[DreamState] Pre-flight integrity sweep failed: #{e.message}"
      end
    end

    run.with_lock do
      run.reload
      return if run.status.in?(%w[completed failed])

      compactor = DreamStateCompactor.new(run: run)
      result = compactor.process_batch!

      case result
      when :continued
        self.class.perform_later(run.id)
      when :paused, :completed
        Rails.logger.info "[DreamState] run #{run.id} #{result}"
      end
    end
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

  def resolve_run(run_id)
    run_id ? CompactionRun.find_by(id: run_id) : CompactionRunner.acquire_run!
  end
end

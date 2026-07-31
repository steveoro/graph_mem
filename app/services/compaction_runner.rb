# frozen_string_literal: true

# Starts or resumes dream-state compaction runs.
class CompactionRunner
  class << self
    def acquire_run!
      CompactionRun.transaction do
        running = CompactionRun.lock.where(status: "running").first
        return running if running

        paused = CompactionRun.lock.where(status: "paused").order(updated_at: :desc).first
        if paused
          paused.update!(status: "running", pause_requested: false)
          paused.operation_progress&.resume!(message: "Resuming compaction")
          return paused
        end

        failed_run = CompactionRun.lock.where(status: "failed").order(updated_at: :desc).first
        if failed_run
          failed_run.resume_from_failure!
          failed_run.operation_progress&.resume!(message: "Resuming compaction after failure")
          return failed_run
        end

        total_entities = MemoryEntity.count
        operation = OperationProgress.start!(
          operation_type: "compaction",
          total_count: total_entities * CompactionRun::PHASES.size,
          phase: CompactionTraversal::PHASES.first,
          message: "Starting compaction",
          counters: default_stats
        )

        CompactionRun.create!(
          operation_progress: operation,
          status: "running",
          phase: CompactionTraversal::PHASES.first,
          stats: default_stats,
          started_at: Time.current
        )
      end
    end

    def start_or_resume!
      run = acquire_run!
      DreamStateCompactionJob.perform_later(run.id)
      run
    end

    def status_snapshot
      run = CompactionRun.current || CompactionRun.recent.first
      return { dream_state: "idle" } unless run

      stats = run.stats || {}
      snapshot = {
        dream_state: run.status,
        run_id: run.id,
        phase: run.phase,
        cursor_entity_id: run.cursor_entity_id,
        pause_requested: run.pause_requested,
        stats: stats,
        progress: progress_for(run),
        operation_id: run.operation_progress&.operation_id,
        started_at: run.started_at&.iso8601,
        finished_at: run.finished_at&.iso8601
      }

      if run.failed?
        snapshot[:error] = stats["error"]
        snapshot[:error_class] = stats["error_class"]
        snapshot[:error_backtrace] = stats["error_backtrace"]
      end

      snapshot
    end

    private

    def progress_for(run)
      if run.operation_progress
        snapshot = run.operation_progress.snapshot
        return {
          phase: {
            current: snapshot[:current],
            total: snapshot[:total],
            percent: snapshot[:percentage]
          },
          overall: {
            current: snapshot[:current],
            total: snapshot[:total],
            percent: snapshot[:percentage]
          }
        }
      end

      stats = run.stats || {}
      total = [ stats["total_entities"].to_i * CompactionRun::PHASES.size, 0 ].max
      current = [ stats["entities_processed"].to_i, total ].min
      percent = run.completed? ? 100 : (total.zero? ? 0 : ((current.to_f / total) * 100).round)
      { phase: { current: current, total: total, percent: percent }, overall: { current: current, total: total, percent: percent } }
    end

    def default_stats
      {
        "entities_processed" => 0,
        "merges_auto" => 0,
        "merges_queued" => 0,
        "observations_deduped" => 0,
        "orphans_parented" => 0,
        "orphans_queued" => 0,
        "relationships_queued" => 0,
        "embeddings_backfilled" => 0,
        "counters_repaired" => 0,
        "dangling_relations_removed" => 0,
        "lifecycle_issues_found" => 0,
        "total_entities" => MemoryEntity.count
      }
    end
  end
end

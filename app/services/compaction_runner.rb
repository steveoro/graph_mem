# frozen_string_literal: true

# Starts or resumes dream-state compaction runs.
class CompactionRunner
  class << self
    def acquire_run!
      run = CompactionRun.current
      if run&.paused?
        run.update!(status: "running", pause_requested: false)
        return run
      end

      failed_run = CompactionRun.where(status: "failed").order(updated_at: :desc).first
      if failed_run && CompactionRun.current.nil? && !CompactionRun.exists?(status: "running")
        failed_run.resume_from_failure!
        return failed_run
      end

      return CompactionRun.find_by(status: "running") if CompactionRun.exists?(status: "running")

      CompactionRun.create!(
        status: "running",
        phase: CompactionTraversal::PHASES.first,
        stats: default_stats,
        started_at: Time.current
      )
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
      stats = run.stats || {}
      traversal = CompactionTraversal.new
      phase_ids = traversal.entity_ids_for_phase(run.phase)
      phase_total = phase_ids.length
      overall_current = stats["entities_processed"].to_i
      overall_total = stats["total_entities"].to_i * CompactionRun::PHASES.size
      overall_total = MemoryEntity.count * CompactionRun::PHASES.size if overall_total.zero?

      phase_current = if run.cursor_entity_id.present?
        idx = phase_ids.index(run.cursor_entity_id)
        idx ? idx + 1 : [ overall_current, phase_total ].min
      else
        0
      end

      percent = ->(current, total) {
        return 0 if total.zero?
        [ [ (current.to_f / total) * 100, 100 ].min, 0 ].max.round
      }

      overall_percent = run.completed? ? 100 : percent.call(overall_current, overall_total)

      {
        phase: {
          current: phase_current,
          total: phase_total,
          percent: percent.call(phase_current, phase_total)
        },
        overall: {
          current: overall_current,
          total: overall_total,
          percent: overall_percent
        }
      }
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
        "total_entities" => MemoryEntity.count
      }
    end
  end
end

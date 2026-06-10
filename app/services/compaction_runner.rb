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

      {
        dream_state: run.status,
        run_id: run.id,
        phase: run.phase,
        cursor_entity_id: run.cursor_entity_id,
        pause_requested: run.pause_requested,
        stats: run.stats || {},
        started_at: run.started_at&.iso8601,
        finished_at: run.finished_at&.iso8601
      }
    end

    private

    def default_stats
      {
        "entities_processed" => 0,
        "merges_auto" => 0,
        "merges_queued" => 0,
        "observations_deduped" => 0,
        "orphans_parented" => 0,
        "orphans_queued" => 0
      }
    end
  end
end

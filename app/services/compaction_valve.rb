# frozen_string_literal: true

# Cooperative pause: MCP tools request compaction to yield before mutating the graph.
class CompactionValve
  MAX_WAIT_SECONDS = 3
  POLL_INTERVAL = 0.1

  class << self
    def request_pause_if_running!
      run = CompactionRun.lock.where(status: "running").first
      return false unless run

      run.request_pause!
      paused = wait_for_pause(run)
      Rails.logger.warn "[CompactionValve] compaction still running after timeout" unless paused
      paused
    end

    private

    def wait_for_pause(run)
      deadline = Time.current + MAX_WAIT_SECONDS

      while Time.current < deadline
        run.reload
        return true if run.paused? || run.status.in?(%w[completed failed idle])
        sleep(POLL_INTERVAL)
      end

      run.reload.paused?
    end
  end
end

# frozen_string_literal: true

class EmbeddingsMaintenanceJob < ApplicationJob
  queue_as :low_priority

  # Retry interval when a deferred backfill could not acquire the embeddings
  # lock (e.g. an import is holding it). Deferred rows stay `missing_embedding`,
  # so re-enqueueing is safe and converges once the writer releases the lock.
  DEFERRED_RETRY_INTERVAL = 60.seconds

  def perform(mode = "backfill")
    started_at = Time.current
    Rails.logger.info "[EmbeddingsMaintenanceJob] Starting #{mode}"

    result = case mode
    when "backfill" then EmbeddingService.backfill_all
    when "regenerate" then EmbeddingService.regenerate_all
    else raise ArgumentError, "unknown mode: #{mode}"
    end

    if result[:deferred]
      Rails.logger.info "[EmbeddingsMaintenanceJob] #{mode} deferred — re-enqueueing in #{DEFERRED_RETRY_INTERVAL}s"
      self.class.set(wait: DEFERRED_RETRY_INTERVAL).perform_later(mode)
    end

    finished_at = Time.current
    duration_ms = ((finished_at - started_at) * 1000).round

    MaintenanceReport.create!(
      report_type: "embedding_maintenance",
      data: {
        mode: mode,
        entities: result[:entities],
        observations: result[:observations],
        deferred: result[:deferred] == true,
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        duration_ms: duration_ms
      }
    )

    Rails.logger.info "[EmbeddingsMaintenanceJob] Finished #{mode}: #{result.inspect}"
    result
  end
end

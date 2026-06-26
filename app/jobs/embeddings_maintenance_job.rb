# frozen_string_literal: true

class EmbeddingsMaintenanceJob < ApplicationJob
  queue_as :low_priority

  def perform(mode = "backfill")
    started_at = Time.current
    Rails.logger.info "[EmbeddingsMaintenanceJob] Starting #{mode}"

    result = case mode
    when "backfill" then EmbeddingService.backfill_all
    when "regenerate" then EmbeddingService.regenerate_all
    else raise ArgumentError, "unknown mode: #{mode}"
    end

    finished_at = Time.current
    duration_ms = ((finished_at - started_at) * 1000).round

    MaintenanceReport.create!(
      report_type: "embedding_maintenance",
      data: {
        mode: mode,
        entities: result[:entities],
        observations: result[:observations],
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        duration_ms: duration_ms
      }
    )

    Rails.logger.info "[EmbeddingsMaintenanceJob] Finished #{mode}: #{result.inspect}"
    result
  end
end

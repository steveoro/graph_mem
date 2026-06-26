# frozen_string_literal: true

class EmbeddingScheduledBackfillJob < ApplicationJob
  queue_as :low_priority

  def perform
    unless AppSettings.scheduled_embedding_backfill_enabled?
      Rails.logger.info("[EmbeddingScheduledBackfill] Skipping — scheduled backfill is disabled")
      return
    end

    EmbeddingsMaintenanceJob.perform_now("backfill")
  end
end

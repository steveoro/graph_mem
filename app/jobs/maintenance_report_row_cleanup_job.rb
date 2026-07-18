# frozen_string_literal: true

# Periodically removes terminal compaction review rows older than the retention window.
# Dismissed signatures live in MaintenanceReportSuppression, so pruning rows does not
# allow ghost suggestions to reappear.
class MaintenanceReportRowCleanupJob < ApplicationJob
  queue_as :default

  def perform
    retention_days = AppSettings.compaction_review_row_retention_days.to_i
    retention_days = 30 if retention_days <= 0

    cutoff = retention_days.days.ago

    # Prune approved/dismissed/ignored review rows older than the retention window.
    # Active rows are left alone so operators can still review recent suggestions.
    MaintenanceReportRow
      .where(status: %w[approved dismissed ignored])
      .where("updated_at < ?", cutoff)
      .find_each(&:destroy!)
  end
end

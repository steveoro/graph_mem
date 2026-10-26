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

    # Prune approved/dismissed/expired/ignored review rows older than the retention window.
    # Active rows are left alone so operators can still review recent suggestions, and a
    # snoozed row (ignored with a future expires_at) is kept until its snooze ends.
    # Set-based deletes (no callbacks or dependents on the row) re-check the status
    # and age in each DELETE, so a row restored mid-run is kept.
    MaintenanceReportRow
      .where(status: %w[approved dismissed expired ignored])
      .where("updated_at < ?", cutoff)
      .where("expires_at IS NULL OR expires_at < ?", Time.current)
      .in_batches(of: 1_000)
      .delete_all

    # Suppressions that expired more than the retention window ago no longer block anything.
    MaintenanceReportSuppression
      .where("expires_at < ?", cutoff)
      .in_batches(of: 1_000)
      .delete_all
  end
end

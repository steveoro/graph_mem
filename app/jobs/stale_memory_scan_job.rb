# frozen_string_literal: true

# Periodic stale-memory revalidation (C4). Runs the discovery-anchored
# detectors in StaleMemoryScanner and enqueues `stale_memory` rows on the
# compaction review queue — flagging only; nothing is auto-deleted.
# Toggle: Settings → enable_stale_memory_scan (AppSettings.stale_memory_scan_enabled?).
class StaleMemoryScanJob < ApplicationJob
  queue_as :low_priority

  def perform
    return unless AppSettings.stale_memory_scan_enabled?

    started_at = Time.current
    items = StaleMemoryScanner.scan

    unless items.empty?
      CompactionReviewService.seed_report(
        report_type: "compaction_review",
        source: "stale_memory_scan",
        source_ref: started_at.to_i,
        items: items
      )
    end

    MaintenanceReport.create!(
      report_type: StaleMemoryScanner::SCAN_REPORT_TYPE,
      data: {
        items_seeded: items.size,
        by_signal: items.group_by { |item| item[:signal] }.transform_values(&:size),
        started_at: started_at.iso8601,
        duration_ms: ((Time.current - started_at) * 1000).round
      }
    )
  end
end

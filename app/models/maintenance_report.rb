# frozen_string_literal: true

class MaintenanceReport < ApplicationRecord
  REPORT_TYPES = %w[orphans duplicates compaction_review embedding_maintenance contradictions
                    scan_review stale_memory_scan review_policy_run].freeze
  MAX_REPORTS_PER_TYPE = 30

  serialize :data, coder: JSON

  has_many :maintenance_report_rows, dependent: :nullify

  validates :report_type, presence: true, inclusion: { in: REPORT_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(report_type: type) }

  after_create :prune_old_reports

  private

  # Keeps the newest MAX_REPORTS_PER_TYPE reports, plus any older one that still holds a pending
  # (active or snoozed) row. A report is more than a log line: it is the only carrier of a row's
  # `data.source` / `data.source_ref`, which the per-run seed cap (CompactionReviewService::SeedLimits)
  # and the graphify rescan's ownership join (`GraphifyRescan.graphify_review_rows`) read through
  # `maintenance_report_id`. Pruning such a report would orphan its rows (`dependent: :nullify`, and
  # the FK is ON DELETE SET NULL), and the cap would stop counting them. Reports whose rows are all
  # resolved (or that have none) are plain history and are deleted as before.
  def prune_old_reports
    excess = self.class.by_type(report_type).recent.offset(MAX_REPORTS_PER_TYPE).pluck(:id)
    return if excess.empty?

    held = MaintenanceReportRow.pending.where(maintenance_report_id: excess).distinct.pluck(:maintenance_report_id)
    self.class.where(id: excess - held).delete_all
  end
end

# frozen_string_literal: true

class MaintenanceReport < ApplicationRecord
  REPORT_TYPES = %w[orphans stale duplicates].freeze
  MAX_REPORTS_PER_TYPE = 30

  serialize :data, coder: JSON

  validates :report_type, presence: true, inclusion: { in: REPORT_TYPES }

  scope :recent, -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(report_type: type) }

  after_create :prune_old_reports

  private

  def prune_old_reports
    excess = self.class.by_type(report_type).recent.offset(MAX_REPORTS_PER_TYPE).pluck(:id)
    self.class.where(id: excess).delete_all if excess.any?
  end
end

# frozen_string_literal: true

# Per-row review item linked to a MaintenanceReport header.
# Stores the original suggestion payload and any operator edits until applied.
class MaintenanceReportRow < ApplicationRecord
  STATUSES = %w[active ignored approved dismissed].freeze

  belongs_to :maintenance_report, optional: true

  validates :report_type, presence: true, inclusion: { in: MaintenanceReport::REPORT_TYPES }
  validates :row_uuid, presence: true, uniqueness: { scope: :maintenance_report_id }
  validates :kind, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :signature, presence: true

  scope :by_report_type, ->(type) { where(report_type: type) }
  scope :by_status, ->(status) { status.present? ? where(status: status) : all }
  scope :by_kind, ->(kind) { kind.present? ? where(kind: kind) : all }
  scope :active, -> { where(status: "active") }
  scope :ignored, -> { where(status: "ignored") }
  scope :approved, -> { where(status: "approved") }
  scope :dismissed, -> { where(status: "dismissed") }
  scope :pending, -> { where(status: %w[active ignored]) }

  serialize :payload, coder: JSON
  serialize :edited_payload, coder: JSON

  # Effective payload: operator edits override original values.
  def effective_payload
    edited = edited_payload || {}
    payload.merge(edited)
  end

  def resolved?
    approved? || dismissed?
  end

  def approved?
    status == "approved"
  end

  def dismissed?
    status == "dismissed"
  end

  def ignored?
    status == "ignored"
  end

  def active?
    status == "active"
  end
end

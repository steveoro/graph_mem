# frozen_string_literal: true

# Per-row review item linked to a MaintenanceReport header.
# Stores the original suggestion payload and any operator edits until applied.
class MaintenanceReportRow < ApplicationRecord
  STATUSES = %w[active ignored approved dismissed expired].freeze
  RESOLVED_STATUSES = %w[approved dismissed expired].freeze
  # Who closed a row (`resolved_by`); policies record `policy:<name>`.
  RESOLVERS = %w[operator agent policy generator].freeze

  belongs_to :maintenance_report, optional: true

  validates :report_type, presence: true, inclusion: { in: MaintenanceReport::REPORT_TYPES }
  validates :row_uuid, presence: true, uniqueness: { scope: :maintenance_report_id }
  validates :kind, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :signature, presence: true
  validate :resolved_by_is_known

  scope :by_report_type, ->(type) { where(report_type: type) }
  scope :by_status, ->(status) { status.present? ? where(status: status) : all }
  scope :by_kind, ->(kind) { kind.present? ? where(kind: kind) : all }
  scope :active, -> { where(status: "active") }
  scope :ignored, -> { where(status: "ignored") }
  scope :approved, -> { where(status: "approved") }
  scope :dismissed, -> { where(status: "dismissed") }
  scope :pending, -> { where(status: %w[active ignored]) }
  scope :expired, -> { where(status: "expired") }
  scope :resolved, -> { where(status: RESOLVED_STATUSES) }
  # Snoozed = ignored until `expires_at`; rows ignored before UI-5 have no end and never return.
  scope :snoozed, -> { ignored.where.not(expires_at: nil) }
  scope :attention, ->(threshold) { active.where(priority: threshold.to_i..) }
  scope :by_group, ->(group_key) { where(group_key: group_key) }
  scope :by_project, ->(project_id) { where(project_id: project_id) }

  serialize :payload, coder: JSON
  serialize :edited_payload, coder: JSON

  # Effective payload: operator edits override original values.
  def effective_payload
    edited = edited_payload || {}
    payload.merge(edited)
  end

  def resolved?
    RESOLVED_STATUSES.include?(status)
  end

  def expired?
    status == "expired"
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

  private

  def resolved_by_is_known
    return if resolved_by.blank? || RESOLVERS.include?(resolved_by.to_s.split(":").first)

    errors.add(:resolved_by, "must be one of #{RESOLVERS.join(', ')} (policies: policy:<name>)")
  end
end

# frozen_string_literal: true

# Tiny durable store of dismissed review signatures.
# Keeps the graph from re-proposing suggestions that an operator has explicitly dropped,
# without bloating the main review rows table. Since UI-5a a suppression can expire
# (`expires_at`; NULL = permanent): snoozes and the `expire_low_confidence` policy write
# expiring ones, and an expired suppression no longer blocks its signature.
class MaintenanceReportSuppression < ApplicationRecord
  SOURCES = %w[dismissed snoozed expired policy].freeze

  validates :report_type, presence: true, inclusion: { in: MaintenanceReport::REPORT_TYPES }
  validates :signature, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :by_report_type, ->(type) { where(report_type: type) }
  scope :for_signature, ->(signature) { where(signature: signature) }
  scope :in_force, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # True if a signature is suppressed (and the suppression hasn't expired) for the report type.
  def self.suppressed?(report_type, signature)
    in_force.exists?(report_type: report_type, signature: signature)
  end

  # Replaces whatever suppression the pair has with a new one. The unique key allows one row per
  # pair, so an expiring suppression must be replaced, never silently kept, when the new one is
  # permanent (or the other way round).
  #
  # @return [Array(Array<Hash>, MaintenanceReportSuppression)] the deleted rows' attributes (for
  #   ChangeSet::Context#note_suppressions!) and the created row
  def self.replace!(report_type:, signature:, kind:, reason:, source:, expires_at: nil)
    existing = where(report_type: report_type, signature: signature).to_a
    deleted = existing.map { |suppression| ChangeSet.snapshot_attributes(suppression) }
    where(id: existing.map(&:id)).delete_all if existing.any?
    created = create!(report_type: report_type, signature: signature, kind: kind, reason: reason,
                      source: source, expires_at: expires_at, dismissed_at: Time.current)
    [ deleted, created ]
  end
end

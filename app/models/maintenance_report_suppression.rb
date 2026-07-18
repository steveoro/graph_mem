# frozen_string_literal: true

# Tiny durable store of dismissed review signatures.
# Keeps the graph from re-proposing suggestions that an operator has explicitly dropped,
# without bloating the main review rows table.
class MaintenanceReportSuppression < ApplicationRecord
  validates :report_type, presence: true, inclusion: { in: MaintenanceReport::REPORT_TYPES }
  validates :signature, presence: true

  scope :by_report_type, ->(type) { where(report_type: type) }
  scope :for_signature, ->(signature) { where(signature: signature) }

  # True if a signature is suppressed for the given report type.
  def self.suppressed?(report_type, signature)
    exists?(report_type: report_type, signature: signature)
  end
end

# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :auditable, polymorphic: true, optional: true

  serialize :changed_fields, coder: JSON

  validates :action, presence: true, inclusion: { in: %w[create update delete] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_record, ->(type, id) { where(auditable_type: type, auditable_id: id) }

  MAX_AGE_DAYS = 90

  def self.prune!
    where("created_at < ?", MAX_AGE_DAYS.days.ago).delete_all
  end
end

# frozen_string_literal: true

class AuditLog < ApplicationRecord
  belongs_to :auditable, polymorphic: true, optional: true

  serialize :changed_fields, coder: JSON

  validates :action, presence: true, inclusion: { in: %w[create update delete] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_record, ->(type, id) { where(auditable_type: type, auditable_id: id) }
  scope :expired, -> { where("created_at < ?", MAX_AGE_DAYS.days.ago) }
  scope :since, ->(days) { where("created_at >= ?", days.to_i.days.ago) }
  scope :with_action, ->(action) { action.present? ? where(action: action) : all }
  scope :with_auditable_type, ->(type) { type.present? ? where(auditable_type: type) : all }
  scope :with_actor, ->(actor) { actor.present? ? where(actor: actor) : all }
  scope :with_auditable_id, ->(id) { id.present? ? where(auditable_id: id) : all }

  MAX_AGE_DAYS = 90
  DEFAULT_SINCE_DAYS = 7
  PER_PAGE = 50

  def self.filter(params)
    filters = normalize_filter_params(params)

    relation = all
    unless filters[:since_days].to_s == "all"
      relation = relation.since(filters[:since_days] || DEFAULT_SINCE_DAYS)
    end
    relation = relation.with_action(filters[:log_action])
    relation = relation.with_auditable_type(filters[:auditable_type])
    relation = relation.with_actor(filters[:actor])
    relation = relation.with_auditable_id(filters[:auditable_id])
    relation.recent
  end

  def self.normalize_filter_params(params)
    raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    raw = raw.with_indifferent_access

    since_days = raw[:since_days]
    since_days = DEFAULT_SINCE_DAYS if since_days.blank? && !raw.key?(:since_days)

    {
      log_action: raw[:log_action].presence,
      auditable_type: raw[:auditable_type].presence,
      actor: raw[:actor].presence,
      auditable_id: raw[:auditable_id].presence,
      since_days: since_days.presence
    }
  end

  def self.prune!
    expired.delete_all
  end
end

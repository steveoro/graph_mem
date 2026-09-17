# frozen_string_literal: true

class ToolInvocation < ApplicationRecord
  OUTCOMES = %w[ok error].freeze
  PERIOD_DAYS = %w[1 7 30 90].freeze
  DEFAULT_PERIOD_DAYS = "30"
  PER_PAGE = 50

  serialize :argument_keys, coder: JSON

  validates :tool_name, :client_id, :outcome, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :result_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :argument_keys_are_strings

  scope :since, ->(time) { where(created_at: time..) }
  scope :errors, -> { where(outcome: "error") }

  # Normalizes allow-listed operator dashboard filters.
  #
  # @param params [Hash, ActionController::Parameters]
  # @return [Hash] safe filter values with a default 30-day period
  def self.normalize_filter_params(params)
    values = params.to_h.symbolize_keys
    since_days = values[:since_days].to_s
    since_days = DEFAULT_PERIOD_DAYS unless since_days.in?(PERIOD_DAYS)

    {
      since_days: since_days,
      tool_name: values[:tool_name].presence,
      client_id: values[:client_id].presence,
      outcome: values[:outcome].to_s.in?(OUTCOMES) ? values[:outcome].to_s : nil,
      error_category: values[:error_category].presence
    }
  end

  # Applies normalized dashboard filters and newest-first ordering.
  #
  # @param params [Hash, ActionController::Parameters]
  # @return [ActiveRecord::Relation<ToolInvocation>]
  def self.filter(params = {})
    filters = normalize_filter_params(params)
    relation = since(filters[:since_days].to_i.days.ago)
    relation = relation.where(tool_name: filters[:tool_name]) if filters[:tool_name]
    relation = relation.where(client_id: filters[:client_id]) if filters[:client_id]
    relation = relation.where(outcome: filters[:outcome]) if filters[:outcome]
    relation = apply_error_category_filter(relation, filters[:error_category])
    relation.order(created_at: :desc, id: :desc)
  end

  # Returns telemetry rows older than the configured retention window.
  #
  # A setting of zero disables expiry.
  #
  # @return [ActiveRecord::Relation<ToolInvocation>]
  def self.expired
    retention_days = AppSettings.tool_invocation_retention_days.to_i
    return none unless retention_days.positive?

    where(created_at: ...retention_days.days.ago)
  end

  # Deletes expired telemetry rows without instantiating append-only records.
  #
  # @return [Integer] number of deleted rows
  def self.prune!
    expired.delete_all
  end

  def self.apply_error_category_filter(relation, category)
    return relation unless category
    return relation.where(error_category: [ nil, "" ]) if category == "uncategorized"

    relation.where(error_category: category)
  end
  private_class_method :apply_error_category_filter

  private

  def argument_keys_are_strings
    return if argument_keys.is_a?(Array) && argument_keys.all? { |key| key.is_a?(String) }

    errors.add(:argument_keys, "must be an array of strings")
  end
end

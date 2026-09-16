# frozen_string_literal: true

class ToolInvocation < ApplicationRecord
  OUTCOMES = %w[ok error].freeze

  serialize :argument_keys, coder: JSON

  validates :tool_name, :client_id, :outcome, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :result_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :argument_keys_are_strings

  scope :since, ->(time) { where(created_at: time..) }
  scope :errors, -> { where(outcome: "error") }

  private

  def argument_keys_are_strings
    return if argument_keys.is_a?(Array) && argument_keys.all? { |key| key.is_a?(String) }

    errors.add(:argument_keys, "must be an array of strings")
  end
end

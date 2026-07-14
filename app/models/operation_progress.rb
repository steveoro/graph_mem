# frozen_string_literal: true

class OperationProgress < ApplicationRecord
  OPERATION_TYPES = %w[compaction import garbage_collection export].freeze
  STATUSES = %w[pending running paused completed failed].freeze

  serialize :counters, coder: JSON
  serialize :details, coder: JSON

  validates :operation_type, presence: true, inclusion: { in: OPERATION_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :current_count, :total_count, :percentage, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(status: %w[pending running paused]) }
  scope :recent, -> { order(created_at: :desc) }

  def self.start!(operation_type:, total_count:, phase: nil, message: nil, counters: {}, details: {}, operation_id: SecureRandom.uuid)
    create!(
      operation_id: operation_id,
      operation_type: operation_type,
      status: "running",
      phase: phase,
      message: message,
      current_count: 0,
      total_count: [ total_count.to_i, 0 ].max,
      percentage: 0,
      counters: counters,
      details: details,
      started_at: Time.current
    )
  end

  def update_progress!(current:, total: total_count, phase: phase, message: nil, counters: nil, details: nil)
    next_current = [ current.to_i, 0 ].max
    next_total = [ total.to_i, 0 ].max
    next_current = [ next_current, next_total ].min
    next_current = [ next_current, current_count.to_i ].max
    next_total = [ next_total, total_count.to_i ].max
    update!(
      current_count: next_current,
      total_count: next_total,
      percentage: percentage_for(next_current, next_total),
      phase: phase,
      message: message,
      counters: counters || self.counters || {},
      details: details || self.details || {}
    )
  end

  def complete!(current: total_count, message: nil, counters: nil, details: nil)
    final_total = [ total_count.to_i, current.to_i, 0 ].max
    update_progress!(
      current: final_total,
      total: final_total,
      message: message,
      counters: counters,
      details: details
    )
    update!(status: "completed", finished_at: Time.current, percentage: 100)
  end

  def resume!(message: nil)
    update!(status: "running", message: message || self.message, finished_at: nil)
  end

  def pause!(message: nil)
    update!(status: "paused", message: message || self.message)
  end

  def fail!(error)
    exception = error.is_a?(Exception) ? error : StandardError.new(error.to_s)
    update!(
      status: "failed",
      message: exception.message,
      error_class: exception.class.name,
      error_message: exception.message,
      finished_at: Time.current
    )
  end

  def snapshot
    {
      id: id,
      operation_id: operation_id,
      operation: operation_type,
      status: status,
      phase: phase,
      message: message,
      current: current_count,
      total: total_count,
      percentage: percentage.to_f,
      counters: counters || {},
      details: details || {},
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      error: error_message,
      error_class: error_class
    }.compact
  end

  private

  def percentage_for(current, total)
    return 0.0 if total.zero?

    [ ((current.to_f / total) * 100).round(1), 100.0 ].min
  end
end

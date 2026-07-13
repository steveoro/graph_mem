# frozen_string_literal: true

class CompactionRun < ApplicationRecord
  STATUSES = %w[idle running paused completed failed].freeze
  PHASES = %w[orphans tree_walk relationship_discovery].freeze

  serialize :stats, coder: JSON

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :phase, inclusion: { in: PHASES }, allow_nil: true

  scope :active, -> { where(status: %w[running paused]) }
  scope :recent, -> { order(created_at: :desc) }

  def self.current
    active.order(updated_at: :desc).first
  end

  def self.dream_state_active?
    exists?(status: "running")
  end

  def running?
    status == "running"
  end

  def paused?
    status == "paused"
  end

  def failed?
    status == "failed"
  end

  def completed?
    status == "completed"
  end

  def resume_from_failure!
    cleared_stats = (stats || {}).except("error", "error_class", "error_backtrace")
    update!(
      status: "running",
      finished_at: nil,
      pause_requested: false,
      stats: cleared_stats
    )
  end

  def merge_stats!(updates)
    merged = (stats || {}).merge(updates.stringify_keys)
    update!(stats: merged)
  end

  def increment_stat!(key, by = 1)
    current = stats || {}
    current[key.to_s] = (current[key.to_s] || 0) + by
    update!(stats: current)
  end

  def request_pause!
    update!(pause_requested: true) if running?
  end

  def pause!
    update!(status: "paused", pause_requested: false)
  end

  def mark_completed!
    update!(status: "completed", finished_at: Time.current, pause_requested: false)
  end

  def mark_failed!(error)
    message = error.is_a?(Exception) ? error.message : error.to_s
    error_class = error.is_a?(Exception) ? error.class.name : nil
    error_backtrace = error.is_a?(Exception) ? error.backtrace&.first(5) : nil

    merged = (stats || {}).merge(
      "error" => message,
      "error_class" => error_class,
      "error_backtrace" => error_backtrace
    )

    updates = {
      status: "failed",
      finished_at: Time.current,
      stats: merged,
      pause_requested: false
    }
    updates[:cursor_entity_id] = cursor_entity_id if cursor_entity_id.present?

    update!(**updates)
  end
end

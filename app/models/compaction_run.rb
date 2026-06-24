# frozen_string_literal: true

class CompactionRun < ApplicationRecord
  STATUSES = %w[idle running paused completed failed].freeze
  PHASES = %w[orphans tree_walk].freeze

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

  def resume_from_failure!
    cleared_stats = (stats || {}).except("error")
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

  def mark_failed!(message)
    merged = (stats || {}).merge("error" => message)
    update!(status: "failed", finished_at: Time.current, stats: merged, pause_requested: false)
  end
end

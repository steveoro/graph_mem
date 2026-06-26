# frozen_string_literal: true

# Enqueues embedding maintenance jobs with duplicate-mode guard.
class EmbeddingsMaintenanceEnqueuer
  JOB_CLASS = "EmbeddingsMaintenanceJob"

  def self.enqueue!(mode)
    new(mode).enqueue!
  end

  def self.pending?(mode)
    new(mode).pending?
  end

  def initialize(mode)
    @mode = mode.to_s
  end

  def self.pending_summary
    {
      backfill: pending?("backfill"),
      regenerate: pending?("regenerate"),
      any: pending?("backfill") || pending?("regenerate")
    }
  end

  def enqueue!
    raise ArgumentError, "unknown mode: #{@mode}" unless @mode.in?(%w[backfill regenerate])

    return :already_pending if pending?

    EmbeddingsMaintenanceJob.perform_later(@mode)
    :enqueued
  end

  def pending?
    return false unless defined?(SolidQueue::Job)

    SolidQueue::Job
      .where(class_name: JOB_CLASS, finished_at: nil)
      .where("arguments LIKE ?", "%#{@mode}%")
      .exists?
  rescue StandardError
    false
  end
end

# frozen_string_literal: true

# Runs ReviewPolicyRunner (UI-5a): nightly from config/recurring.yml, and after a compaction run,
# a stale scan or a project scan that seeded review rows. Two runs never overlap: an advisory lock
# guards the run, and a run that finds it taken returns at once.
class ReviewPolicyJob < ApplicationJob
  queue_as :low_priority

  LOCK_PREFIX = "graph_mem.review_policy"

  # Enqueues a run when `seeded` (rows, a count or a boolean) says rows were seeded.
  # @param trigger [String]
  def self.enqueue_if_seeded(trigger:, seeded:)
    count = case seeded
    when true then 1
    when false, nil then 0
    when Integer then seeded
    else seeded.size
    end
    perform_later(trigger: trigger) if count.positive?
  end

  # Whether a run is under way or waiting (1.86.2: the Review rail polls faster meanwhile): the
  # run's lock is held, or a Solid Queue job of this class hasn't finished yet. A failed job also
  # keeps finished_at nil until it's retried or discarded, so it doesn't count (else every open
  # Review tab would poll every 3 s after one failed run).
  # @return [Boolean]
  def self.running?
    conn = ActiveRecord::Base.connection
    name = conn.quote(lock_name(conn))
    return true unless conn.uncached { conn.select_value("SELECT IS_USED_LOCK(#{name})") }.nil?

    pending_job?
  end

  # @param conn [ActiveRecord::ConnectionAdapters::AbstractAdapter]
  # @return [String] the named-lock name, per database (quote it before use in SQL)
  def self.lock_name(conn)
    "#{LOCK_PREFIX}:#{conn.current_database}"
  end
  private_class_method :lock_name

  def self.pending_job?
    return false unless defined?(SolidQueue::Job)

    SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution).exists?
  rescue StandardError
    false
  end
  private_class_method :pending_job?

  # @param trigger [String]
  # @return [Hash, nil] the run summary, nil when another run holds the lock
  def perform(trigger: "nightly")
    conn = ActiveRecord::Base.connection
    name = conn.quote(self.class.send(:lock_name, conn))
    return unless conn.uncached { conn.select_value("SELECT GET_LOCK(#{name}, 0)") }.to_i == 1

    begin
      ReviewPolicyRunner.call(trigger: trigger)
    ensure
      conn.uncached { conn.select_value("SELECT RELEASE_LOCK(#{name})") }
    end
  end
end

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

  # @param trigger [String]
  # @return [Hash, nil] the run summary, nil when another run holds the lock
  def perform(trigger: "nightly")
    conn = ActiveRecord::Base.connection
    name = conn.quote("#{LOCK_PREFIX}:#{conn.current_database}")
    return unless conn.uncached { conn.select_value("SELECT GET_LOCK(#{name}, 0)") }.to_i == 1

    begin
      ReviewPolicyRunner.call(trigger: trigger)
    ensure
      conn.uncached { conn.select_value("SELECT RELEASE_LOCK(#{name})") }
    end
  end
end

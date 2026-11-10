# frozen_string_literal: true

# Computes the keyword path (FactKeywords) of every active fact still pending (keywords_at NULL), in
# batches, until none is left (1.77.0). Requested by MemoryObservation's after_commit when a fact is
# written or its text changes (FactKeywordsJob.request!), and run nightly (config/recurring.yml) for
# anything a request missed. One run at a time: a request while one is queued or running is
# discarded, and the running one picks up facts written meanwhile on its next batch. Off when the
# fact_keywords_enabled setting is.
class FactKeywordsJob < ApplicationJob
  queue_as :low_priority
  limits_concurrency to: 1, key: "fact_keywords", duration: 1.hour, on_conflict: :discard

  BATCH_SIZE = 500
  # A guard on one run (BATCH_SIZE × this facts); the next request or night continues.
  MAX_BATCHES = 200
  # A burst of writes (an import, a scan) asks for one run, a moment after its first write.
  REQUEST_DELAY = 5

  class << self
    # Enqueues one run, at most once per REQUEST_DELAY in this process, when the setting is on.
    #
    # @return [Boolean] whether a run was enqueued
    def request!
      return false unless AppSettings.fact_keywords_enabled?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if @requested_at && now - @requested_at < REQUEST_DELAY

      @requested_at = now
      set(wait: REQUEST_DELAY.seconds).perform_later
      true
    end

    # Forgets the last request (specs).
    def reset_request!
      @requested_at = nil
    end
  end

  # @return [Integer] the facts computed
  def perform
    return 0 unless AppSettings.fact_keywords_enabled?

    computed = 0
    MAX_BATCHES.times do
      batch = MemoryObservation.active.keywords_pending.includes(:memory_entity).order(:id).limit(BATCH_SIZE).to_a
      break if batch.empty?

      computed += FactKeywords.compute!(batch)
    end
    computed
  end
end

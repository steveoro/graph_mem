# frozen_string_literal: true

# Computes the keyword path (FactKeywords) of every active fact still pending (keywords_at NULL), in
# batches, until none is left (1.77.0). Requested by MemoryObservation's after_commit when a fact is
# written or its text changes (FactKeywordsJob.request!), and run nightly (config/recurring.yml) for
# anything a request missed. One run at a time: a request while one is queued or running is
# discarded, and the running one picks up facts written meanwhile on its next batch. Off when the
# fact_keywords_enabled setting is. Inside "Run all scheduled jobs now" it stops between batches when
# a stop is requested (CooperativeStop).
class FactKeywordsJob < ApplicationJob
  queue_as :low_priority
  limits_concurrency to: 1, key: "fact_keywords", duration: 1.hour, on_conflict: :discard

  BATCH_SIZE = 500
  # A guard on one run (BATCH_SIZE × this facts); the next request or night continues.
  MAX_BATCHES = 200
  # A burst of writes (an import, a scan) asks for one run, a moment after its first write.
  REQUEST_DELAY = 5
  # 1.83.0: LLM word batches per run that reach the LLM (FactKeywords::LlmWords::BATCH_SIZE facts
  # each); the next request or night continues. A batch the cloud gate refused isn't charged.
  LLM_BATCHES_PER_RUN = 25
  # Batches in a row the LLM failed to answer (down, not JSON) before the run gives up; one such
  # batch is passed over, so it never blocks the facts behind it. A batch the cloud gate refused
  # (nothing sent) never counts: the run walks past it, however many there are.
  LLM_EMPTY_BATCHES = 3

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
      # Inside a scheduled run with a stop requested (1.81.0): the rest stays pending for the next run.
      break if CooperativeStop.requested?

      batch = MemoryObservation.active.keywords_pending.includes(:memory_entity).order(:id).limit(BATCH_SIZE).to_a
      break if batch.empty?

      computed += FactKeywords.compute!(batch)
    end
    computed + compute_llm_words
  end

  private

  # 1.83.0: the LLM words of facts whose path is computed (FactKeywords::LlmWords), at most
  # LLM_BATCHES_PER_RUN batches, stopping between batches inside a scheduled run asked to stop.
  #
  # @return [Integer] the facts stamped
  def compute_llm_words
    return 0 unless FactKeywords::LlmWords.enabled?

    stamped = 0
    after_id = 0
    empty = 0
    asked = 0
    # Ends: the cursor only moves forward, and the loop breaks on an empty batch or the cap.
    loop do
      break if asked >= LLM_BATCHES_PER_RUN || CooperativeStop.requested?

      batch = MemoryObservation.active.where.not(keywords_at: nil).llm_words_pending.where("memory_observations.id > ?", after_id)
                               .includes(:memory_entity).order(:id).limit(FactKeywords::LlmWords::BATCH_SIZE).to_a
      break if batch.empty?

      after_id = batch.last.id
      refused = []
      done = FactKeywords::LlmWords.compute!(batch, refused: refused)
      stamped += done
      # Refused by the cloud gate (nothing sent): neither the LLM failing nor a call to charge.
      next if refused.any? && done.zero?

      asked += 1
      empty = done.zero? ? empty + 1 : 0
      break if empty >= LLM_EMPTY_BATCHES
    end
    stamped
  end
end

# frozen_string_literal: true

# A stop requested for a scheduled run (1.81.0, "Run all scheduled jobs now"), checked by the jobs
# that loop over batches whose progress lives in the database (FactKeywordsJob, the embedding
# backfill): they return early between batches, and running them again continues the work.
#
# ScheduledRunJob sets the check around each step; it is thread-scoped, so the same jobs run on
# their schedule, or from their own buttons, never stop early.
#
#   CooperativeStop.with(-> { row.reload.details["stop_requested"] }) { FactKeywordsJob.perform_now }
#   # inside a job:
#   break if CooperativeStop.requested?
module CooperativeStop
  # The check is asked at most this often (it reads a database row); a stop, once seen, sticks.
  INTERVAL = 2.seconds
  KEY = :cooperative_stop

  module_function

  # @param check [#call] returns true when a stop is requested
  # @yield the work that may stop early
  # @return [Object] the block's value
  def with(check)
    previous = Thread.current[KEY]
    Thread.current[KEY] = { check: check, asked_at: nil, answer: false }
    yield
  ensure
    Thread.current[KEY] = previous
  end

  # @return [Boolean] inside a scheduled run (1.84.0: FactKeywordsJob drops its per-run batch cap there)
  def active? = !Thread.current[KEY].nil?

  # @return [Boolean] whether the work should stop now (always false outside #with)
  def requested?
    state = Thread.current[KEY]
    return false unless state
    return true if state[:answer]

    now = Time.current
    return false if state[:asked_at] && now - state[:asked_at] < INTERVAL

    state[:asked_at] = now
    state[:answer] = state[:check].call ? true : false
  end
end

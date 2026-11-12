# frozen_string_literal: true

# How far the current step of a scheduled run is (1.84.0, "Run all scheduled jobs now"): the jobs
# that loop over batches (FactKeywordsJob, the embedding backfill) report done/total next to their
# CooperativeStop checks, and ScheduledRunJob stores it on the run's step, so System › Background jobs
# shows a progress bar under the running step.
#
# Thread-scoped, like CooperativeStop: outside a scheduled run, report does nothing. A failing sink is
# logged and swallowed, so reporting progress never fails a step.
#
#   StepProgress.with(->(done:, total:, label: nil) { … }) { FactKeywordsJob.perform_now }
#   # inside a job:
#   StepProgress.report(done: 40, total: 3533, label: "LLM words")
module StepProgress
  KEY = :step_progress

  module_function

  # @param sink [#call] called with `done:`, `total:`, `label:`
  # @yield the step's work
  # @return [Object] the block's value
  def with(sink)
    previous = Thread.current[KEY]
    Thread.current[KEY] = sink
    yield
  ensure
    Thread.current[KEY] = previous
  end

  # @return [Boolean] inside a scheduled run's step
  def active? = !Thread.current[KEY].nil?

  # @param done [Integer]
  # @param total [Integer]
  # @param label [String, nil] what is being counted ("LLM words")
  def report(done:, total:, label: nil)
    sink = Thread.current[KEY]
    return unless sink

    sink.call(done: done, total: total, label: label)
  rescue StandardError => e
    Rails.logger.warn("[StepProgress] #{e.class}: #{e.message}")
  end
end

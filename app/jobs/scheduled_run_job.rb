# frozen_string_literal: true

# "Run all scheduled jobs now" (1.81.0): runs the steps of ScheduledRun one at a time, for machines
# that are off when the schedule would run them. The run's state is an OperationProgress row
# (operation_type "scheduled_run"), so System › Background jobs shows it live:
#
#   details = { "index" => 2, "stop_requested" => false,
#               "steps" => [ { "entry", "label", "schedule", "outcome", "note", "error",
#                              "started_at", "finished_at", "compaction_run_id" }, … ] }
#
# A step's outcome is nil (not reached), "running", "waiting" (compaction), "done", "skipped" (its
# setting is off), "stopped" (it stopped early: it runs again on Resume) or "failed" (logged; the
# run goes on). Compaction works in slices, so the job re-enqueues itself every COMPACTION_POLL
# until the compaction run ends. One switch drives it (System::JobsController#scheduled_run):
#
#   ScheduledRunJob.start!        # idle → running
#   ScheduledRunJob.stop!(row)    # running → stopping → paused (between steps, or inside the
#                                 #   stoppable ones; compaction through its own pause)
#   ScheduledRunJob.resume!(row)  # paused → running, at the step it stopped at
#   ScheduledRunJob.start_over!(row)
#
# There is no timer: a run is running until it finishes or is stopped. After a power cut, Solid
# Queue runs the job again at boot and it continues at the stored step; if its job was lost, Stop
# pauses the row at once.
class ScheduledRunJob < ApplicationJob
  queue_as :default

  OPERATION_TYPE = "scheduled_run"
  COMPACTION_POLL = 1.minute
  # A compaction run in one of these has ended (a paused one ends the step unless we asked for it).
  COMPACTION_ENDED = %w[completed paused failed].freeze
  FINISHED = %w[done skipped failed].freeze

  class << self
    # @return [OperationProgress, nil] the latest run
    def current
      OperationProgress.where(operation_type: OPERATION_TYPE).recent.first
    end

    # @param row [OperationProgress, nil]
    # @return [Symbol] :idle (none, completed or failed), :running, :stopping or :paused
    def state(row = current)
      return :idle if row.nil? || %w[completed failed].include?(row.status)
      return :paused if row.status == "paused"

      row.details.to_h["stop_requested"] ? :stopping : :running
    end

    # @param steps [Array<ScheduledRun::Step>]
    # @return [OperationProgress, nil] the new run; nil unless idle
    def start!(steps: ScheduledRun.steps)
      return nil unless state == :idle

      details = { "index" => 0, "stop_requested" => false,
                  "steps" => steps.map { |step| { "entry" => step.entry, "label" => step.label, "schedule" => step.schedule } } }
      row = OperationProgress.start!(operation_type: OPERATION_TYPE, total_count: steps.size, phase: steps.first&.label,
                                     message: "Starting", details: details)
      OperationProgressBroadcaster.call(row)
      perform_later(row.operation_id)
      row
    end

    # Requests a stop. With no live job to honour it (its job was lost), the row pauses at once.
    #
    # @param row [OperationProgress]
    # @param live [Boolean] whether a job is running the steps (Solid Queue knows; specs pass it)
    # @return [Boolean] false unless the run is running
    def stop!(row, live: live_job?)
      return false unless row&.status == "running"

      details = row.details.deep_dup
      return pause!(row, details) || true unless live

      details["stop_requested"] = true
      step = details["steps"][details["index"]]
      CompactionRun.find_by(id: step["compaction_run_id"])&.request_pause! if step && step["outcome"] == "waiting"
      row.update!(details: details, message: "Stopping after: #{step&.dig('label')}")
      OperationProgressBroadcaster.call(row)
      true
    end

    # @param row [OperationProgress]
    # @return [Boolean] false unless the run is paused
    def resume!(row)
      return false unless row&.status == "paused"

      row.update!(status: "running", details: row.details.merge("stop_requested" => false), message: "Resuming", finished_at: nil)
      OperationProgressBroadcaster.call(row)
      perform_later(row.operation_id)
      true
    end

    # Closes a paused run ("abandoned") and starts a new one at step 1.
    #
    # @return [OperationProgress, nil] the new run; nil unless the row was paused
    def start_over!(row, steps: ScheduledRun.steps)
      return nil unless row&.status == "paused"

      row.fail!("abandoned")
      OperationProgressBroadcaster.call(row)
      start!(steps: steps)
    end

    # @return [Boolean] Solid Queue holds an unfinished ScheduledRunJob
    def live_job?
      return false unless ActiveJob::Base.queue_adapter_name.to_s == "solid_queue"

      SolidQueue::Job.where(class_name: name, finished_at: nil).exists?
    end

    def pause!(row, details)
      details["stop_requested"] = false
      label = details["steps"][details["index"]]&.dig("label")
      row.update!(status: "paused", details: details, message: label ? "Stopped at: #{label}" : "Stopped")
      OperationProgressBroadcaster.call(row)
      nil
    end
  end

  # @param operation_id [String] the run's OperationProgress
  def perform(operation_id)
    @row = OperationProgress.find_by(operation_id: operation_id, operation_type: OPERATION_TYPE)
    return unless @row&.status == "running"

    steps = @row.details["steps"]
    while (index = @row.details["index"]) < steps.size
      step = ScheduledRun::Step.new(entry: steps[index]["entry"], schedule: steps[index]["schedule"])
      outcome = run_step(index, step)
      return if outcome == :wait
      # A stopped step runs again on Resume; a finished one doesn't.
      return self.class.pause!(@row.reload, @row.details.deep_dup) if outcome == "stopped"

      save!(index) { |details| details["index"] = index + 1 }
      return self.class.pause!(@row.reload, @row.details.deep_dup) if stop_requested?
    end
    @row.complete!(message: "Done", details: @row.details)
    OperationProgressBroadcaster.call(@row)
  end

  private

  # @return [String, Symbol] the step's outcome, or :wait while compaction runs
  def run_step(index, step)
    return finish(index, "skipped") unless step.enabled?
    return compaction_step(index) if step.compaction?

    save!(index, phase: step.label) { |details| details["steps"][index].merge!("outcome" => "running", "started_at" => now, "error" => nil) }
    begin
      CooperativeStop.with(-> { stop_requested? }) { step.run! }
    rescue StandardError => e
      Rails.logger.error("[ScheduledRun] #{step.entry} failed: #{e.class}: #{e.message}")
      return finish(index, "failed", "error" => "#{e.class}: #{e.message}")
    end
    finish(index, step.stoppable? && stop_requested? ? "stopped" : "done")
  end

  def compaction_step(index)
    entry = @row.details["steps"][index]
    return start_compaction(index) unless entry["outcome"] == "waiting"

    run = CompactionRun.find_by(id: entry["compaction_run_id"])
    return finish(index, "failed", "error" => "the compaction run is gone") unless run
    return finish(index, "stopped", "note" => run.status) if run.status == "paused" && stop_requested?
    return finish(index, "done", "note" => run.status) if COMPACTION_ENDED.include?(run.status)

    run.request_pause! if stop_requested?
    save!(index) { |_details| nil } # last progress, for the status line
    wait
  end

  def start_compaction(index)
    run = CompactionRunner.start_or_resume!
    save!(index, phase: "Dream state compaction") do |details|
      details["steps"][index].merge!("outcome" => "waiting", "compaction_run_id" => run.id, "error" => nil)
      details["steps"][index]["started_at"] ||= now
    end
    wait
  end

  def wait
    self.class.set(wait: COMPACTION_POLL).perform_later(@row.operation_id)
    :wait
  end

  def finish(index, outcome, extra = {})
    save!(index) do |details|
      details["steps"][index].merge!("outcome" => outcome, "finished_at" => now, **extra)
      details["steps"][index]["started_at"] ||= now
    end
    outcome
  end

  # Writes the details (the block edits a copy), the finished-step count and the phase, then broadcasts.
  def save!(_index, phase: @row.phase)
    @row.reload
    details = @row.details.deep_dup
    yield details
    finished = details["steps"].count { |step| FINISHED.include?(step["outcome"]) }
    @row.update_progress!(current: finished, phase: phase, message: @row.message, details: details)
    @row.touch
    OperationProgressBroadcaster.call(@row)
  end

  def stop_requested?
    OperationProgress.where(id: @row.id).pick(:details).to_h["stop_requested"] == true
  end

  def now = Time.current.iso8601
end

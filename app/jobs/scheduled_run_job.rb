# frozen_string_literal: true

# "Run all scheduled jobs now" (1.81.0): runs the steps of ScheduledRun one at a time, for machines
# that are off when the schedule would run them. The run's state is an OperationProgress row
# (operation_type "scheduled_run"), so System › Background jobs shows it live:
#
#   details = { "index" => 2, "stop_requested" => false, "token" => "…",
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
# There is no timer: a run is running until it finishes or is stopped. A job that raises outside a
# step pauses the run ("Interrupted: …"). After a power cut Solid Queue marks the job failed (it
# doesn't run it again), so no job is left for the row: the card says so and Stop pauses the row at
# once ("Pause now"); Resume continues at the stored step.
#
# Every start and resume gives the run a new token, passed to its jobs: a job carrying another one
# (a retried old job) does nothing, so one run never has two jobs. The row's details are read and
# written under its row lock, so the switch and the job never overwrite each other.
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
    # @return [OperationProgress, nil] the new run; nil unless idle (two presses at once start one run)
    def start!(steps: ScheduledRun.steps)
      row = with_start_lock do
        next nil unless state == :idle

        details = { "index" => 0, "stop_requested" => false, "token" => SecureRandom.hex(8),
                    "steps" => steps.map { |step| { "entry" => step.entry, "label" => step.label, "schedule" => step.schedule } } }
        OperationProgress.start!(operation_type: OPERATION_TYPE, total_count: steps.size, phase: steps.first&.label,
                                 message: "Starting", details: details)
      end
      return nil unless row

      OperationProgressBroadcaster.call(row)
      perform_later(row.operation_id, row.details["token"])
      row
    end

    # Requests a stop. With no live job to honour it (after a power cut, or a lost job), the row
    # pauses at once, also while a stop is already requested.
    #
    # @param row [OperationProgress]
    # @param live [Boolean] whether a job is running the steps (Solid Queue knows; specs pass it)
    # @return [Symbol, false] :requested, :paused, or false unless the run is running
    def stop!(row, live: live_job?(row))
      return false unless row

      result = locked(row) do
        next false unless row.status == "running"

        details = row.details.deep_dup
        next pause_locked!(row, details) unless live

        details["stop_requested"] = true
        step = details["steps"][details["index"]]
        CompactionRun.find_by(id: step["compaction_run_id"])&.request_pause! if step && step["outcome"] == "waiting"
        row.update!(details: details, message: "Stopping after: #{step&.dig('label')}")
        :requested
      end
      OperationProgressBroadcaster.call(row) if result
      result
    end

    # @param row [OperationProgress]
    # @return [Boolean] false unless the run is paused (two presses at once resume it once)
    def resume!(row)
      return false unless row
      return false unless locked(row) do
        next false unless row.status == "paused"

        row.update!(status: "running", details: row.details.merge("stop_requested" => false, "token" => SecureRandom.hex(8)),
                    message: "Resuming", finished_at: nil)
      end

      OperationProgressBroadcaster.call(row)
      perform_later(row.operation_id, row.details["token"])
      true
    end

    # Closes a paused run ("abandoned") and starts a new one at step 1.
    #
    # @return [OperationProgress, nil] the new run; nil unless the row was paused
    def start_over!(row, steps: ScheduledRun.steps)
      return nil unless row && locked(row) { row.status == "paused" && row.fail!("abandoned") }

      OperationProgressBroadcaster.call(row)
      start!(steps: steps)
    end

    # Whether a Solid Queue job is still going to run this run's steps: an unfinished
    # ScheduledRunJob for this run that hasn't failed. After a power cut Solid Queue fails the job
    # that was running (it isn't run again), so this is false and Stop pauses the row at once.
    #
    # @param row [OperationProgress]
    # @return [Boolean] false outside Solid Queue (the test adapter)
    def live_job?(row)
      return false unless row && ActiveJob::Base.queue_adapter_name.to_s == "solid_queue"

      SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution)
                     .where("arguments LIKE ?", "%#{SolidQueue::Job.sanitize_sql_like(row.operation_id)}%").exists?
    end

    # Pauses the row (the caller holds its lock and passes its details to keep).
    #
    # @return [Symbol] :paused
    def pause_locked!(row, details, message: nil)
      details["stop_requested"] = false
      label = details["steps"][details["index"]]&.dig("label")
      row.update!(status: "paused", details: details, message: message || (label ? "Stopped at: #{label}" : "Stopped"))
      :paused
    end

    # Pauses the row under its lock, then broadcasts.
    def pause!(row, message: nil)
      locked(row) { pause_locked!(row, row.details.deep_dup, message: message) if row.status == "running" }
      OperationProgressBroadcaster.call(row)
      nil
    end

    # Runs the block with the row locked and freshly read.
    def locked(row, &)
      row.with_lock(&)
    end

    # Two presses of Run at once start one run: a database-wide named lock around check and create.
    def with_start_lock
      connection = OperationProgress.connection
      name = connection.quote("graph_mem:#{connection.current_database}:scheduled_run_start")
      return nil unless connection.select_value("SELECT GET_LOCK(#{name}, 5)").to_i == 1

      begin
        yield
      ensure
        connection.select_value("SELECT RELEASE_LOCK(#{name})")
      end
    end
  end

  # @param operation_id [String] the run's OperationProgress
  # @param token [String] the run's token when this job was enqueued (a job from an earlier start
  #   or resume carries an old one and does nothing)
  def perform(operation_id, token = nil)
    @row = OperationProgress.find_by(operation_id: operation_id, operation_type: OPERATION_TYPE)
    return unless @row&.status == "running" && @row.details["token"] == token

    @token = token
    run_steps
  rescue StandardError => e
    # Outside a step (a step's own errors are recorded and the run goes on): pause, so Resume can
    # continue, and let Solid Queue record the failure.
    self.class.pause!(@row, message: "Interrupted: #{e.class}: #{e.message}".truncate(250)) if @row
    raise
  end

  private

  def run_steps
    steps = @row.details["steps"]
    while (index = @row.details["index"]) < steps.size
      step = ScheduledRun::Step.new(entry: steps[index]["entry"], schedule: steps[index]["schedule"])
      outcome = run_step(index, step)
      return if outcome == :wait
      # A stopped step runs again on Resume; a finished one doesn't.
      return self.class.pause!(@row) if outcome == "stopped"

      save!(index) { |details| details["index"] = index + 1 }
      return self.class.pause!(@row) if stop_requested?
    end
    @row.complete!(message: "Done", details: @row.details)
    OperationProgressBroadcaster.call(@row)
  end

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
    self.class.set(wait: COMPACTION_POLL).perform_later(@row.operation_id, @token)
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
  # Writes the details under the row lock (the block edits a fresh copy, so a stop requested
  # meanwhile is kept), the finished-step count and the phase, then broadcasts.
  def save!(_index, phase: nil)
    @row.with_lock do
      details = @row.details.deep_dup
      yield details
      finished = details["steps"].count { |step| FINISHED.include?(step["outcome"]) }
      @row.update_progress!(current: finished, phase: phase || @row.phase, message: @row.message, details: details)
      @row.touch
    end
    OperationProgressBroadcaster.call(@row)
  end

  # Read past the query cache: Solid Queue runs jobs with it on, and a step that writes nothing (an
  # embedding backfill while Ollama fails) would otherwise never see the stop.
  def stop_requested?
    OperationProgress.uncached { OperationProgress.where(id: @row.id).pick(:details) }.to_h["stop_requested"] == true
  end

  def now = Time.current.iso8601
end

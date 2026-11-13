# frozen_string_literal: true

require "fugit"

# Starts "Run all scheduled jobs now" by itself on a machine that was off at the scheduled times
# (1.86.0). Solid Queue skips a recurring slot it missed, so the night jobs never run on a
# workstation that is switched off at night; this job (config/recurring.yml, production, every 15
# minutes) notices that nothing ran lately and starts a ScheduledRunJob with the trigger "catch-up".
#
# It does nothing (a debug line says why) unless the setting scheduled_run_catch_up_enabled is on
# (System › Settings, default on) and the oldest live Solid Queue supervisor has been up at least
# BOOT_GRACE, so the machine has settled before a long run starts. Then:
#
# - **A run cut off** (a power cut, a lost job: the row is running and no Solid Queue job is left for
#   it) is resumed at the step it stopped at: it was interrupted, not paused by the operator. One info
#   line says so. A run cut off while stopping only finishes its stop (paused): the operator asked it to
#   stop (Graphy, #173). A run that is running with a live job, or paused, is left alone (a paused run
#   is never auto-resumed: it was paused for a reason).
# - **Otherwise it starts a new run** only when the nightly slot has been missed: no scheduled run and
#   no compaction run started at or after `due_since`, the previous fire time of the compaction
#   entry's schedule in config/recurring.yml (computed with Fugit in Solid Queue's time zone; 20 hours
#   ago when no schedule can be read). A host that is off at night is overdue on every boot (the same
#   time of day, no drift); a host that stayed up ran the 3:00 compaction itself, so nothing is due.
#   A compaction run running with a job behind it also blocks. A paused compaction run does not: it is
#   usually paused by the MCP write valve (CompactionValve), and only the run's compaction step
#   (CompactionRunner) resumes it on a host that is off at night (Graphy, #173).
#
#   ScheduledRunCatchUpJob.perform_now # => the new or resumed OperationProgress, or nil
class ScheduledRunCatchUpJob < ApplicationJob
  queue_as :default

  # How long the oldest live supervisor must have been up before a run starts.
  BOOT_GRACE = 20.minutes
  # The window used when the compaction entry's schedule can't be read (see #due_since).
  OVERDUE_AFTER = 20.hours
  LOG_TAG = "[ScheduledRunCatchUp]"

  # Resumes an interrupted scheduled run, or starts a new one when the nightly slot was missed.
  #
  # @return [OperationProgress, nil] the resumed or new run; nil when a condition blocked it (or the
  #   run changed meanwhile)
  def perform
    reason = blocked_by
    return log_skip(reason) if reason

    row = ScheduledRunJob.current
    state = ScheduledRunJob.state(row)
    return finish_stop(row) if state == :stopping
    return resume_interrupted(row) if state != :idle

    row = ScheduledRunJob.start!(trigger: ScheduledRunJob::TRIGGER_CATCH_UP)
    Rails.logger.info(started_message(row)) if row
    row
  end

  private

  # @return [String, nil] why nothing is done now, nil when something is (resume or start)
  def blocked_by
    return "setting off" unless AppSettings.scheduled_run_catch_up_enabled?
    return "no live supervisor" if booted_at.nil?
    return "booted #{minutes_since(booted_at)} min ago (< #{BOOT_GRACE.in_minutes.to_i})" if booted_at > BOOT_GRACE.ago

    row = ScheduledRunJob.current
    state = ScheduledRunJob.state(row)
    return "a scheduled run is #{state}" if state == :paused || (state != :idle && ScheduledRunJob.live_job?(row))
    return nil unless state == :idle # an interrupted run: resumed whatever ran lately

    overdue_blocker
  end

  # @return [String, nil] why a new run isn't due: something started since the last nightly slot
  def overdue_blocker
    return "a scheduled run started #{minutes_since(last_scheduled_run_at)} min ago (since #{due_since.iso8601})" if since_due?(last_scheduled_run_at)
    return "a compaction run started #{minutes_since(last_compaction_at)} min ago (since #{due_since.iso8601})" if since_due?(last_compaction_at)
    return "a compaction run is running" if CompactionRun.exists?(status: "running") && ScheduledRunJob.compaction_job_live?

    nil
  end

  # Finishes the stop of an orphaned stopping run (stop! with no live job pauses it) and leaves it paused.
  def finish_stop(row)
    return nil unless ScheduledRunJob.stop!(row, live: false) == :paused

    Rails.logger.info("#{LOG_TAG} paused a run that was stopping when its job was lost (#{row.operation_id}); not resumed")
    nil
  end

  # Pauses an orphaned run at once (stop! with no live job) and resumes it at its stored step.
  def resume_interrupted(row)
    return nil unless ScheduledRunJob.stop!(row, live: false) == :paused && ScheduledRunJob.resume!(row)

    Rails.logger.info("#{LOG_TAG} resumed an interrupted run at step #{row.reload.details['index'].to_i + 1} of #{row.total_count} " \
                      "(#{row.operation_id}): supervisor up #{minutes_since(booted_at)} min, no job was running it")
    row
  end

  def log_skip(reason)
    Rails.logger.debug { "#{LOG_TAG} skipped: #{reason}" }
    nil
  end

  def started_message(row)
    "#{LOG_TAG} started scheduled run #{row.operation_id}: setting on, supervisor up #{minutes_since(booted_at)} min " \
      "(>= #{BOOT_GRACE.in_minutes.to_i}), no scheduled run active, last scheduled run #{ago(last_scheduled_run_at)}, " \
      "last compaction run #{ago(last_compaction_at)}, both before the last nightly slot #{due_since.iso8601}"
  end

  # The previous fire time of the compaction entry's schedule (ScheduledRun's steps are this
  # environment's recurring.yml section), read the way Solid Queue reads it: Fugit, in
  # SolidQueue.time_zone when set, else the system's. OVERDUE_AFTER ago when there is no such
  # entry or its schedule can't be parsed.
  #
  # @return [Time]
  def due_since
    @due_since ||= previous_slot(ScheduledRun.steps.find(&:compaction?)&.schedule) || OVERDUE_AFTER.ago
  end

  # @param schedule [String, nil] a recurring.yml schedule ("at 3am every day")
  # @return [Time, nil] its previous fire time; nil unless it is a cron-like schedule
  def previous_slot(schedule)
    return nil if schedule.blank?

    cron = Fugit.parse(schedule, multi: :fail)
    return nil unless cron.respond_to?(:previous_time)

    zone = SolidQueue.time_zone
    cron = Fugit.parse("#{cron.to_cron_s} #{zone}", multi: :fail) if cron.respond_to?(:zone) && cron.zone.nil? && zone.present?
    cron.previous_time.utc
  rescue StandardError => e
    Rails.logger.debug { "#{LOG_TAG} can't read schedule #{schedule.inspect}: #{e.class}: #{e.message}" }
    nil
  end

  # The oldest live supervisor's start. A supervisor is "live" while it still beats
  # (SolidQueue.process_alive_threshold); one left by a power cut is ignored until pruned. The
  # kind is "Supervisor(fork)" or "Supervisor(async)". SolidQueue::Process lives in the queue
  # database (config.solid_queue.connects_to) and is read like the SolidQueue::Job lookups of
  # ScheduledRunJob.
  #
  # @return [Time, nil]
  def booted_at
    return @booted_at if defined?(@booted_at)

    @booted_at = SolidQueue::Process.where("kind LIKE ?", "Supervisor%")
                                    .where(last_heartbeat_at: SolidQueue.process_alive_threshold.ago..).minimum(:created_at)
  end

  # @return [Time, nil] when the latest scheduled run started, whatever its outcome
  def last_scheduled_run_at
    @last_scheduled_run_at ||= OperationProgress.where(operation_type: ScheduledRunJob::OPERATION_TYPE).maximum(:started_at)
  end

  # @return [Time, nil] when the latest compaction run started
  def last_compaction_at
    @last_compaction_at ||= CompactionRun.maximum(:started_at)
  end

  def since_due?(time) = time.present? && time >= due_since

  def minutes_since(time) = ((Time.current - time) / 60).floor

  def ago(time) = time ? "#{minutes_since(time)} min ago" : "never"
end

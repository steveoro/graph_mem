# frozen_string_literal: true

module System
  # Background jobs (UI-7, moved from Projects & Data): the scheduled-jobs switch (1.81.0), the
  # dream-state compactor, garbage collector and relation-repair cards, and their controls. Each
  # control redirects back here.
  class JobsController < BaseController
    self.nav_section = :jobs

    # What the scheduled-jobs switch may do in each state (ScheduledRunJob.state).
    SCHEDULED_RUN_ACTIONS = { idle: %w[start], running: %w[stop], paused: %w[resume start_over] }.freeze

    # GET /system/jobs
    def index
      @snapshot = MaintenanceDashboardSnapshot.call
    end

    def start_compaction
      unless AppSettings.dream_state_compactor_enabled?
        redirect_to system_jobs_path, alert: t("operator.maintenance.compactor_disabled")
        return
      end

      run = CompactionRunner.start_or_resume!
      redirect_to system_jobs_path, notice: "Dream-state compaction started (run ##{run.id})."
    end

    def pause_compaction
      run = CompactionRun.current
      if run&.running?
        run.request_pause!
        redirect_to system_jobs_path, notice: "Pause requested for dream-state compaction (run ##{run.id})."
      else
        redirect_to system_jobs_path, alert: "No running compaction to pause."
      end
    end

    def run_garbage_collection
      unless AppSettings.garbage_collector_enabled?
        redirect_to system_jobs_path, alert: t("operator.maintenance.gc_disabled")
        return
      end

      result = GarbageCollectionRunner.call
      counts = result[:reports].map { |r| "#{r[:report_type]}: #{r[:count]}" }.join(", ")
      redirect_to system_jobs_path,
                  notice: "Garbage collection completed. #{counts}. Pruned #{result[:audit_logs_pruned]} audit logs."
    end

    # POST /system/jobs/scheduled_run, the one switch of "Run all scheduled jobs now" (1.81.0).
    # `expected` is the action the page offered (start, stop, resume or start_over); a press made
    # for another state (a stale tab, a run that finished meanwhile) changes nothing.
    def scheduled_run
      row = ScheduledRunJob.current
      expected = params[:expected].to_s
      allowed = SCHEDULED_RUN_ACTIONS.fetch(ScheduledRunJob.state(row), [])
      done = allowed.include?(expected) && scheduled_run_action(expected, row)
      return redirect_to(system_jobs_path, alert: t("system.jobs.scheduled_run.changed")) unless done

      redirect_to system_jobs_path, notice: t("system.jobs.scheduled_run.notice.#{expected}")
    end

    def repair_relations
      # Operator "Repair" is an explicit destructive cleanup; ambiguous issues are deleted.
      result = RelationIntegrityRepairer.call(dry_run: false, review_ambiguous: false)
      message = relation_repair_notice(result)
      redirect_to system_jobs_path, notice: message
    end

    private

    # @return [Boolean] whether the action took effect
    def scheduled_run_action(expected, row)
      case expected
      when "start" then ScheduledRunJob.start!.present?
      when "stop" then ScheduledRunJob.stop!(row)
      when "resume" then ScheduledRunJob.resume!(row)
      when "start_over" then ScheduledRunJob.start_over!(row).present?
      end
    end

    def relation_repair_notice(result)
      parts = [
        "Relation repair completed.",
        "Deleted #{result.deleted_count} relation(s).",
        "Same-direction duplicates: #{result.same_direction_duplicates.size}.",
        "Reverse pairs: #{result.reverse_pairs.size}.",
        "Merge collisions: #{result.merge_collisions.size}."
      ]
      parts.join(" ")
    end
  end
end

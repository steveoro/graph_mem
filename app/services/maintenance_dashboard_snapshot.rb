# frozen_string_literal: true

# What Projects & Data › Background jobs shows (UI-6): compaction state, graph stats, the latest
# maintenance reports, the garbage collector's last run and the recurring schedules. HomeSnapshot
# also reads #graph_stats.
class MaintenanceDashboardSnapshot
  SCHEDULE_PATH = Rails.root.join("config/recurring.yml").freeze

  def self.call
    new.call
  end

  # @return [Hash] what the cards show (#cards, the live frame's poll, 1.84.0)
  def self.cards
    new.cards
  end

  # @return [Hash] #cards plus `graph_stats` (the page's totals line)
  def call
    cards.merge(graph_stats: graph_stats)
  end

  # Everything the cards read, without the graph totals (an anti-join), so a poll stays cheap.
  #
  # @return [Hash] `{ refreshed_at:, compaction:, latest_reports:, operations:, schedules:,
  #   cursor_entity:, scheduled_run:, active: }` (`active`: some job is running, so the page polls
  #   faster)
  def cards
    data = {
      refreshed_at: Time.current,
      compaction: compaction_snapshot,
      latest_reports: latest_reports_by_type,
      operations: operation_snapshots,
      schedules: schedule_hints,
      cursor_entity: cursor_entity,
      scheduled_run: scheduled_run_snapshot
    }
    data.merge(active: data.dig(:scheduled_run, :state).in?(%i[running stopping]) || data.dig(:compaction, :dream_state) == "running" ||
                       data.dig(:operations, :garbage_collection, :status) == "running")
  end

  # The "Run all scheduled jobs now" card (1.81.0): the switch's state, the latest run (its
  # OperationProgress snapshot plus when it last changed), the steps (the run's, or the ones a new
  # run would have), and the newest audit-log entry since the run started. Plain values only.
  #
  # @return [Hash] `{ state:, run:, steps:, latest_audit:, live:, step_progress: }` (`live`: a job is
  #   still going to run the steps; false after a shutdown. `step_progress`: see #step_progress)
  def scheduled_run_snapshot
    row = ScheduledRunJob.current
    steps = row ? row.details.to_h["steps"].to_a : ScheduledRun.steps.map { |step| { "label" => step.label, "schedule" => step.schedule } }
    {
      state: ScheduledRunJob.state(row),
      run: row && row.snapshot.merge(index: row.details.to_h["index"]),
      steps: steps,
      latest_audit: row&.started_at && latest_audit_since(row.started_at),
      live: %w[running].include?(row&.status) && ScheduledRunJob.live_job?(row),
      step_progress: step_progress(row)
    }
  end

  # How far the running step is (1.84.0), for the bar under its label: what the step reported
  # (StepProgress, stored on the step by ScheduledRunJob), else the progress row of the work it
  # started (the compaction run it waits on, the garbage collection started during it).
  #
  # @param row [OperationProgress, nil] the scheduled run
  # @return [Hash, nil] `{ percent:, done:, total: (Integer), label: String }`; nil when the run isn't running, the
  #   step reports nothing (an indeterminate bar) or has nothing to count
  def step_progress(row)
    return nil unless row&.status == "running"

    details = row.details.to_h
    step = details["steps"].to_a[details["index"].to_i]
    return nil unless step && %w[running waiting].include?(step["outcome"])

    reported = step["progress"]
    return counted(reported["done"], reported["total"], reported["label"]) if reported

    progress = step_operation(step)
    progress && counted(progress.current_count, progress.total_count, progress.phase.presence || step["label"])
  end

  # Graph totals and the orphan count (also read on its own by HomeSnapshot#counts).
  #
  # @return [Hash] `{ totals: { entities:, observations:, relations:, audit_logs: }, orphan_count: }`
  def graph_stats
    {
      totals: {
        entities: MemoryEntity.count,
        observations: MemoryObservation.count,
        relations: MemoryRelation.count,
        audit_logs: AuditLog.count
      },
      orphan_count: orphan_count
    }
  end

  private

  def counted(done, total, label)
    total = total.to_i
    return nil unless total.positive?

    done = done.to_i.clamp(0, total)
    { percent: done * 100 / total, done: done, total: total, label: label.to_s }
  end

  # @return [OperationProgress, nil] the progress row of the work a compaction or GC step started
  def step_operation(step)
    if step["compaction_run_id"]
      CompactionRun.find_by(id: step["compaction_run_id"])&.operation_progress
    elsif step["entry"] == "GarbageCollectionJob" && step["started_at"].present?
      OperationProgress.where(operation_type: "garbage_collection", created_at: Time.zone.parse(step["started_at"])..).recent.first
    end
  end

  # Read once per snapshot (#cursor_entity reads it too).
  def compaction_snapshot
    @compaction_snapshot ||= CompactionRunner.status_snapshot
  end

  def orphan_count
    MemoryEntity
      .left_joins(:memory_observations)
      .where(memory_observations: { id: nil })
      .where.not(id: MemoryRelation.select(:from_entity_id))
      .where.not(id: MemoryRelation.select(:to_entity_id))
      .count
  end

  def operation_snapshots
    {
      garbage_collection: OperationProgress.where(operation_type: "garbage_collection").recent.first&.snapshot
    }
  end

  def latest_reports_by_type
    MaintenanceReport::REPORT_TYPES.index_with do |type|
      report = MaintenanceReport.by_type(type).recent.first
      next nil unless report

      {
        id: report.id,
        report_type: report.report_type,
        created_at: report.created_at,
        count: report_count(report),
        data: report.data
      }
    end
  end

  def report_count(report)
    data = report.data || {}
    data["count"] || data[:count] || 0
  end

  def schedule_hints
    return {} unless SCHEDULE_PATH.exist?

    yaml = YAML.safe_load(SCHEDULE_PATH.read, permitted_classes: [], aliases: true) || {}
    env = Rails.env
    (yaml[env] || {}).transform_values { |job| job["schedule"] }
  rescue StandardError
    {}
  end

  def latest_audit_since(time)
    log = AuditLog.where(created_at: time..).order(created_at: :desc, id: :desc).first
    log && { action: log.action, auditable_type: log.auditable_type, auditable_id: log.auditable_id, actor: log.actor,
             created_at: log.created_at.iso8601 }
  end

  def cursor_entity
    entity_id = compaction_snapshot[:cursor_entity_id]
    return nil if entity_id.blank?

    entity = MemoryEntity.find_by(id: entity_id)
    return nil unless entity

    { id: entity.id, name: entity.name, entity_type: entity.entity_type }
  end
end

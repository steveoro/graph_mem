# frozen_string_literal: true

# What Projects & Data › Background jobs shows (UI-6): compaction state, graph stats, the latest
# maintenance reports, the garbage collector's last run and the recurring schedules. HomeSnapshot
# also reads #graph_stats.
class MaintenanceDashboardSnapshot
  SCHEDULE_PATH = Rails.root.join("config/recurring.yml").freeze

  def self.call
    new.call
  end

  def call
    {
      refreshed_at: Time.current,
      compaction: compaction_snapshot,
      graph_stats: graph_stats,
      latest_reports: latest_reports_by_type,
      operations: operation_snapshots,
      schedules: schedule_hints,
      cursor_entity: cursor_entity,
      scheduled_run: scheduled_run_snapshot
    }
  end

  # The "Run all scheduled jobs now" card (1.81.0): the switch's state, the latest run (its
  # OperationProgress snapshot plus when it last changed), the steps (the run's, or the ones a new
  # run would have), and the newest audit-log entry since the run started. Plain values only.
  #
  # @return [Hash] `{ state:, run:, steps:, latest_audit:, live: }` (`live`: a job is still going to run
  #   the steps; false after a shutdown)
  def scheduled_run_snapshot
    row = ScheduledRunJob.current
    steps = row ? row.details.to_h["steps"].to_a : ScheduledRun.steps.map { |step| { "label" => step.label, "schedule" => step.schedule } }
    {
      state: ScheduledRunJob.state(row),
      run: row && row.snapshot.merge(index: row.details.to_h["index"]),
      steps: steps,
      latest_audit: row&.started_at && latest_audit_since(row.started_at),
      live: %w[running].include?(row&.status) && ScheduledRunJob.live_job?(row)
    }
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

  def compaction_snapshot
    CompactionRunner.status_snapshot
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

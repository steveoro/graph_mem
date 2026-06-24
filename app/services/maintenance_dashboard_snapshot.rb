# frozen_string_literal: true

# Aggregates operator dashboard state from compaction runs, graph stats, and maintenance reports.
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
      schedules: schedule_hints,
      cursor_entity: cursor_entity
    }
  end

  private

  def compaction_snapshot
    CompactionRunner.status_snapshot
  end

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

  def orphan_count
    MemoryEntity
      .left_joins(:memory_observations)
      .where(memory_observations: { id: nil })
      .where.not(id: MemoryRelation.select(:from_entity_id))
      .where.not(id: MemoryRelation.select(:to_entity_id))
      .count
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

  def cursor_entity
    entity_id = compaction_snapshot[:cursor_entity_id]
    return nil if entity_id.blank?

    entity = MemoryEntity.find_by(id: entity_id)
    return nil unless entity

    { id: entity.id, name: entity.name, entity_type: entity.entity_type }
  end
end

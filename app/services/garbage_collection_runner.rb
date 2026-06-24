# frozen_string_literal: true

# Runs garbage-collection diagnostics and returns created report summaries.
class GarbageCollectionRunner
  def self.call
    new.call
  end

  def call
    report_orphans
    report_duplicates
    prune_audit_logs

    {
      reports: latest_reports,
      audit_logs_pruned: @audit_logs_pruned
    }
  end

  private

  def report_orphans
    orphan_ids = MemoryEntity
      .left_joins(:memory_observations)
      .where(memory_observations: { id: nil })
      .where.not(id: MemoryRelation.select(:from_entity_id))
      .where.not(id: MemoryRelation.select(:to_entity_id))
      .pluck(:id, :name, :entity_type)

    entities = orphan_ids.map { |id, name, type| { id: id, name: name, entity_type: type } }

    @orphans_report = MaintenanceReport.create!(
      report_type: "orphans",
      data: { count: entities.size, entities: entities.first(100) }
    )

    Rails.logger.info "[GC] Found #{entities.size} orphan entities"
  end

  def report_duplicates
    dupes = MemoryObservation
      .select(:memory_entity_id, :content, "COUNT(*) as cnt")
      .group(:memory_entity_id, :content)
      .having("COUNT(*) > 1")
      .map do |obs|
        {
          entity_id: obs.memory_entity_id,
          content_preview: obs.content.truncate(100),
          count: obs.cnt
        }
      end

    @duplicates_report = MaintenanceReport.create!(
      report_type: "duplicates",
      data: { count: dupes.size, observations: dupes.first(100) }
    )

    Rails.logger.info "[GC] Found #{dupes.size} duplicate observation groups"
  end

  def prune_audit_logs
    @audit_logs_pruned = AuditLog.prune!
    Rails.logger.info "[GC] Pruned #{@audit_logs_pruned} audit logs older than #{AuditLog::MAX_AGE_DAYS} days"
  end

  def latest_reports
    [ @orphans_report, @duplicates_report ].map do |report|
      {
        id: report.id,
        report_type: report.report_type,
        count: report.data["count"] || report.data[:count] || 0,
        created_at: report.created_at
      }
    end
  end
end

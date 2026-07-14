# frozen_string_literal: true

# Runs garbage-collection diagnostics and returns created report summaries.
class GarbageCollectionRunner
  def self.call
    new.call
  end

  def call
    report_orphans
    cleanup_duplicates
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

  def cleanup_duplicates
    groups = MemoryObservation
      .select(:memory_entity_id, :content, "MIN(id) AS keep_id", "COUNT(*) AS cnt")
      .group(:memory_entity_id, :content)
      .having("COUNT(*) > 1")

    deleted_count = 0
    affected_entity_ids = []
    duplicate_groups = []

    groups.each do |group|
      delete_ids = MemoryObservation
        .where(memory_entity_id: group.memory_entity_id, content: group.content)
        .where.not(id: group.keep_id)
        .order(:id)
        .pluck(:id)

      next if delete_ids.empty?

      MemoryObservation.where(id: delete_ids).destroy_all
      deleted_count += delete_ids.size
      affected_entity_ids << group.memory_entity_id

      duplicate_groups << {
        entity_id: group.memory_entity_id,
        content_preview: group.content.truncate(100),
        count: group.cnt
      }
    end

    repair_counters_for(affected_entity_ids.uniq)

    @duplicates_report = MaintenanceReport.create!(
      report_type: "duplicates",
      data: {
        count: deleted_count,
        group_count: duplicate_groups.size,
        observations: duplicate_groups.first(100)
      }
    )

    Rails.logger.info "[GC] Deleted #{deleted_count} duplicate observations from #{duplicate_groups.size} groups"
  end

  def repair_counters_for(entity_ids)
    return if entity_ids.empty?

    MemoryEntity.where(id: entity_ids).find_each do |entity|
      entity.update_column(:memory_observations_count, entity.memory_observations.count)
    end
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

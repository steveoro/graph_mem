# frozen_string_literal: true

class GetGraphStatsTool < ApplicationTool
  def self.tool_name
    "get_graph_stats"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: true,
    destructive_hint: false,
    idempotent_hint: true,
    open_world_hint: false
  )

  description "Return live knowledge-graph health metrics (totals, entity_type_distribution, orphan_count, " \
    "most_connected, recent updates). Takes no arguments. " \
    "Do not use for stored report documents; use `get_maintenance_reports` instead. " \
    "Do not use to page actual entities; use `list_entities` instead. " \
    "Do not use for a topic summary; use `summarize` instead. " \
    "Do not use for compaction job status; use `dream_state_status` instead. " \
    "Do not use for software version; use `get_version` instead."

  def call
    {
      totals: totals,
      entity_type_distribution: entity_type_distribution,
      orphan_count: orphan_count,
      most_connected: most_connected,
      recently_updated: recently_updated,
      latest_maintenance: latest_maintenance
    }
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    logger.error "GetGraphStatsTool unexpected error: #{e.class}: #{e.message}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def totals
    {
      entities: MemoryEntity.count,
      observations: MemoryObservation.count,
      relations: MemoryRelation.count,
      audit_logs: AuditLog.count
    }
  end

  def entity_type_distribution
    MemoryEntity.group(:entity_type).order("count_all DESC").count
  end

  def orphan_count
    MemoryEntity
      .left_joins(:memory_observations)
      .where(memory_observations: { id: nil })
      .where.not(id: MemoryRelation.select(:from_entity_id))
      .where.not(id: MemoryRelation.select(:to_entity_id))
      .count
  end

  def most_connected
    from_counts = MemoryRelation.group(:from_entity_id).count
    to_counts   = MemoryRelation.group(:to_entity_id).count

    merged = from_counts.merge(to_counts) { |_k, a, b| a + b }
    top_ids = merged.sort_by { |_id, cnt| -cnt }.first(10)

    top_ids.map do |entity_id, count|
      entity = MemoryEntity.find_by(id: entity_id)
      next unless entity
      { id: entity.id, name: entity.name, entity_type: entity.entity_type, relation_count: count }
    end.compact
  end

  def recently_updated
    MemoryEntity
      .order(updated_at: :desc)
      .limit(10)
      .pluck(:id, :name, :entity_type, :updated_at)
      .map { |id, name, type, at| { id: id, name: name, entity_type: type, updated_at: at.iso8601 } }
  end

  def latest_maintenance
    MaintenanceReport::REPORT_TYPES.each_with_object({}) do |type, hash|
      report = MaintenanceReport.by_type(type).recent.first
      next unless report
      hash[type] = {
        created_at: report.created_at.iso8601,
        count: report.data["count"]
      }
    end
  end
end

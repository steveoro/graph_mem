# frozen_string_literal: true

# Aggregates embedding coverage, index status, and runtime config for operator UI.
class EmbeddingStatusSnapshot
  def self.call
    new.call
  end

  def call
    vector_enabled = EmbeddingService.vector_enabled?
    entities_total = MemoryEntity.count
    observations_total = MemoryObservation.count
    entities_missing = vector_enabled ? MemoryEntity.where(embedding: nil).count : entities_total
    observations_missing = vector_enabled ? MemoryObservation.where(embedding: nil).count : observations_total
    entities_embedded = entities_total - entities_missing
    observations_embedded = observations_total - observations_missing
    indexes = EmbeddingIndexStatus.indexes
    total_records = entities_total + observations_total
    embedded_records = entities_embedded + observations_embedded

    {
      vector_enabled: vector_enabled,
      entities_total: entities_total,
      entities_missing: entities_missing,
      entities_embedded: entities_embedded,
      observations_total: observations_total,
      observations_missing: observations_missing,
      observations_embedded: observations_embedded,
      indexes: indexes,
      config: EmbeddingService.config_snapshot.merge(sources: EmbeddingConfig.config_sources),
      last_maintenance_report: last_maintenance_report,
      pending_job: EmbeddingsMaintenanceEnqueuer.pending_summary,
      coverage_percent: coverage_percent(total_records, embedded_records, vector_enabled),
      vector_search_ready: vector_search_ready?(
        vector_enabled,
        entities_missing,
        observations_missing,
        indexes
      )
    }
  end

  private

  def last_maintenance_report
    MaintenanceReport.by_type("embedding_maintenance").recent.first
  end

  def coverage_percent(total, embedded, vector_enabled)
    return 0 unless vector_enabled
    return 100 if total.zero?

    ((embedded.to_f / total) * 100).round
  end

  def vector_search_ready?(vector_enabled, entities_missing, observations_missing, indexes)
    vector_enabled &&
      entities_missing.zero? &&
      observations_missing.zero? &&
      indexes[:memory_entities] &&
      indexes[:memory_observations]
  end
end

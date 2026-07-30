# frozen_string_literal: true

# Recurring self-healing sweep for the graph:
# - repair duplicate/broken relations
# - delete duplicate observations and recount affected counters
# - reconcile all memory_observations_count counters
# - backfill missing entity/observation embeddings
# - detect and remove dangling relations (pointing to deleted entities)
# - detect observation lifecycle corruption (active with obsoleted_at, superseded without superseded_by, cross-entity superseded_by)
class GraphIntegrityService
  def self.call
    new.call
  end

  def call
    Rails.logger.info "[GraphIntegrity] Starting self-healing sweep"

    relation_result = repair_relation_integrity
    gc_result = GarbageCollectionRunner.call
    counters_repaired = recount_counters
    dangling_result = repair_dangling_relations
    embedding_result = repair_stale_embeddings
    lifecycle_issues = detect_observation_lifecycle_corruption

    Rails.logger.info "[GraphIntegrity] Completed self-healing sweep " \
      "(counters repaired: #{counters_repaired}, dangling relations: #{dangling_result}, " \
      "embeddings backfilled: #{embedding_result[:backfilled]}, " \
      "embedding failures: #{embedding_result[:failed].size}, " \
      "lifecycle issues: #{lifecycle_issues.size})"

    {
      relation_integrity: relation_result,
      garbage_collection: gc_result,
      counters_repaired: counters_repaired,
      dangling_relations_removed: dangling_result,
      embeddings_backfilled: embedding_result,
      observation_lifecycle_issues: lifecycle_issues
    }
  end

  private

  def repair_relation_integrity
    RelationIntegrityRepairer.call
  rescue StandardError => e
    Rails.logger.error "[GraphIntegrity] Relation integrity repair failed: #{e.message}"
    { error: e.message, error_class: e.class.name }
  end

  def recount_counters
    repaired = 0
    MemoryEntity.find_each do |entity|
      actual = entity.memory_observations.count
      next if entity.memory_observations_count == actual

      entity.update_column(:memory_observations_count, actual)
      repaired += 1
    end
    repaired
  end

  def repair_dangling_relations
    valid_entity_ids = MemoryEntity.pluck(:id).to_set
    dangling = MemoryRelation.where.not(from_entity_id: valid_entity_ids)
      .or(MemoryRelation.where.not(to_entity_id: valid_entity_ids))

    count = dangling.count
    dangling.destroy_all
    count
  end

  def repair_stale_embeddings
    return { backfilled: 0, failed: [] } unless EmbeddingService.vector_enabled?

    backfilled = 0
    failed = []

    MemoryEntity.where(embedding: nil).find_each do |entity|
      if EmbeddingService.embed_entity(entity)
        backfilled += 1
      else
        failed << { entity_id: entity.id, name: entity.name }
      end
    end

    MemoryObservation.where(embedding: nil).find_each do |obs|
      EmbeddingService.embed_observation(obs)
    end

    { backfilled: backfilled, failed: failed }
  end

  def detect_observation_lifecycle_corruption
    issues = []

    MemoryObservation.active.where.not(obsoleted_at: nil).find_each do |obs|
      issues << {
        kind: "lifecycle_corruption",
        observation_id: obs.id,
        entity_id: obs.memory_entity_id,
        issue: "active observation has obsoleted_at set",
        obsoleted_at: obs.obsoleted_at.iso8601
      }
    end

    MemoryObservation.where(status: MemoryObservation::SUPERSEDED_STATUS).where(superseded_by_id: nil).find_each do |obs|
      issues << {
        kind: "lifecycle_corruption",
        observation_id: obs.id,
        entity_id: obs.memory_entity_id,
        issue: "superseded observation has no superseded_by reference"
      }
    end

    MemoryObservation.where.not(superseded_by_id: nil).find_each do |obs|
      next if obs.superseded_by&.memory_entity_id == obs.memory_entity_id

      issues << {
        kind: "lifecycle_corruption",
        observation_id: obs.id,
        entity_id: obs.memory_entity_id,
        issue: "superseded_by references a different entity",
        superseded_by_id: obs.superseded_by_id,
        superseded_by_entity_id: obs.superseded_by&.memory_entity_id
      }
    end

    issues
  end
end

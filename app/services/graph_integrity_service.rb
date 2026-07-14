# frozen_string_literal: true

# Recurring self-healing sweep for the graph:
# - repair duplicate/broken relations
# - delete duplicate observations and recount affected counters
# - reconcile all memory_observations_count counters
class GraphIntegrityService
  def self.call
    new.call
  end

  def call
    Rails.logger.info "[GraphIntegrity] Starting self-healing sweep"

    relation_result = repair_relation_integrity
    gc_result = GarbageCollectionRunner.call
    recount_counters

    Rails.logger.info "[GraphIntegrity] Completed self-healing sweep"
    {
      relation_integrity: relation_result,
      garbage_collection: gc_result
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
    MemoryEntity.find_each do |entity|
      actual = entity.memory_observations.count
      next if entity.memory_observations_count == actual

      entity.update_column(:memory_observations_count, actual)
    end
  end
end

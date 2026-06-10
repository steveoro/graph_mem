# frozen_string_literal: true

# Builds deterministic entity ID lists for dream-state compaction phases.
class CompactionTraversal
  CHILD_RELATION_TYPES = OrphanMatchingStrategy::CHILD_RELATION_TYPES

  PHASES = CompactionRun::PHASES

  def entity_ids_for_phase(phase)
    case phase
    when "orphans"
      orphan_ids
    when "tree_walk"
      tree_walk_ids
    else
      []
    end
  end

  def next_phase_after(phase)
    idx = PHASES.index(phase)
    return nil unless idx

    PHASES[idx + 1]
  end

  private

  def orphan_ids
    OrphanMatchingStrategy.new.orphan_nodes.pluck(:id).sort
  end

  def tree_walk_ids
    ids = []
    visited = Set.new
    queue = MemoryEntity.where(entity_type: "Project").order(:id).pluck(:id)

    until queue.empty?
      entity_id = queue.shift
      next if visited.include?(entity_id)

      visited.add(entity_id)
      ids << entity_id

      child_ids = MemoryRelation
        .where(to_entity_id: entity_id, relation_type: CHILD_RELATION_TYPES)
        .order(:from_entity_id)
        .pluck(:from_entity_id)

      queue.concat(child_ids)
    end

    ids
  end
end

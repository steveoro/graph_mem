# frozen_string_literal: true

# Captures what a merge destroys or moves, so ChangeSetUndo::Merge can put it back (UI-4a).
# Called by NodeOperationsStrategy#merge_into_once inside its transaction, on rows it has locked:
#
#   before = EntityMergeSnapshot.capture_before(source, target)
#   ...the merge...
#   change_set.add_merge_step!(EntityMergeSnapshot.complete(before, target))
#
# The source keeps every column plus its vector as hex (`embedding_hex`: VEC_ToText rounds to
# 6 digits, HEX/UNHEX restores the bytes exactly). Five queries per merge, whatever the number of
# observations and relations.
class EntityMergeSnapshot
  class << self
    # @param source [MemoryEntity] the entity about to be merged away
    # @param target [MemoryEntity] the survivor
    # @return [Hash] the "before" half of a merge step
    def capture_before(source, target)
      relations = MemoryRelation.where(from_entity_id: source.id).or(MemoryRelation.where(to_entity_id: source.id)).to_a
      {
        "source" => ChangeSet.snapshot_attributes(source).except("embedding")
                             .merge("embedding_hex" => embedding_hex(source.id)),
        "target" => { "id" => target.id, "aliases_before" => target.aliases },
        "observation_ids" => source.memory_observations.pluck(:id),
        "relations" => relations.map { |relation| ChangeSet.snapshot_attributes(relation) },
        "children" => children_of(source.id, relations)
      }
    end

    # @param before [Hash] from {.capture_before}
    # @param target [MemoryEntity] the survivor, as the merge left it in memory
    # @return [Hash] the merge step stored in the change set's "merges" section
    def complete(before, target)
      relations = before.delete("relations")
      after = MemoryRelation.where(id: relations.map { |relation| relation["id"] }).to_h do |relation|
        [ relation.id, relation ]
      end
      repointed, destroyed = relations.partition { |relation| after.key?(relation["id"]) }

      before.merge(
        "target" => before["target"].merge("aliases_after" => target.aliases),
        "repointed" => repointed.map { |relation| repoint_entry(relation, after[relation["id"]]) },
        "destroyed" => destroyed,
        "at" => Time.current.utc.iso8601(6)
      )
    end

    private

    def embedding_hex(entity_id)
      MemoryEntity.where(id: entity_id).pick(Arel.sql("HEX(embedding)"))
    end

    def children_of(source_id, relations)
      child_ids = relations.filter_map do |relation|
        relation.from_entity_id if relation.to_entity_id == source_id && relation.relation_type == "part_of"
      end
      return [] if child_ids.empty?

      MemoryEntity.where(id: child_ids).pluck(:id, :project_id)
    end

    def repoint_entry(before, relation)
      {
        "id" => relation.id, "relation_type" => relation.relation_type,
        "from_before" => before["from_entity_id"], "to_before" => before["to_entity_id"],
        "from_after" => relation.from_entity_id, "to_after" => relation.to_entity_id
      }
    end
  end
end

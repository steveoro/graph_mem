# frozen_string_literal: true

# Scans and repairs relation integrity issues that can block dream-state compaction.
#
# - same_direction_duplicates: multiple rows for the same (from, to, type) tuple
# - reverse_pairs: A→B and B→A with the same type (allowed by index, often accidental)
# - merge_collisions: child X linked to multiple parents with the same relation type
class RelationIntegrityRepairer
  Result = Struct.new(
    :dry_run,
    :same_direction_duplicates,
    :reverse_pairs,
    :merge_collisions,
    :deleted_relation_ids,
    keyword_init: true
  ) do
    def deleted_count
      deleted_relation_ids.size
    end

    def issues_count
      same_direction_duplicates.size + reverse_pairs.size + merge_collisions.size
    end
  end

  def self.call(dry_run: false)
    new(dry_run: dry_run).call
  end

  def initialize(dry_run: false)
    @dry_run = dry_run
  end

  def call
    same_direction = find_same_direction_duplicates
    reverse = find_reverse_pairs
    merge = find_merge_collisions

    deleted_ids = []
    unless @dry_run
      deleted_ids.concat(repair_same_direction_duplicates!(same_direction))
      deleted_ids.concat(repair_reverse_pairs!(reverse))
      deleted_ids.concat(repair_merge_collisions!(merge))
    end

    Result.new(
      dry_run: @dry_run,
      same_direction_duplicates: same_direction,
      reverse_pairs: reverse,
      merge_collisions: merge,
      deleted_relation_ids: deleted_ids.uniq
    )
  end

  private

  def find_same_direction_duplicates
    duplicate_keys.flat_map do |(from_id, to_id, rel_type)|
      relations = MemoryRelation.where(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: rel_type
      ).order(:id).to_a

      next [] if relations.size <= 1

      keep, *delete_rows = relations
      [ {
        kind: "same_direction",
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: rel_type,
        keep_id: keep.id,
        delete_ids: delete_rows.map(&:id)
      } ]
    end
  end

  def find_reverse_pairs
    duplicates = []
    seen_pairs = Set.new

    MemoryRelation.includes(:from_entity, :to_entity).find_each do |rel|
      pair_key = [ [ rel.from_entity_id, rel.to_entity_id ].sort, rel.relation_type ].flatten
      next if seen_pairs.include?(pair_key)

      reverse = MemoryRelation.find_by(
        from_entity_id: rel.to_entity_id,
        to_entity_id: rel.from_entity_id,
        relation_type: rel.relation_type
      )

      next unless reverse

      seen_pairs.add(pair_key)
      keep_rel, delete_rel = [ rel, reverse ].sort_by(&:id)

      duplicates << {
        kind: "reverse_pair",
        relation_type: rel.relation_type,
        keep_id: keep_rel.id,
        delete_id: delete_rel.id,
        keep: relation_summary(keep_rel),
        delete: relation_summary(delete_rel)
      }
    end

    duplicates
  end

  def find_merge_collisions
    collisions = []
    seen = Set.new

    MemoryRelation
      .select(:from_entity_id, :relation_type)
      .group(:from_entity_id, :relation_type)
      .having("COUNT(DISTINCT to_entity_id) > 1")
      .pluck(:from_entity_id, :relation_type)
      .each do |child_id, rel_type|
        relations = MemoryRelation
          .where(from_entity_id: child_id, relation_type: rel_type)
          .order(:id)
          .to_a

        keep, *delete_rows = relations
        key = [ child_id, rel_type ]
        next if seen.include?(key)

        seen.add(key)
        collisions << {
          kind: "merge_collision",
          child_entity_id: child_id,
          relation_type: rel_type,
          parent_entity_ids: relations.map(&:to_entity_id),
          keep_id: keep.id,
          delete_ids: delete_rows.map(&:id)
        }
      end

    collisions
  end

  def duplicate_keys
    MemoryRelation
      .group(:from_entity_id, :to_entity_id, :relation_type)
      .having("COUNT(*) > 1")
      .pluck(:from_entity_id, :to_entity_id, :relation_type)
  end

  def repair_same_direction_duplicates!(issues)
    delete_ids_from_issues(issues, :delete_ids)
  end

  def repair_reverse_pairs!(issues)
    issues.flat_map { |issue| delete_relation_ids([ issue[:delete_id] ]) }
  end

  def repair_merge_collisions!(issues)
    delete_ids_from_issues(issues, :delete_ids)
  end

  def delete_ids_from_issues(issues, key)
    ids = issues.flat_map { |issue| Array(issue[key]) }
    delete_relation_ids(ids)
  end

  def delete_relation_ids(ids)
    ids.filter_map do |relation_id|
      relation = MemoryRelation.find_by(id: relation_id)
      next unless relation

      relation.destroy!
      relation_id
    end
  end

  def relation_summary(relation)
    {
      id: relation.id,
      from_entity_id: relation.from_entity_id,
      from_name: relation.from_entity&.name,
      to_entity_id: relation.to_entity_id,
      to_name: relation.to_entity&.name
    }
  end
end

# frozen_string_literal: true

# Scans and repairs relation integrity issues that can block dream-state compaction.
#
# - same_direction_duplicates: multiple rows for the same (from, to, type) tuple
# - reverse_pairs: A→B and B→A with the same type (review-only when ambiguous)
# - merge_collisions: child X linked to multiple parents with single-parent types
#
# With review_ambiguous: true (GraphIntegrityService: the dream-state pre-flight and the nightly
# garbage collection) only same-direction duplicates are deleted, which the unique key
# (from_entity_id, to_entity_id, relation_type) makes impossible, so no part_of is ever deleted
# there; reverse pairs and merge collisions are queued as relation_integrity review rows.
# With review_ambiguous: false (the operator's "Repair relation duplicates") the extra parents and
# the newer edge of each pair are deleted too: under the membership lock (taken before the
# transaction), in one transaction, with each child of a deleted part_of synced to the parent it
# keeps. A ProjectMembership::Collision rolls the whole repair back; the result carries the reason.
#
#   result = RelationIntegrityRepairer.call(dry_run: false, review_ambiguous: false)
#   result.error # => nil, or "cannot move 'SynthWidget' into project 4: …" (nothing deleted)
class RelationIntegrityRepairer
  Result = Struct.new(
    :dry_run,
    :same_direction_duplicates,
    :reverse_pairs,
    :merge_collisions,
    :deleted_relation_ids,
    :review_items,
    :error,
    keyword_init: true
  ) do
    def deleted_count
      deleted_relation_ids.size
    end

    def issues_count
      same_direction_duplicates.size + reverse_pairs.size + merge_collisions.size
    end
  end

  # @param dry_run [Boolean] find the issues, write nothing
  # @param review_ambiguous [Boolean] queue reverse pairs and merge collisions for review (true)
  #   instead of deleting them (false)
  # @return [Result] `error` is set (and nothing deleted) when a membership sync refused the repair
  def self.call(dry_run: false, review_ambiguous: true)
    new(dry_run: dry_run, review_ambiguous: review_ambiguous).call
  end

  def initialize(dry_run: false, review_ambiguous: true)
    @dry_run = dry_run
    @review_ambiguous = review_ambiguous
  end

  # @return [Result]
  def call
    return scan_and_repair if @dry_run || @review_ambiguous

    # Can delete part_of edges: the membership lock before the transaction (the advisory-first
    # rule), and the issues found under it, so the walk sees the edges the repair deletes.
    ProjectMembership.with_membership_lock do
      ActiveRecord::Base.transaction { scan_and_repair }
    end
  rescue ProjectMembership::Collision, ProjectMembership::LockTimeout => e
    refused(e)
  end

  private

  def scan_and_repair
    same_direction = find_same_direction_duplicates
    reverse = find_reverse_pairs
    merge = find_merge_collisions

    deleted_ids = []
    review_items = []
    unless @dry_run
      deleted_ids.concat(repair_same_direction_duplicates!(same_direction))
      if @review_ambiguous
        review_items.concat(queue_reverse_pairs!(reverse))
        review_items.concat(queue_merge_collisions!(merge))
      else
        deleted_ids.concat(repair_reverse_pairs!(reverse))
        deleted_ids.concat(repair_merge_collisions!(merge))
        sync_children!
      end
    end

    Result.new(
      dry_run: @dry_run,
      same_direction_duplicates: same_direction,
      reverse_pairs: reverse,
      merge_collisions: merge,
      deleted_relation_ids: deleted_ids.uniq,
      review_items: review_items
    )
  end

  # Nothing was deleted: the issues are found again (read-only) so the operator sees them.
  def refused(error)
    same_direction = find_same_direction_duplicates
    Result.new(
      dry_run: @dry_run, same_direction_duplicates: same_direction, reverse_pairs: find_reverse_pairs,
      merge_collisions: find_merge_collisions, deleted_relation_ids: [], review_items: [],
      error: error.is_a?(ProjectMembership::LockTimeout) ? "#{error.message}; retry shortly" : "#{error.message}; rename or re-parent one of them, then repair again"
    )
  end

  # Each child that lost a part_of edge takes the project of the parent it keeps (or none).
  def sync_children!
    MemoryEntity.where(id: @part_of_children.to_a).order(:id).each { |child| ProjectMembership.sync!(child) }
  end

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
        next unless RelationSemantics.single_parent?(rel_type)

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

  def queue_reverse_pairs!(issues)
    issues.map do |issue|
      {
        id: SecureRandom.uuid,
        kind: "relation_integrity",
        issue_kind: "reverse_pair",
        payload: issue
      }
    end
  end

  def queue_merge_collisions!(issues)
    issues.map do |issue|
      {
        id: SecureRandom.uuid,
        kind: "relation_integrity",
        issue_kind: "merge_collision",
        payload: issue
      }
    end
  end

  def delete_ids_from_issues(issues, key)
    ids = issues.flat_map { |issue| Array(issue[key]) }
    delete_relation_ids(ids)
  end

  def delete_relation_ids(ids)
    @part_of_children ||= Set.new
    begin
      Current.deletion_reason = "duplicate"
      ids.filter_map do |relation_id|
        relation = MemoryRelation.find_by(id: relation_id)
        next unless relation

        relation.destroy!
        @part_of_children << relation.from_entity_id if MemoryRelation.reads_as_part_of?(relation.relation_type)
        relation_id
      end
    ensure
      Current.deletion_reason = nil
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

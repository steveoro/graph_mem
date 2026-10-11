# frozen_string_literal: true

# Fills `memory_entities.project_id` for pre-scope data: walks each Project
# root's part_of tree and stamps every descendant with that project. Members
# move with their tree — the stamp is recomputed from the CURRENT edges, so
# an entity re-parented under a different root lands under the new project.
#
# Idempotent: rows already carrying the right project_id are not touched, so
# a second run changes 0 rows. Unrooted entities stay NULL (global). No
# renames and no re-embedding — project_id is not an embedding field.
#
# Used by the backfill migration and by
# `bin/rails graph_mem:backfill_project_ids[dry_run]` for the report only.
class ProjectIdBackfill
  Report = Struct.new(:per_project, :unrooted, :conflicts, :changed, keyword_init: true)

  # @param out [#puts, #call] report sink — $stdout for the rake task, a
  #   `say` lambda for the migration.
  def initialize(out: $stdout)
    @out = out
  end

  # @param dry_run [Boolean] print the report without writing
  # @return [Report] per-project member counts, unrooted count, conflicts,
  #   changed-row count (0 on a re-run)
  def run(dry_run: false)
    membership, conflicts = compute_membership

    per_project = membership.values.group_by(&:itself).transform_values(&:size)
    rooted = membership.keys
    unrooted_count = MemoryEntity.where.not(id: rooted)
                                 .where.not(entity_type: "Project").count

    changed = apply_membership(membership) unless dry_run
    changed ||= 0

    report = Report.new(
      per_project: per_project,
      unrooted: unrooted_count,
      conflicts: conflicts,
      changed: changed
    )
    print_report(report, dry_run: dry_run)
    report
  end

  private

  # @return [Array(Hash<Integer, Integer>, Hash<Integer, Array<Integer>>)]
  #   entity_id => project_id map, plus entity_id => [project_ids] when two
  #   roots reach the same entity (impossible under single-parent part_of —
  #   still reported, never silently resolved).
  def compute_membership
    membership = {}
    conflicts = Hash.new { |hash, key| hash[key] = [] }

    project_ids.each do |project_id|
      RelationSemantics.descendant_ids(project_id).each do |entity_id|
        if membership.key?(entity_id) && membership[entity_id] != project_id
          conflicts[entity_id] |= [ membership[entity_id], project_id ]
        else
          membership[entity_id] = project_id
        end
      end
    end

    [ membership, conflicts ]
  end

  def apply_membership(membership)
    changed = 0
    membership.group_by { |_, project_id| project_id }.each do |project_id, pairs|
      # `where.not(project_id: x)` drops NULL rows (SQL NULL != x →
      # UNKNOWN) — spell out the NULL case or pre-scope rows never stamp.
      changed += MemoryEntity.where(id: pairs.map(&:first))
                             .where("project_id IS NULL OR project_id <> ?", project_id)
                             .update_all(project_id: project_id)
    end
    changed
  end

  def project_ids
    MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).order(:id).pluck(:id)
  end

  def print_report(report, dry_run:)
    emit(dry_run ? "project_id backfill (DRY RUN)" : "project_id backfill")
    project_names.each do |project_id, name|
      emit "  #{name} (##{project_id}): #{report.per_project[project_id] || 0} members"
    end
    emit "  unrooted (stays NULL): #{report.unrooted}"
    emit "  conflicts: #{report.conflicts.size}" +
         (report.conflicts.any? ? " #{report.conflicts.inspect}" : "")
    emit(dry_run ? "  (no rows written)" : "  changed rows: #{report.changed}")
  end

  def emit(line)
    @out.respond_to?(:puts) ? @out.puts(line) : @out.call(line)
  end

  def project_names
    MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
                .order(:id).pluck(:id, :name).to_h
  end
end

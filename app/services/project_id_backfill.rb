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

  MAX_LOCK_WAIT_RETRIES = 3

  # @param dry_run [Boolean] print the report without writing
  # @return [Report] per-project member counts, unrooted count, conflicts,
  #   changed-row count (0 on a re-run)
  def run(dry_run: false)
    # Compute + apply under the shared membership lock so a live re-parent
    # can't land between the two steps and get stamped under its old
    # project. Every part_of writer that reroutes subtrees takes the same
    # lock (ProjectMembership.reassign!), so the walk sees a stable tree.
    # A row-lock wait from a NON-membership writer can still surface as
    # ActiveRecord::LockWaitTimeout — retry a bounded number of times
    # (the membership lock ordering keeps these rare).
    attempts = 0
    begin
      attempts += 1
      membership = conflicts = nil
      unrooted_count = changed = 0
      ProjectMembership.with_membership_lock do
        membership, conflicts = compute_membership
        unrooted_count = MemoryEntity.where.not(id: membership.keys)
                                     .where.not(entity_type: "Project").count
        changed = dry_run ? 0 : apply_membership(membership)
      end
    rescue ActiveRecord::LockWaitTimeout, ProjectMembership::LockTimeout
      retry if attempts < MAX_LOCK_WAIT_RETRIES
      raise
    end

    per_project = membership.values.group_by(&:itself).transform_values(&:size)

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
      member_ids(project_id).each do |entity_id|
        if membership.key?(entity_id) && membership[entity_id] != project_id
          conflicts[entity_id] |= [ membership[entity_id], project_id ]
        else
          membership[entity_id] = project_id
        end
      end
    end

    [ membership, conflicts ]
  end

  # Reachable members of a project — ProjectMembership.member_ids, the
  # same walk every membership writer applies (reference_stub edges and
  # nested Projects stop it: the referencing project does not own a
  # parked stub, and a nested Project starts its own scope).
  def member_ids(project_id)
    ProjectMembership.member_ids(project_id)
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
    # Rows no part_of chain reaches are UNROOTED → project_id NULL. Rows
    # stamped by an earlier run then re-parented away must be cleared or
    # they sit in a scope that does not own them (membership mirrors the
    # CURRENT edges).
    changed += MemoryEntity.where.not(id: membership.keys)
                           .where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
                           .where.not(project_id: nil)
                           .update_all(project_id: nil)
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

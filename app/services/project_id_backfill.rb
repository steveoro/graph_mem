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
    # Compute + apply under the shared membership lock so a live re-parent
    # can't land between the two steps and get stamped under its old
    # project. Every part_of writer that reroutes subtrees takes the same
    # lock (ProjectMembership.reassign!), so the walk sees a stable tree.
    membership = conflicts = nil
    unrooted_count = changed = 0
    ProjectMembership.with_membership_lock do
      membership, conflicts = compute_membership
      unrooted_count = MemoryEntity.where.not(id: membership.keys)
                                   .where.not(entity_type: "Project").count
      changed = dry_run ? 0 : apply_membership(membership)
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

  # Reachable members of a project, walking part_of edges breadth-first —
  # NOT RelationSemantics.descendant_ids: two edge/entity kinds stop the
  # walk.
  # (a) `reference_stub: true` edges park an unresolved target in the
  #     GLOBAL namespace for whichever project declares it first — the
  #     referencing project does not own it. Following them stamps the
  #     stub into the referencer's scope, after which it can never be
  #     claimed and the declarer creates a duplicate.
  # (b) Nested Project children: a Project inside another project's tree
  #     starts its OWN scope (nearest-Project wins, matching
  #     ProjectMembership.project_id_for_parent). Its row stays NULL —
  #     Projects are global — and its members belong to ITS walk, not the
  #     outer one.
  def member_ids(project_id)
    ids = Set.new
    queue = [ project_id ]
    until queue.empty?
      current = queue.shift
      # COALESCE: edges with NULL properties or no reference_stub key must
      # NOT be filtered out — `NOT(JSON_EXTRACT = ...)` evaluates NULL for
      # them and would drop them along with the stubs.
      MemoryRelation.where(to_entity_id: current, relation_type: "part_of")
        .where("COALESCE(JSON_UNQUOTE(JSON_EXTRACT(properties, '$.reference_stub')), 'false') <> 'true'")
        .pluck(:from_entity_id).each do |child_id|
          next if ids.include?(child_id)
          next if project_entity_ids.include?(child_id) # nested Project: its own scope

          ids.add(child_id)
          queue << child_id
        end
    end
    ids
  end

  def project_entity_ids
    @project_entity_ids ||= MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
                                        .pluck(:id).to_set
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

# frozen_string_literal: true

module ReviewPolicies
  # Applies `relation_retype` rows of operation "swap" (Dream State R1b, plan item 4). Off by
  # default. A swap turns a dependency-like entity's `part_of` a Project into the Project's
  # `depends_on` it, so the entity and its own subtree leave the project's scope; this policy does
  # it unattended only when nothing says the project owns the entity: the project has no fact that
  # names the entity (DependencyEvidence: held by it, its keyword path holds it, or its text names
  # it while the path is pending) and matches one of OWNERSHIP_PHRASES. Such a row stays for the
  # operator, and so does one whose entity is no longer of a dependency-like type (the setting or
  # the entity changed since it was queued).
  #
  # Never a "retype" row (it creates a part_of, a membership move) nor an "add" row: both are
  # refused row by row. The AutoApply hard rule is lifted for this kind only; every other
  # destructive and choice kind is still refused. CompactionReviewService.apply takes the
  # membership lock before the row lock. A name collision (ProjectMembership::Collision, or the
  # swap's own refusal) counts as skipped; a busy lock (LockTimeout) counts as busy and ends the
  # step for this run. At most 100 per run.
  #
  #   ReviewPolicies::AutoApplyRelationRetype.new.call
  #   # => { "acted" => 3, "skipped" => 1, "busy" => 0, "refused" => 0, "change_sets" => ["…"] }
  class AutoApplyRelationRetype < AutoApply
    PER_RUN = 100
    KIND = "relation_retype"
    OPERATION = CompactionReviewApplier::RelationRetypeDependency::SWAP
    # A fact naming the entity with one of these says the project owns it (shown in the policy's
    # help text, Settings › Review policies).
    OWNERSHIP_PHRASES = [ "part of this project", "our own", "maintained here", "vendored", "forked" ].freeze
    OWNERSHIP_PATTERN = /\b(?:#{OWNERSHIP_PHRASES.map { |phrase| phrase.split.map { |word| Regexp.escape(word) }.join('\s+') }.join('|')})\b/i

    # @param library [MemoryEntity] the row's dependency-like entity
    # @param project [MemoryEntity] the Project it is part_of
    # @return [Boolean] a fact of the project names the entity with an ownership phrase
    def self.ownership_signal?(library, project)
      DependencyEvidence.facts_matching(library, project, OWNERSHIP_PATTERN).any?
    end

    private

    # The AutoApply hard rule, lifted for this kind only.
    def applicable_kind?(kind)
      kind == KIND || super
    end

    # Swap rows only (a relation_retype row can't be edited: its payload is what was queued).
    def eligible
      MaintenanceReportRow.active.where(kind: KIND).where("JSON_VALUE(payload, '$.operation') = ?", OPERATION)
    end

    def with_locked_row(row)
      return if @stopped
      return @stats["refused"] += 1 unless applicable_kind?(row.kind) && swap?(row)
      return @stats["skipped"] += 1 if left_for_operator?(row)

      result = CompactionReviewService.apply(row.row_uuid, {}, report_type: row.report_type)
      @stats[result[:success] ? "acted" : "skipped"] += 1
    rescue ProjectMembership::Collision
      @stats["skipped"] += 1
    rescue ActiveRecord::StatementInvalid => e
      raise unless TransientDbError.busy?(e)

      @stats["busy"] += 1
    end

    def swap?(row)
      row.effective_payload["operation"].to_s == OPERATION
    end

    # Read on the live edge's endpoints; a gone edge or endpoint is left to the apply, which
    # answers it as a stale row.
    def left_for_operator?(row)
      relation = MemoryRelation.find_by(id: row.effective_payload["relation_id"].to_i)
      library = relation&.from_entity
      project = relation&.to_entity
      return false unless library && project

      !dependency_types.entity?(library) || self.class.ownership_signal?(library, project)
    end

    def dependency_types
      @dependency_types ||= DependencyLikeTypes.current
    end
  end
end

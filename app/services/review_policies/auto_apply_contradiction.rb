# frozen_string_literal: true

module ReviewPolicies
  # Auto-resolve value changes (1.92.0, docs/plans/contradiction-auto-resolve-plan.md). On by
  # default, for one class of contradiction rows only: the two facts are on one entity, have the same
  # source and perspective, and are a plain value change (ContradictionDetector.value_change) of the
  # key-value class: one "Key: value" line each, the same key, one changed value, the same unit. The
  # older fact is marked superseded by the newer one (link and reason set); nothing is deleted, and
  # the policy run is an undoable change set.
  #
  # The free-text class (two sentences that differ in 1-2 values) is applied only with
  # auto_apply_contradiction_free_text on, within auto_apply_contradiction_max_tokens changed values
  # and auto_apply_contradiction_max_distance (the live cosine distance). Any other contradiction
  # (a polarity pair that isn't a value change) stays for the operator. A tie on which fact is newer
  # skips the row. At most 100 per run.
  #
  # A revert sticks: once this policy superseded a fact and the fact is active again (the run was
  # undone, or an operator re-activated it), the pair is left for the operator, for as long as the
  # audit row is kept (AuditLog::MAX_AGE_DAYS).
  #
  #   ReviewPolicies::AutoApplyContradiction.new.call
  #   # => { "acted" => 2, "skipped" => 0, "busy" => 0, "refused" => 0, "change_sets" => ["…"] }
  class AutoApplyContradiction < AutoApply
    PER_RUN = 100
    KIND = "contradiction"

    private

    # The AutoApply hard rule, lifted for this kind only: every other choice and destructive kind
    # is still refused.
    def applicable_kind?(kind)
      kind == KIND || super
    end

    # One query for every row's facts and one for the reverted ones, whatever the backlog.
    def eligible
      rows = MaintenanceReportRow.active.where(kind: KIND).to_a
      fact_ids = rows.flat_map { |row| pair_ids(row) }.uniq
      facts = MemoryObservation.where(id: fact_ids).index_by(&:id)
      reverted = reverted_ids(fact_ids)
      ids = rows.select { |row| newer_side(row, facts: facts, reverted: reverted, count_ties: true) }.map(&:id)
      MaintenanceReportRow.where(id: ids)
    end

    def pair_ids(row)
      payload = row.effective_payload
      [ payload["observation_id_1"], payload["observation_id_2"] ].map(&:to_i)
    end

    # The facts this policy already superseded once (its audit rows): active again means someone
    # reverted it.
    #
    # @return [Set<Integer>]
    def reverted_ids(fact_ids)
      AuditLog.where(auditable_type: "MemoryObservation", auditable_id: fact_ids, actor: "policy:#{policy_name}")
              .distinct.pluck(:auditable_id).to_set
    end

    # Applies one row: the live facts are read again first (an operator action in between wins),
    # and the service takes its own locks and re-checks the row and both observations.
    def with_locked_row(row)
      return if @stopped
      return @stats["refused"] += 1 unless applicable_kind?(row.kind)

      newer = newer_side(row)
      return @stats["skipped"] += 1 unless newer

      result = CompactionReviewService.apply(row.row_uuid, { keep_observation_id: newer.id },
                                             report_type: row.report_type, resolution: :supersede)
      @stats[result[:success] ? "acted" : "skipped"] += 1
    rescue ActiveRecord::StatementInvalid => e
      raise unless TransientDbError.busy?(e)

      @stats["busy"] += 1
    end

    # The fact to keep, read from the live observations (the payload's text is cut and may be old).
    #
    # @return [MemoryObservation, nil] nil when the row isn't an applicable value change
    # @param facts [Hash{Integer => MemoryObservation}, nil] preloaded facts (nil reads them now)
    # @param reverted [Set<Integer>, nil] preloaded reverted_ids (nil reads them now)
    def newer_side(row, facts: nil, reverted: nil, count_ties: false)
      ids = pair_ids(row)
      pair = (facts || MemoryObservation.where(id: ids).index_by(&:id)).values_at(*ids)
      return nil unless ids.uniq.size == 2 && pair.all? { |fact| fact&.active? }

      older, newer = by_age(*pair)
      change = ContradictionDetector.value_change(older || pair.first, newer || pair.last)
      return nil unless change && applicable_class?(change, pair)
      return nil if (reverted || reverted_ids(ids)).intersect?(ids.to_set)
      return newer if newer

      @stats["skipped"] += 1 if count_ties
      nil
    end

    def applicable_class?(change, pair)
      case change[:class]
      when :key_value then true
      when :free_text
        AppSettings.review_flag?(:auto_apply_contradiction_free_text) &&
          change[:count] <= AppSettings.review_number(:auto_apply_contradiction_max_tokens) &&
          within_distance?(pair)
      else false
      end
    end

    # @return [Array<MemoryObservation>, nil] [older, newer] by valid_from (both set), then created_at,
    #   then updated_at; nil on a tie
    def by_age(first, second)
      keys = [ ->(fact) { fact.valid_from if first.valid_from && second.valid_from }, :created_at.to_proc, :updated_at.to_proc ]
      keys.each do |key|
        a = key.call(first)
        b = key.call(second)
        return a < b ? [ first, second ] : [ second, first ] if a && b && a != b
      end
      nil
    end

    # The live cosine distance of the two facts, when both are embedded.
    def within_distance?(pair)
      distance = MemoryObservation.connection.select_value(MemoryObservation.sanitize_sql([
        "SELECT VEC_DISTANCE_COSINE(a.embedding, b.embedding) FROM memory_observations a, memory_observations b " \
        "WHERE a.id = ? AND b.id = ? AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL", pair.first.id, pair.last.id
      ]))
      !distance.nil? && distance.to_f <= AppSettings.review_number(:auto_apply_contradiction_max_distance)
    end
  end
end

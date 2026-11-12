# frozen_string_literal: true

module ReviewPolicies
  # Whether a pair review row is about two facts with no subject in common, by their keyword paths
  # (1.78.0, FactKeywords::Relatedness), with the generators' own rules:
  #
  # - a `contradiction` row whose facts ContradictionDetector.pairable no longer pairs;
  # - a `fact_supersede` row whose facts are unrelated (FactKeywords::Relatedness: siblings, or
  #   mentions with none in common) and that no search term found. Judged rows too (1.80.0): the
  #   generator no longer judges such a pair, so a `superseded` verdict on it was the judge's mistake;
  # - an **unjudged** `fact_supersede` row that isn't the same fact with a different detail (1.82.0:
  #   without the judge, being related isn't enough). A judged row is never dismissed just for being
  #   related: the judge saw it.
  #
  # A row whose facts are gone or inactive is the Dangling policy's; a row whose paths are still
  # pending can't be told yet.
  #
  #   ReviewPolicies::SubjectCheck.status(row) # => :dismiss, :keep, :pending or :not_applicable
  module SubjectCheck
    KINDS = %w[contradiction fact_supersede].freeze
    REASON = "the facts share no subject (keyword paths)"
    # 1.83.0: a pair that does share something, but isn't the same fact the generators need.
    REASON_NOT_SAME = "not the same fact (keyword paths)"

    module_function

    # @param row [MaintenanceReportRow]
    # @return [Symbol] :dismiss, :keep, :pending (a path not computed yet) or :not_applicable
    #   (another kind, a term match, or a fact gone or inactive)
    def status(row)
      return :not_applicable unless KINDS.include?(row.kind)

      payload = row.effective_payload.to_h.deep_stringify_keys
      row.kind == "contradiction" ? contradiction_status(payload) : fact_supersede_status(payload)
    end

    # @return [String, nil] the dismissal reason (REASON for unrelated facts, REASON_NOT_SAME for the
    #   others), nil when the row still applies
    def reason(row)
      return nil unless status(row) == :dismiss

      pair = row.kind == "contradiction" ? %w[observation_id_1 observation_id_2] : %w[fact_observation_id observation_id]
      payload = row.effective_payload.to_h.deep_stringify_keys
      first, second = active_pair(*payload.values_at(*pair))
      FactKeywords::Relatedness.compare(first, second).hard_unrelated? ? REASON : REASON_NOT_SAME
    end

    def contradiction_status(payload)
      first, second = active_pair(payload["observation_id_1"], payload["observation_id_2"])
      return :not_applicable unless first && second
      return :pending unless FactKeywords::Relatedness.computed?(first, second)

      ContradictionDetector.pairable(first, second, payload["distance"]) ? :keep : :dismiss
    end

    def fact_supersede_status(payload)
      return :not_applicable if payload.dig("signals", "term").present?

      fact, observation = active_pair(payload["fact_observation_id"], payload["observation_id"])
      return :not_applicable unless fact && observation
      return :pending unless FactKeywords::Relatedness.computed?(fact, observation)

      comparison = FactKeywords::Relatedness.compare(fact, observation)
      # A judged row is dismissed only for facts unrelated by their entity mentions, never by LLM words alone.
      return :dismiss if comparison.hard_unrelated?
      return :keep unless payload["verdict"] == FactSupersede::Judge::UNJUDGED

      comparison.same_fact_different_detail? ? :keep : :dismiss
    end

    # @return [Array(MemoryObservation, MemoryObservation), Array(nil, nil)] both active, in order
    def active_pair(first_id, second_id)
      rows = MemoryObservation.active.where(id: [ first_id, second_id ].map(&:to_i)).includes(:memory_entity).index_by(&:id)
      [ rows[first_id.to_i], rows[second_id.to_i] ]
    end
    private_class_method :contradiction_status, :fact_supersede_status, :active_pair
  end
end

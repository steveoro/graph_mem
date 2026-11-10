# frozen_string_literal: true

module ReviewPolicies
  # Whether a pair review row is about two facts with no subject in common, by their keyword paths
  # (1.78.0, FactKeywords::Relatedness), with the generators' own rules:
  #
  # - a `contradiction` row whose facts ContradictionDetector.pairable no longer pairs;
  # - an `unjudged` `fact_supersede` row whose facts are unrelated (both mention entities, none in
  #   common) and that no search term found. A judged row is the judge's call and is left alone.
  #
  # A row whose facts are gone or inactive is the Dangling policy's; a row whose paths are still
  # pending can't be told yet.
  #
  #   ReviewPolicies::SubjectCheck.status(row) # => :dismiss, :keep, :pending or :not_applicable
  module SubjectCheck
    KINDS = %w[contradiction fact_supersede].freeze
    REASON = "the facts share no subject (keyword paths)"

    module_function

    # @param row [MaintenanceReportRow]
    # @return [Symbol] :dismiss, :keep, :pending (a path not computed yet) or :not_applicable
    #   (another kind, a judged row, a term match, or a fact gone or inactive)
    def status(row)
      return :not_applicable unless KINDS.include?(row.kind)

      payload = row.effective_payload.to_h.deep_stringify_keys
      row.kind == "contradiction" ? contradiction_status(payload) : fact_supersede_status(payload)
    end

    # @return [String, nil] the dismissal reason, nil when the row still applies
    def reason(row)
      REASON if status(row) == :dismiss
    end

    def contradiction_status(payload)
      first, second = active_pair(payload["observation_id_1"], payload["observation_id_2"])
      return :not_applicable unless first && second
      return :pending unless FactKeywords::Relatedness.computed?(first, second)

      ContradictionDetector.pairable(first, second, payload["distance"]) ? :keep : :dismiss
    end

    def fact_supersede_status(payload)
      return :not_applicable unless payload["verdict"] == FactSupersede::Judge::UNJUDGED && payload.dig("signals", "term").blank?

      fact, observation = active_pair(payload["fact_observation_id"], payload["observation_id"])
      return :not_applicable unless fact && observation
      return :pending unless FactKeywords::Relatedness.computed?(fact, observation)

      FactKeywords::Relatedness.compare(fact, observation).subject == :unrelated ? :dismiss : :keep
    end

    # @return [Array(MemoryObservation, MemoryObservation), Array(nil, nil)] both active, in order
    def active_pair(first_id, second_id)
      rows = MemoryObservation.active.where(id: [ first_id, second_id ].map(&:to_i)).includes(:memory_entity).index_by(&:id)
      [ rows[first_id.to_i], rows[second_id.to_i] ]
    end
    private_class_method :contradiction_status, :fact_supersede_status, :active_pair
  end
end

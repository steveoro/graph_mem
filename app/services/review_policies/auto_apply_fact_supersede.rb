# frozen_string_literal: true

module ReviewPolicies
  # "Outdated by a fact" rows (fact supersede, Decision 8). Off by default. Eligible rows: the judge
  # said `superseded` at or above auto_apply_fact_supersede_min_confidence, no guard, an entity
  # inside the fact's project, and a fact an operator marked (SourceFact#operator_confirmed_fact?).
  # Agent-marked facts and unjudged rows only ever propose. The apply supersedes when the row has
  # a replacement and retires otherwise. At most 100 per run.
  class AutoApplyFactSupersede < AutoApply
    PER_RUN = 100
    KIND = "fact_supersede"

    private

    # The AutoApply hard rule, lifted for this kind only: every other choice and destructive kind
    # is still refused.
    def applicable_kind?(kind)
      kind == KIND || super
    end

    def eligible
      threshold = AppSettings.review_number(:auto_apply_fact_supersede_min_confidence)
      facts = {}
      ids = MaintenanceReportRow.active.where(kind: KIND, confidence: threshold..).select do |row|
        payload = row.effective_payload
        next false unless confident_unguarded_scoped?(payload, threshold)

        fact_id = payload["fact_observation_id"].to_i
        facts.fetch(fact_id) { facts[fact_id] = MemoryObservation.find_by(id: fact_id)&.operator_confirmed_fact? || false }
      end.map(&:id)
      MaintenanceReportRow.where(id: ids)
    end

    def confident_unguarded_scoped?(payload, threshold)
      payload["verdict"] == "superseded" && payload["confidence"].to_f >= threshold && payload["guard"].blank? &&
        payload.dig("signals", "scoped") == true && payload["project_id"].present?
    end
  end
end

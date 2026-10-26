# frozen_string_literal: true

module ReviewPolicies
  # Relationship proposals in the high band at or above auto_apply_relationship_min_confidence,
  # never part_of. At most 50 per run.
  class AutoApplyRelationships < AutoApply
    PER_RUN = 50

    private

    def eligible
      threshold = AppSettings.review_number(:auto_apply_relationship_min_confidence)
      rows = MaintenanceReportRow.active.where(kind: "relationship_proposal", confidence: threshold..)
      ids = rows.select do |row|
        payload = row.effective_payload
        payload["confidence_band"] == "high" && MemoryRelation.canonical_relation_type(payload["relation_type"].to_s) != "part_of"
      end.map(&:id)
      MaintenanceReportRow.where(id: ids)
    end
  end
end

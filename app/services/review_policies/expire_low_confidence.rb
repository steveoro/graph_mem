# frozen_string_literal: true

module ReviewPolicies
  # Expires active rows with confidence below THRESHOLD that nobody touched for
  # review_expire_low_confidence_days. An expiring suppression keeps them away for SUPPRESS_FOR,
  # after which new evidence can propose them again.
  class ExpireLowConfidence < Base
    THRESHOLD = 0.4
    SUPPRESS_FOR = 90.days

    private

    def verb = "expired"

    def candidates
      eligible.order(:updated_at).limit(PER_RUN).to_a
    end

    def eligible
      MaintenanceReportRow.active.where(confidence: ...THRESHOLD)
                          .where(updated_at: ...AppSettings.review_number(:review_expire_low_confidence_days).days.ago)
    end

    def act(row)
      return false unless eligible.exists?(id: row.id)

      change!(row, { status: "expired", resolution_reason: "expired: low confidence, untouched" },
              suppression: { reason: "expired by policy", source: "expired", expires_at: SUPPRESS_FOR.from_now })
    end
  end
end

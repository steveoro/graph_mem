# frozen_string_literal: true

module ReviewPolicies
  # Brings snoozed rows back when their snooze ends: status active, no end date, and the
  # "snoozed" suppression goes. Always on. Rows ignored before UI-5a have no end and stay ignored.
  class SnoozeExpiry < Base
    private

    def enabled? = true
    def verb = "reopened"

    def candidates
      MaintenanceReportRow.snoozed.where(expires_at: ..Time.current).order(:expires_at).limit(PER_RUN).to_a
    end

    def act(row)
      return false unless row.ignored? && row.expires_at&.<=(Time.current)

      change!(row, { status: "active", expires_at: nil }, unsuppress: "snoozed")
    end
  end
end

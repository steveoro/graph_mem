# frozen_string_literal: true

module ReviewPolicies
  # Dismisses pending rows that point at something gone (an entity, observation or relation), or
  # whose effect already holds (the relation exists, the observation is already inactive, the
  # entity already sits under the parent). No suppression: a deleted id can't come back.
  class Dangling < Base
    private

    def verb = "dismissed"

    def candidates
      MaintenanceReportRow.pending.find_each.lazy.select { |row| DanglingCheck.reason(row) }.first(PER_RUN)
    end

    def act(row)
      return false unless %w[active ignored].include?(row.status)

      reason = DanglingCheck.reason(row)
      return false unless reason

      change!(row, { status: "dismissed", dismissed_at: Time.current, resolution_reason: "dangling: #{reason}", expires_at: nil })
    end
  end
end

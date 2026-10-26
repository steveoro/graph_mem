# frozen_string_literal: true

module ReviewPolicies
  # Dismisses active stale_memory rows whose signal resolved itself (StaleMemoryScanner no longer
  # flags any of their observations). No suppression: the signal may come back.
  class NoLongerFlagged < Base
    private

    def verb = "dismissed"

    def candidates
      MaintenanceReportRow.active.where(kind: "stale_memory").find_each.lazy
                          .select { |row| unflagged?(row) }.first(PER_RUN)
    end

    def act(row)
      return false unless row.active? && unflagged?(row)

      change!(row, { status: "dismissed", dismissed_at: Time.current, resolution_reason: "no longer flagged" })
    end

    def unflagged?(row)
      payload = row.effective_payload
      StaleMemoryScanner.still_flagged_ids(entity_id: payload["entity_id"].to_i, signal: payload["signal"],
                                           observation_ids: Array(payload["observation_ids"])).empty?
    end
  end
end

# frozen_string_literal: true

module ReviewPolicies
  # Dismisses pending pair rows by their keyword paths (1.78.0, SubjectCheck): contradiction rows
  # the detector would no longer pair, "Outdated by a fact" rows for unrelated facts (judged ones too,
  # since 1.80.0), and unjudged ones that aren't the same fact with a different detail (1.82.0).
  # Cleans the backlog the generators seeded before they read the paths. Off with fact keywords off. No suppression: a fact whose text changes is judged again.
  # Reverse: Undo the run, or Restore the row.
  class NoSharedSubject < Base
    private

    def verb = "dismissed"

    def enabled?
      super && AppSettings.fact_keywords_enabled?
    end

    def candidates
      MaintenanceReportRow.pending.where(kind: SubjectCheck::KINDS).find_each.lazy
                          .select { |row| SubjectCheck.status(row) == :dismiss }.first(PER_RUN)
    end

    def act(row)
      return false unless %w[active ignored].include?(row.status)

      reason = SubjectCheck.reason(row)
      return false unless reason

      change!(row, { status: "dismissed", dismissed_at: Time.current, resolution_reason: reason, expires_at: nil })
    end
  end
end

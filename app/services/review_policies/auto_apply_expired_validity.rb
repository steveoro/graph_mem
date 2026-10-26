# frozen_string_literal: true

module ReviewPolicies
  # stale_memory rows whose writer-set validity elapsed (signal valid_until_elapsed): the apply
  # marks the observations obsolete. At most 100 per run.
  class AutoApplyExpiredValidity < AutoApply
    PER_RUN = 100

    private

    def eligible
      MaintenanceReportRow.active.where(kind: "stale_memory")
                          .where("COALESCE(JSON_VALUE(edited_payload, '$.signal'), JSON_VALUE(payload, '$.signal')) = ?", "valid_until_elapsed")
    end
  end
end

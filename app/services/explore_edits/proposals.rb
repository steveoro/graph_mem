# frozen_string_literal: true

class ExploreEdits
  # Propose deletion (UI-4b W7): Explore never deletes an entity; it seeds a `delete_entity` row in
  # Review & Fix (scan review, source "operator"). Nothing in the graph changes, so there is no
  # change set: the seeded row is the record.
  module Proposals
    ROOT_PROPOSAL = "Project roots can't be proposed for deletion from Explore."

    # @param entity [MemoryEntity]
    # @param reason [String, nil] at most MAX_REASON_LENGTH characters
    # @return [Hash] with `review_row_uuid:` (the new row, or the pending one already there)
    def propose_deletion(entity, reason: nil)
      return refused(ROOT_PROPOSAL) if project_root?(entity)
      return refused("The reason is too long (at most #{MAX_REASON_LENGTH} characters).") if reason.to_s.length > MAX_REASON_LENGTH

      item = { kind: "delete_entity", entity_id: entity.id, entity_name: entity.name, entity_type: entity.entity_type,
               reason: reason.to_s.strip.presence || "proposed from Explore" }
      row = CompactionReviewService.seed_report(report_type: "scan_review", source: "operator", items: [ item ]).first
      return proposed("Deletion proposed for review.", entity, row) if row

      pending = MaintenanceReportRow.where(report_type: "scan_review", status: "active",
                                           signature: CompactionReviewService.signature_for("delete_entity", item)).order(:id).first
      return proposed("Already proposed.", entity, pending) if pending

      refused("Not proposed: Review & Fix suppresses this suggestion (it was dismissed before).")
    end

    private

    def proposed(message, entity, row)
      done(message, entity, changed: [], review_row_uuid: row.row_uuid)
    end
  end
end

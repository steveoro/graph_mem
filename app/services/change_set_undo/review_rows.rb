# frozen_string_literal: true

class ChangeSetUndo
  # Reverts the review-row and suppression sections of a change set. Rows that the cleanup job
  # deleted, or that changed since, are skipped and reported, never a conflict. The undo set
  # records the reverse changes, so undoing the undo (redo) runs this same code.
  class ReviewRows
    FIELDS = CompactionReviewService::ChangeRecording::REVIEW_FIELDS

    # @param change_set [ChangeSet] the set being undone
    # @param context [ChangeSet::Context] the undo set being recorded
    # @param effects [ChangeSetUndo::Effects]
    def initialize(change_set, context, effects)
      @change_set = change_set
      @context = context
      @effects = effects
    end

    def call
      @change_set.section(:review_rows).reverse_each { |entry| revert_row(entry) }
      delete_created_suppressions
      reinsert_deleted_suppressions
    end

    private

    def revert_row(entry)
      row = MaintenanceReportRow.lock.find_by(id: entry["id"])
      short = entry["row_uuid"].to_s.first(8)
      return @effects.skipped << "review row #{short} was deleted" unless row
      unless row.status == entry.dig("after", "status")
        return @effects.skipped << "review row #{short} is now #{row.status}"
      end

      before = fields(row)
      row.update!(entry["before"].slice(*FIELDS))
      @context.note_review_row!(row, before: before, after: fields(row))
    end

    def delete_created_suppressions
      ids = @change_set.section(:suppressions_created).map { |entry| entry["id"] }
      return if ids.empty?

      scope = MaintenanceReportSuppression.where(id: ids)
      deleted = scope.map { |suppression| ChangeSet.snapshot_attributes(suppression) }
      scope.delete_all
      @context.note_suppressions!(deleted: deleted)
    end

    def reinsert_deleted_suppressions
      created = @change_set.section(:suppressions_deleted).filter_map do |attrs|
        next if MaintenanceReportSuppression.exists?(report_type: attrs["report_type"], signature: attrs["signature"])

        attrs = attrs.slice(*MaintenanceReportSuppression.column_names)
        attrs = attrs.except("id") if MaintenanceReportSuppression.exists?(id: attrs["id"])
        MaintenanceReportSuppression.create!(attrs)
      end
      @context.note_suppressions!(created: created)
    end

    def fields(row)
      ChangeSet.snapshot_attributes(row).slice(*FIELDS)
    end
  end
end

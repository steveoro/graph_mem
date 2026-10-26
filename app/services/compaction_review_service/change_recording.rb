# frozen_string_literal: true

class CompactionReviewService
  # UI-4a: each review action is a change set (`review.<action>`). Graph writes inside it are
  # recorded through Auditable; this module adds what the audit trail doesn't cover: the review
  # row's status fields before and after, and the suppression rows created or deleted.
  # Extended into CompactionReviewService, so the helpers are private class methods.
  module ChangeRecording
    REVIEW_FIELDS = %w[status applied_at dismissed_at resolution_reason].freeze
    # Payload paths that name the entity a row is about, most specific first.
    ANCHOR_PATHS = [ %w[entity_id], %w[source_id], %w[from_id], %w[from_entity_id], %w[entity_a entity_id] ].freeze
    PAST_TENSE = {
      "apply" => "applied", "bulk_apply" => "applied", "dismiss" => "dismissed",
      "bulk_dismiss" => "dismissed", "restore" => "restored", "ignore" => "ignored"
    }.freeze

    private

    # Opens (or joins) the `review.<action>` change set.
    # @param action [String] a key of PAST_TENSE
    # @param row [MaintenanceReportRow, nil] the single row acted on, when there is one
    # @return [Object] the block's value
    def record_review(action, row = nil, &)
      summary = row ? "#{PAST_TENSE.fetch(action)} #{row.kind} suggestion" : "#{PAST_TENSE.fetch(action)} suggestions"
      ChangeSet.record(kind: "review.#{action}", summary: summary, subject: row && review_anchor(row), &)
    end

    # Runs the block (which updates `row`) and notes the row's review fields before and after.
    # @return [Object] the block's value
    def track_review_row(row)
      before = review_fields(row)
      result = yield
      Current.change_set&.note_review_row!(row, before: before, after: review_fields(row))
      result
    end

    # @return [Hash{String => Object}] JSON-ready review fields
    def review_fields(row)
      REVIEW_FIELDS.to_h { |field| [ field, row.public_send(field) ] }.as_json
    end

    def review_anchor(row)
      payload = row.effective_payload.to_h.deep_stringify_keys
      id = ANCHOR_PATHS.lazy.map { |path| payload.dig(*path) }.find(&:present?)
      id.to_s.match?(/\A\d+\z/) ? MemoryEntity.find_by(id: id.to_i) : nil
    end

    def note_suppressions(created: [], deleted: [])
      Current.change_set&.note_suppressions!(created: created, deleted: deleted)
    end
  end
end

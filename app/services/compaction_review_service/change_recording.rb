# frozen_string_literal: true

class CompactionReviewService
  # UI-4a: each review action is a change set (`review.<action>`). Graph writes inside it are
  # recorded through Auditable; this module adds what the audit trail doesn't cover: the review
  # row's fields before and after, and the suppression rows created or deleted. UI-5a links each
  # row to the set that changed it (`change_set_id`), records who resolved it (`resolved_by`) and
  # returns the undo handle with the action's result.
  # Extended into CompactionReviewService, so the helpers are private class methods.
  module ChangeRecording
    REVIEW_FIELDS = %w[status applied_at dismissed_at resolution_reason resolved_by change_set_id expires_at].freeze
    # Payload paths that name the entity a row is about, most specific first.
    ANCHOR_PATHS = [ %w[entity_id], %w[source_id], %w[from_id], %w[from_entity_id], %w[entity_a entity_id] ].freeze
    PAST_TENSE = {
      "apply" => "applied", "bulk_apply" => "applied", "dismiss" => "dismissed", "bulk_dismiss" => "dismissed",
      "restore" => "restored", "ignore" => "ignored", "snooze" => "snoozed"
    }.freeze

    # @param actor [String, nil] Current.actor
    # @return [String] the resolved_by value: operator, agent, policy:<name> or generator
    def self.resolver_for(actor)
      case actor.to_s
      when /\Aoperator:/ then "operator"
      when /\A(mcp|api):/ then "agent"
      when /\Apolicy:[a-z_]+\z/ then actor.to_s
      else "generator"
      end
    end

    # For ReviewPolicies: changes a row the caller has locked, inside the open (policy) change set,
    # like an operator action would: change_set_id, resolved_by and the undo notes.
    # @param attrs [Hash] the row update (status, resolution_reason, …)
    # @param suppression [Hash, nil] `{ reason:, source:, expires_at: }` to suppress the signature
    # @param unsuppress [String, nil] delete the row's suppressions with this source first
    def policy_change!(row, attrs, suppression: nil, unsuppress: nil)
      if unsuppress
        scope = MaintenanceReportSuppression.where(report_type: row.report_type, signature: suppression_signatures(row),
                                                   source: unsuppress)
        deleted = scope.map { |suppression_row| ChangeSet.snapshot_attributes(suppression_row) }
        scope.delete_all
        note_suppressions(deleted: deleted) if deleted.any?
      end
      suppress(row, **suppression) if suppression
      track_review_row(row, attrs)
    end

    private

    # Opens (or joins) the `review.<action>` change set. A hash result gains the undo handle:
    # `change_set_uuid` (nil when nothing was written), `undoable` and `not_undoable_reason`.
    # @param action [String] a key of PAST_TENSE
    # @param row [MaintenanceReportRow, nil] the single row acted on, when there is one
    # @return [Object] the block's value
    def record_review(action, row = nil)
      summary = row ? "#{PAST_TENSE.fetch(action)} #{row.kind} suggestion" : "#{PAST_TENSE.fetch(action)} suggestions"
      ChangeSet.record(kind: "review.#{action}", summary: summary, subject: row && review_anchor(row)) do |context|
        result = yield
        result.is_a?(Hash) ? result.merge(undo_handle(context)) : result
      end
    end

    def undo_handle(context)
      set = context.id && ChangeSet.find_by(id: context.id)
      { change_set_uuid: set&.uuid, undoable: set ? set.undoable? : false, not_undoable_reason: set&.not_undoable_reason }
    end

    # Updates the row with `attrs` plus its change set and resolver, and notes the review fields
    # before and after (so ChangeSetUndo::ReviewRows can write them back).
    def track_review_row(row, attrs)
      before = review_fields(row)
      status = attrs.fetch(:status, row.status)
      resolved = MaintenanceReportRow::RESOLVED_STATUSES.include?(status)
      row.update!({ resolved_by: resolved ? ChangeRecording.resolver_for(Current.actor) : nil }
                    .merge(attrs, change_set_id: Current.change_set&.persist!))
      Current.change_set&.note_review_row!(row, before: before, after: review_fields(row))
    end

    # @return [Hash{String => Object}] JSON-ready review fields
    def review_fields(row)
      ChangeSet.snapshot_attributes(row).slice(*REVIEW_FIELDS)
    end

    def review_anchor(row)
      payload = row.effective_payload.to_h.deep_stringify_keys
      id = ANCHOR_PATHS.lazy.map { |path| payload.dig(*path) }.find(&:present?)
      id.to_s.match?(/\A\d+\z/) ? MemoryEntity.find_by(id: id.to_i) : nil
    end

    def note_suppressions(created: [], deleted: [])
      Current.change_set&.note_suppressions!(created: created, deleted: deleted)
    end

    # Replaces the row's suppressions (an expiring one becomes permanent, and the other way round);
    # both the deleted and the created rows are noted, so undo brings the old ones back.
    def suppress(row, reason:, source: "dismissed", expires_at: nil)
      suppression_signatures(row).each do |signature|
        deleted, created = MaintenanceReportSuppression.replace!(report_type: row.report_type, signature: signature,
                                                                 kind: row.kind, reason: reason, source: source,
                                                                 expires_at: expires_at)
        note_suppressions(created: Array(created), deleted: deleted)
      end
    end
  end
end

# frozen_string_literal: true

require "digest"

# Group actions on the Review page (UI-5b C1): apply, dismiss or snooze the pending rows of one
# group (`group_key`) in a single change set. Apply is limited to ReviewRowClassifier::SAFE_BULK_KINDS
# and must present the token from its preview: if the eligible rows changed meanwhile, nothing is
# written and the answer is a conflict listing what changed.
#
#   preview = ReviewGroupActions.preview(group_key: "relationship_proposal|3-9", op: "apply", min_confidence: 0.8)
#   ReviewGroupActions.apply(group_key: …, row_uuids: preview[:included].map { _1[:row_uuid] }, token: preview[:token])
#   # => { success: true, status: :ok, message: "Applied 4 suggestion(s)", change_set_uuid: "…", undoable: true, … }
class ReviewGroupActions
  GROUP_CAP = 100
  OPS = %w[apply dismiss snooze].freeze
  KINDS = { "apply" => "review.group_apply", "dismiss" => "review.group_dismiss", "snooze" => "review.group_snooze" }.freeze
  MAX_EFFECTS = 20
  PAST = { "apply" => "Applied", "dismiss" => "Dismissed", "snooze" => "Snoozed" }.freeze

  class << self
    # @param group_key [String]
    # @param op [String] apply, dismiss or snooze
    # @param min_confidence [Float, nil] apply only rows at or above it
    # @return [Hash] `{ included: [row hashes], excluded: [row hashes + reason], effects: [String], token: String }`
    def preview(group_key:, op:, min_confidence: nil)
      included, excluded = partition(group_key, op.to_s, min_confidence)
      {
        op: op.to_s, group_key: group_key, min_confidence: min_confidence,
        included: included.map { |row| describe(row) },
        excluded: excluded.map { |row, reason| describe(row).merge(reason: reason) },
        effects: effects(included, op.to_s),
        token: token(included, op.to_s, min_confidence)
      }
    end

    # Applies the group's safe rows, if they are still the ones the preview showed.
    # @return [Hash] a service-style result with `status` (:ok, :conflict, :unprocessable)
    def apply(group_key:, row_uuids:, token:, min_confidence: nil)
      included, = partition(group_key, "apply", min_confidence)
      if token != token(included, "apply", min_confidence)
        changed = (Array(row_uuids) - included.map(&:row_uuid)) | (included.map(&:row_uuid) - Array(row_uuids))
        return { success: false, status: :conflict, error: "The group changed since the preview: review it again", changed: changed }
      end
      return { success: false, status: :unprocessable, error: "Nothing in this group can be applied in bulk" } if included.empty?

      run("apply", included) do |row|
        CompactionReviewService.apply(row.row_uuid, {}, report_type: row.report_type)
      end
    end

    # Dismisses the group's pending rows among `row_uuids` (any kind; writes suppressions).
    def dismiss(group_key:, row_uuids:, reason: nil)
      rows = pending_rows(group_key, row_uuids)
      run("dismiss", rows) { |row| CompactionReviewService.dismiss(row.row_uuid, reason: reason, report_type: row.report_type) }
    end

    # Snoozes the group's pending rows among `row_uuids` for `days` (any kind; expiring suppressions,
    # a permanent one is kept).
    def snooze(group_key:, row_uuids:, days: CompactionReviewService::SNOOZE_DAYS)
      rows = pending_rows(group_key, row_uuids)
      run("snooze", rows) { |row| CompactionReviewService.snooze(row.row_uuid, days: days, report_type: row.report_type) }
    end

    private

    # Pending rows of the group, highest priority first (no root-first key: Decision 13).
    def group_rows(group_key)
      MaintenanceReportRow.pending.by_group(group_key).order(priority: :desc, id: :asc).limit(GROUP_CAP * 2).to_a
    end

    # @return [Array(Array<MaintenanceReportRow>, Array<Array(MaintenanceReportRow, String)>)]
    def partition(group_key, op, min_confidence)
      raise ArgumentError, "unknown group action: #{op}" unless OPS.include?(op)

      included = []
      excluded = []
      group_rows(group_key).each do |row|
        reason = exclusion(row, op, min_confidence) || ("over the cap of #{GROUP_CAP}" if included.size >= GROUP_CAP)
        reason ? excluded << [ row, reason ] : included << row
      end
      [ included, excluded ]
    end

    def exclusion(row, op, min_confidence)
      return nil unless op == "apply"
      return "choose a side per row" if ReviewRowClassifier::CHOICE_KINDS.include?(row.kind)
      return "destructive: apply one by one" unless ReviewRowClassifier::SAFE_BULK_KINDS.include?(row.kind)
      return "below confidence #{min_confidence}" if min_confidence && row.confidence.to_f < min_confidence.to_f

      nil
    end

    def pending_rows(group_key, row_uuids)
      MaintenanceReportRow.pending.by_group(group_key).where(row_uuid: Array(row_uuids))
                          .order(priority: :desc, id: :asc).limit(GROUP_CAP).to_a
    end

    # One change set for the whole group; each row's own action joins it.
    def run(op, rows)
      return { success: false, status: :unprocessable, error: "No pending suggestions selected in this group" } if rows.empty?

      ChangeSet.record(kind: KINDS.fetch(op), summary: "#{op} group: #{rows.size} suggestion(s)", subject: nil) do |context|
        results = rows.map { |row| yield(row) }
        failed = results.count { |result| !result[:success] }
        message = "#{PAST.fetch(op)} #{rows.size - failed} suggestion(s)"
        message += "; #{failed} failed" if failed.positive?
        set = context.id && ChangeSet.find_by(id: context.id)
        { success: failed.zero?, status: :ok, message: message, change_set_uuid: set&.uuid,
          undoable: set ? set.undoable? : false, not_undoable_reason: set&.not_undoable_reason }
      end
    end

    def describe(row)
      { row_uuid: row.row_uuid, kind: row.kind, status: row.status, priority: row.priority, confidence: row.confidence&.to_f }
    end

    def effects(rows, op)
      return [ "#{rows.size} suggestion(s) #{op == 'dismiss' ? 'dismissed (suppressed)' : 'snoozed for 30 days'}" ] unless op == "apply"

      lines = rows.flat_map { |row| CompactionReviewApplier.preview(row)[:effects] }
      lines.size > MAX_EFFECTS ? lines.first(MAX_EFFECTS) + [ "…and #{lines.size - MAX_EFFECTS} more" ] : lines
    end

    def token(rows, op, min_confidence)
      Digest::SHA256.hexdigest([ rows.map(&:id).sort.join(","), op, min_confidence.to_s ].join("|"))
    end
  end
end

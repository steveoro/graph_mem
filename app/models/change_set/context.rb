# frozen_string_literal: true

class ChangeSet
  # The in-memory side of an open change set (`Current.change_set`). Writers report to it
  # (Auditable, the merge snapshot, the review actions) and it keeps the `change_sets` row in step:
  # inserted by the first write, updated with one statement per later change, always inside the
  # caller's transaction. Each transaction it touches gets an after_rollback hook that restores
  # the in-memory state to what it was before that transaction, so a rolled-back write (or a merge
  # retry) leaves no stale id or snapshot entry behind.
  #
  # Strategy (one-way): `audit` → `merge` (first merge step, if no other write came first) →
  # `none` with a reason: `mixed_merge`, `hard_delete` (an entity or observation deleted outside a
  # merge), `audit_incomplete` (an audit row failed) or `snapshot_too_large`.
  class Context
    HARD_DELETE_TYPES = %w[MemoryEntity MemoryObservation].freeze
    # Sections dropped when the snapshot exceeds MAX_SNAPSHOT_BYTES; their sizes are kept.
    LARGE_SECTIONS = %w[merges review_rows suppressions_created suppressions_deleted redo_merges].freeze

    attr_reader :uuid, :kind, :actor, :summary, :id, :strategy, :not_undoable_reason

    # @param kind [String] see ChangeSet::KINDS
    # @param actor [String, nil]
    # @param actor_claim [String, nil] display only (ActorClaim)
    # @param summary [String, nil]
    # @param subject [ActiveRecord::Base, nil]
    # @param undo_of [ChangeSet, nil]
    def initialize(kind:, actor:, actor_claim: nil, summary: nil, subject: nil, undo_of: nil)
      @uuid = SecureRandom.uuid
      @kind = kind
      @actor = actor
      @actor_claim = actor_claim
      @undo_of_id = undo_of&.id
      @subject_type = subject&.class&.name
      @subject_id = subject&.id
      @summary = summary
      @strategy = "audit"
      @not_undoable_reason = nil
      @sections = {}
      @dropped = {}
      @audit_failures = 0
      @non_merge_write = false
      @merge_seen = false
      @merge_depth = 0
      @version = 0
      @tracked = []
    end

    # Inserts the row on first use (in the current transaction) and returns its id.
    # @return [Integer]
    def persist!
      return @id if @id

      track_rollback!
      @persisted_at = Time.current
      @id = ChangeSet.create!(row_attributes.merge(uuid: @uuid, kind: @kind, actor: @actor, actor_claim: @actor_claim, undo_of_id: @undo_of_id)).id
    end

    # Called by Auditable before each audit row: picks the subject and moves the strategy.
    # @param record [ActiveRecord::Base] the audited record
    # @param action [String] "create", "update" or "delete"
    def note_audit!(record, action)
      changed = mutate! do
        claim_subject(record)
        next if @merge_depth.positive?

        @non_merge_write = true
        downgrade!("mixed_merge") if @merge_seen
        downgrade!("hard_delete") if action == "delete" && HARD_DELETE_TYPES.include?(record.class.name)
      end
      persist_or_flush!(changed)
    end

    # An audit row could not be written: the set can no longer be inverted reliably.
    def note_audit_failure!
      mutate! do
        @audit_failures += 1
        downgrade!("audit_incomplete")
      end
      persist_or_flush!(true)
    end

    # Marks the writes in the block as one merge step (their audit rows don't make the set mixed).
    # @return [Object] the block's value
    def within_merge_step
      changed = mutate! do
        @merge_seen = true
        if @non_merge_write
          downgrade!("mixed_merge")
        elsif @strategy == "audit"
          @strategy = "merge"
        end
      end
      persist_or_flush!(changed)
      @merge_depth += 1
      begin
        yield
      ensure
        @merge_depth -= 1
      end
    end

    # @param step [Hash] see EntityMergeSnapshot
    # @raise [ActiveRecord::ActiveRecordError] when the snapshot can't be written
    def add_merge_step!(step)
      append!("merges", step)
    end

    # Records a review row's status change so ChangeSetUndo::ReviewRows can write `before` back.
    # @param row [MaintenanceReportRow]
    # @param before [Hash] review fields before the action
    # @param after [Hash] review fields after it
    def note_review_row!(row, before:, after:)
      return if before == after

      append!("review_rows", { "id" => row.id, "row_uuid" => row.row_uuid, "before" => before, "after" => after })
    end

    # @param created [Array<MaintenanceReportSuppression>] rows this action inserted
    # @param deleted [Array<Hash>] full attribute hashes of rows this action deleted
    def note_suppressions!(created: [], deleted: [])
      created_entries = created.map { |s| { "id" => s.id, "report_type" => s.report_type, "signature" => s.signature } }
      append!("suppressions_created", *created_entries) if created_entries.any?
      append!("suppressions_deleted", *deleted) if deleted.any?
    end

    # The merges an undo reverted, in their original order, so undoing the undo re-runs them.
    # @param pairs [Array<Hash>] `{ "source_id" =>, "target_id" => }`
    def note_redo_merges!(pairs)
      append!("redo_merges", *pairs) if pairs.any?
    end

    # What a toast needs to offer Undo, read back from the stored row (nil uuid when nothing was
    # written, so no set exists).
    # @return [Hash] `{ change_set_uuid:, undoable:, not_undoable_reason: }`
    def undo_handle
      set = @id && ChangeSet.find_by(id: @id)
      { change_set_uuid: set&.uuid, undoable: set ? set.undoable? : false, not_undoable_reason: set&.not_undoable_reason }
    end

    # @return [Hash] the snapshot as stored ("v" plus the non-empty sections)
    def snapshot
      data = { "v" => ChangeSet::SNAPSHOT_VERSION }
      @sections.each { |name, entries| data[name] = entries if entries.any? }
      data["dropped"] = @dropped.dup if @dropped.any?
      data["audit_failures"] = @audit_failures if @audit_failures.positive?
      data
    end

    private

    def row_attributes
      data = snapshot
      bytes = data.to_json.bytesize
      if bytes > ChangeSet::MAX_SNAPSHOT_BYTES
        downgrade!("snapshot_too_large")
        drop_large_sections!
        data = snapshot
        bytes = data.to_json.bytesize
      end
      {
        summary: @summary&.truncate(255),
        subject_type: @subject_type,
        subject_id: @subject_id,
        undo_strategy: @strategy,
        not_undoable_reason: @not_undoable_reason,
        undoable_until: @strategy == "none" ? nil : @persisted_at + ChangeSet::WINDOWS.fetch(@strategy),
        snapshot: data,
        snapshot_bytes: bytes
      }
    end

    # Over the cap: keep counts instead of the large sections. Once shrunk, the set is `none`
    # and later entries for those sections are only counted (see #append!).
    def drop_large_sections!
      LARGE_SECTIONS.each do |name|
        next unless @sections.key?(name)

        @dropped[name] = @dropped.fetch(name, 0) + @sections.delete(name).size
      end
    end

    def append!(name, *entries)
      mutate! do
        if @not_undoable_reason == "snapshot_too_large" && LARGE_SECTIONS.include?(name)
          @dropped[name] = @dropped.fetch(name, 0) + entries.size
        else
          (@sections[name] ||= []).concat(entries)
        end
      end
      persist_or_flush!(true)
    end

    def persist_or_flush!(changed)
      if @id.nil?
        persist!
      elsif changed
        track_rollback!
        ChangeSet.where(id: @id).update_all(row_attributes.merge(updated_at: Time.current))
      end
    end

    def claim_subject(record)
      return if @subject_type

      entity_id = case record
      when MemoryEntity then record.id
      when MemoryObservation then record.memory_entity_id
      when MemoryRelation then record.from_entity_id
      end
      return unless entity_id

      @subject_type = "MemoryEntity"
      @subject_id = entity_id
    end

    def downgrade!(reason)
      return if @strategy == "none"

      @strategy = "none"
      @not_undoable_reason = reason
    end

    # Runs a state change; registers the rollback hook first. Returns true when the stored
    # columns (strategy, reason, subject) changed.
    def mutate!
      track_rollback!
      before = [ @strategy, @not_undoable_reason, @subject_type, @subject_id ]
      yield
      @version += 1
      before != [ @strategy, @not_undoable_reason, @subject_type, @subject_id ]
    end

    # One after_rollback hook per transaction: it restores the state saved on entry. When an outer
    # rollback also runs the hooks of released savepoints, the oldest saved state wins.
    def track_rollback!
      transaction = ActiveRecord::Base.current_transaction
      return unless transaction.open?
      return if @tracked.any? { |tracked| tracked.equal?(transaction) }

      @tracked << transaction
      saved = capture_state
      transaction.after_rollback { restore_state(saved) }
    end

    def capture_state
      {
        id: @id, persisted_at: @persisted_at, strategy: @strategy, reason: @not_undoable_reason,
        subject: [ @subject_type, @subject_id ], sections: @sections.transform_values(&:dup), dropped: @dropped.dup,
        audit_failures: @audit_failures, non_merge_write: @non_merge_write, merge_seen: @merge_seen,
        version: @version
      }
    end

    def restore_state(saved)
      return if saved[:version] > @version

      @id = saved[:id]
      @persisted_at = saved[:persisted_at]
      @strategy = saved[:strategy]
      @not_undoable_reason = saved[:reason]
      @subject_type, @subject_id = saved[:subject]
      @sections = saved[:sections]
      @dropped = saved[:dropped]
      @audit_failures = saved[:audit_failures]
      @non_merge_write = saved[:non_merge_write]
      @merge_seen = saved[:merge_seen]
      @version = saved[:version]
    end
  end
end

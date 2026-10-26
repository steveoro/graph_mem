# frozen_string_literal: true

# Nightly retention for change sets (UI-4a). Snapshots are only needed while a set can be undone
# (merge 7 days, everything else 30), so they are cleared after SNAPSHOT_DAYS. The rows
# themselves stay as long as audit rows point at them (AuditLog::MAX_AGE_DAYS) and are deleted
# once none does. `undo_of_id` is ON DELETE SET NULL, so an undo outliving its original is kept.
class ChangeSetPruneJob < ApplicationJob
  queue_as :low_priority

  SNAPSHOT_DAYS = 30
  BATCH_SIZE = 1_000

  def perform
    ChangeSet.where(created_at: ...SNAPSHOT_DAYS.days.ago).where.not(snapshot: nil)
             .in_batches(of: BATCH_SIZE)
             .update_all(snapshot: nil, snapshot_bytes: nil)

    ChangeSet.where(created_at: ...AuditLog::MAX_AGE_DAYS.days.ago)
             .where("NOT EXISTS (SELECT 1 FROM audit_logs WHERE audit_logs.change_set_id = change_sets.id)")
             .in_batches(of: BATCH_SIZE)
             .delete_all
  end
end

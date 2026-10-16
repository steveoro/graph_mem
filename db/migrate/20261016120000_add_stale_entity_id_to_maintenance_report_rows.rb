# frozen_string_literal: true

# Generated column backing the stale-memory candidate lock. The FOR UPDATE
# scan in CompactionReviewService.stale_memory_candidates must hit a real
# index range — filtering on JSON_VALUE(payload, ...) narrows the RESULT but
# not the LOCK: without an index on the expression, InnoDB X-locks every
# scanned row, which (a) blocks applies on unrelated entities and (b) makes
# concurrent seeds on different entities crash with ER_CHECKREAD.
#
# The index is ONLY (stale_entity_id, report_type): `kind` is implied by the
# generated column (non-NULL only for stale_memory rows), and `status` must
# stay OUT — an apply's update!(status: "approved") would move the row's
# index entry into a range a waiting seed has next-key locked, which InnoDB
# resolves by deadlocking the seed (errno 1213).
#
# COALESCE(edited_payload, payload) mirrors effective_payload semantics, so
# operator entity_id overrides keep matching. The REGEXP guard yields NULL
# for non-numeric payloads instead of raising a strict-mode CAST error on
# write. FLOOR(DECIMAL) mirrors Ruby's `to_i` for non-negative decimals —
# "42.0" and "42.5" both give 42 (a string CAST AS UNSIGNED would error or
# round instead); a `[.]` character class writes the literal dot without a
# backslash, which neither the SQL string literal nor the dump escapes.
class AddStaleEntityIdToMaintenanceReportRows < ActiveRecord::Migration[8.1]
  def up
    add_column :maintenance_report_rows, :stale_entity_id, :virtual,
               type: :bigint,
               as: "CASE WHEN `kind` = 'stale_memory' " \
                   "AND COALESCE(JSON_VALUE(`edited_payload`, '$.entity_id'), " \
                   "JSON_VALUE(`payload`, '$.entity_id')) REGEXP '^[0-9]+([.][0-9]+)?$' " \
                   "THEN FLOOR(CAST(COALESCE(JSON_VALUE(`edited_payload`, '$.entity_id'), " \
                   "JSON_VALUE(`payload`, '$.entity_id')) AS DECIMAL(30,6))) ELSE NULL END"
    add_index :maintenance_report_rows, %i[stale_entity_id report_type],
              name: "index_mrr_stale_candidates"
  end

  def down
    # By name, not column list: the index definition has changed across
    # revisions of this migration, and column-matched removal would fail on
    # databases carrying an older shape.
    remove_index :maintenance_report_rows, name: "index_mrr_stale_candidates"
    remove_column :maintenance_report_rows, :stale_entity_id
  end
end

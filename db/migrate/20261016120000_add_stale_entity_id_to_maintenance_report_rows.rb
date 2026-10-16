# frozen_string_literal: true

# Generated column backing the stale-memory candidate lock. The FOR UPDATE
# scan in CompactionReviewService.stale_memory_candidates must hit a real
# index range — filtering on JSON_VALUE(payload, ...) narrows the RESULT but
# not the LOCK: without an index on the expression, InnoDB X-locks every
# scanned row, which (a) blocks applies on unrelated entities and (b) makes
# concurrent seeds on different entities crash with ER_CHECKREAD.
#
# COALESCE(edited_payload, payload) mirrors effective_payload semantics, so
# operator entity_id overrides keep matching. The REGEXP guard yields NULL
# for non-numeric payloads instead of raising a strict-mode CAST error on
# write. BIGINT (not varchar) keeps the composite index under InnoDB's
# 3072-byte key limit alongside three varchar(255) columns.
class AddStaleEntityIdToMaintenanceReportRows < ActiveRecord::Migration[8.1]
  def change
    add_column :maintenance_report_rows, :stale_entity_id, :virtual,
               type: :bigint,
               as: "CASE WHEN `kind` = 'stale_memory' " \
                   "AND COALESCE(JSON_VALUE(`edited_payload`, '$.entity_id'), " \
                   "JSON_VALUE(`payload`, '$.entity_id')) REGEXP '^[0-9]+$' " \
                   "THEN CAST(COALESCE(JSON_VALUE(`edited_payload`, '$.entity_id'), " \
                   "JSON_VALUE(`payload`, '$.entity_id')) AS UNSIGNED) ELSE NULL END"
    add_index :maintenance_report_rows, %i[stale_entity_id report_type kind status],
              name: "index_mrr_stale_candidates"
  end
end

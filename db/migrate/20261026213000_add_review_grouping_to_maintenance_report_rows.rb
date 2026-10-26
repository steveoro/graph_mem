# frozen_string_literal: true

# UI-5a: grouping, priority and resolution columns on review rows, and expiring suppressions.
# Schema only: ReviewRowClassifier.backfill! fills existing rows outside the migration. No foreign
# keys: rows outlive the change sets the prune job empties, and anchors can be deleted (the
# `dangling` policy looks for exactly that).
class AddReviewGroupingToMaintenanceReportRows < ActiveRecord::Migration[8.1]
  def change
    add_column :maintenance_report_rows, :group_key, :string, limit: 191
    add_column :maintenance_report_rows, :anchor_entity_id, :bigint
    add_column :maintenance_report_rows, :project_id, :bigint
    add_column :maintenance_report_rows, :priority, :integer, null: false, default: 0
    add_column :maintenance_report_rows, :confidence, :decimal, precision: 4, scale: 3
    add_column :maintenance_report_rows, :expires_at, :datetime
    add_column :maintenance_report_rows, :resolved_by, :string, limit: 64
    add_column :maintenance_report_rows, :change_set_id, :bigint

    add_index :maintenance_report_rows, [ :report_type, :status, :priority ], name: "index_mrr_on_type_status_priority"
    add_index :maintenance_report_rows, [ :report_type, :status, :group_key ], name: "index_mrr_on_type_status_group"
    add_index :maintenance_report_rows, [ :project_id, :status ], name: "index_mrr_on_project_status"
    add_index :maintenance_report_rows, :expires_at
    add_index :maintenance_report_rows, :change_set_id

    add_column :maintenance_report_suppressions, :expires_at, :datetime
    add_column :maintenance_report_suppressions, :source, :string, limit: 16, null: false, default: "dismissed"
    add_index :maintenance_report_suppressions, :expires_at
  end
end

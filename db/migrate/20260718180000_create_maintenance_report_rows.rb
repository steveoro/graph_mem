# frozen_string_literal: true

class CreateMaintenanceReportRows < ActiveRecord::Migration[8.0]
  def change
    create_table :maintenance_report_rows do |t|
      t.bigint :maintenance_report_id, null: true
      t.string :report_type, null: false
      t.string :row_uuid, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "active"
      t.string :signature, null: false
      t.json :payload, null: false
      t.json :edited_payload
      t.text :resolution_reason
      t.datetime :applied_at
      t.datetime :dismissed_at
      t.timestamps
    end

    add_index :maintenance_report_rows, [ :maintenance_report_id, :row_uuid ], unique: true, name: "index_maintenance_report_rows_on_report_and_uuid"
    add_index :maintenance_report_rows, [ :report_type, :signature ], name: "index_maintenance_report_rows_on_report_type_and_signature"
    add_index :maintenance_report_rows, :status, name: "index_maintenance_report_rows_on_status"
    add_index :maintenance_report_rows, :kind, name: "index_maintenance_report_rows_on_kind"
    add_index :maintenance_report_rows, :dismissed_at, name: "index_maintenance_report_rows_on_dismissed_at"
    add_index :maintenance_report_rows, :applied_at, name: "index_maintenance_report_rows_on_applied_at"

    add_foreign_key :maintenance_report_rows, :maintenance_reports, on_delete: :nullify
  end
end

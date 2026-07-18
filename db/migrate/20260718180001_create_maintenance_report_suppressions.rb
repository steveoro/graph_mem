# frozen_string_literal: true

class CreateMaintenanceReportSuppressions < ActiveRecord::Migration[8.0]
  def change
    create_table :maintenance_report_suppressions do |t|
      t.string :report_type, null: false
      t.string :signature, null: false
      t.string :kind
      t.datetime :dismissed_at
      t.text :reason
      t.timestamps
    end

    add_index :maintenance_report_suppressions,
              [ :report_type, :signature ],
              unique: true,
              name: "index_mrs_on_report_type_and_signature"
    add_index :maintenance_report_suppressions, :signature, name: "index_mrs_on_signature"
    add_index :maintenance_report_suppressions, :dismissed_at, name: "index_mrs_on_dismissed_at"
  end
end

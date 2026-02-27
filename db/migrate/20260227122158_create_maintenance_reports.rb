class CreateMaintenanceReports < ActiveRecord::Migration[8.0]
  def change
    create_table :maintenance_reports do |t|
      t.string :report_type, null: false
      t.json :data, null: false
      t.datetime :created_at, null: false
    end

    add_index :maintenance_reports, :report_type
    add_index :maintenance_reports, :created_at
  end
end

class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.string :auditable_type, null: false
      t.bigint :auditable_id, null: false
      t.string :action, null: false
      t.string :actor
      t.json :changed_fields
      t.datetime :created_at, null: false
    end

    add_index :audit_logs, [ :auditable_type, :auditable_id ]
    add_index :audit_logs, :created_at
  end
end

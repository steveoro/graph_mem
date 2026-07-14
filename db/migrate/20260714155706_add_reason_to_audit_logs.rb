class AddReasonToAuditLogs < ActiveRecord::Migration[8.0]
  def change
    add_column :audit_logs, :reason, :string
  end
end

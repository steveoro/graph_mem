# frozen_string_literal: true

# UI-4a: links each audit row to its change set. Index only, no foreign key: the column is added
# instantly on a large table, and change sets are only deleted after their audit rows are pruned.
class AddChangeSetIdToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :audit_logs, :change_set_id, :bigint, null: true
    add_index :audit_logs, :change_set_id
  end
end

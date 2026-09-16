# frozen_string_literal: true

class CreateToolInvocations < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_invocations do |t|
      t.string :tool_name, null: false
      t.string :client_id, null: false
      t.string :outcome, null: false
      t.string :error_class
      t.string :error_category
      t.integer :duration_ms, null: false
      t.integer :result_size
      t.string :scope
      t.json :argument_keys, null: false
      t.datetime :created_at, null: false
    end

    add_index :tool_invocations, :created_at
    add_index :tool_invocations, [ :tool_name, :created_at ]
    add_index :tool_invocations, [ :client_id, :created_at ]
  end
end

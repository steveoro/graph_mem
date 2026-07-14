# frozen_string_literal: true

class CreateOperationProgresses < ActiveRecord::Migration[8.0]
  def change
    create_table :operation_progresses do |t|
      t.string :operation_id, null: false
      t.string :operation_type, null: false
      t.string :status, null: false, default: "pending"
      t.string :phase
      t.string :message
      t.bigint :current_count, null: false, default: 0
      t.bigint :total_count, null: false, default: 0
      t.decimal :percentage, precision: 5, scale: 1, null: false, default: 0
      t.json :counters
      t.json :details
      t.datetime :started_at
      t.datetime :finished_at
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    add_index :operation_progresses, :operation_id, unique: true
    add_index :operation_progresses, [ :operation_type, :status ]
    add_index :operation_progresses, :created_at
  end
end

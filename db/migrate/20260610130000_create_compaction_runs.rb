# frozen_string_literal: true

class CreateCompactionRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :compaction_runs do |t|
      t.string :status, null: false, default: "idle"
      t.bigint :cursor_entity_id
      t.string :phase
      t.json :stats
      t.boolean :pause_requested, null: false, default: false
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :compaction_runs, :status
    add_index :compaction_runs, :created_at
  end
end

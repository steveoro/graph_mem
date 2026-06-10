# frozen_string_literal: true

class CreateAgentContexts < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_contexts do |t|
      t.string :client_id, null: false
      t.bigint :current_project_id
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :agent_contexts, :client_id, unique: true
    add_index :agent_contexts, :current_project_id
  end
end

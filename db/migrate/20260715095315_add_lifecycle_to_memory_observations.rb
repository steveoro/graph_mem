# frozen_string_literal: true

class AddLifecycleToMemoryObservations < ActiveRecord::Migration[8.0]
  def change
    add_column :memory_observations, :status, :string, null: false, default: "active"
    add_column :memory_observations, :obsoleted_at, :datetime
    add_column :memory_observations, :obsolescence_reason, :string
    add_column :memory_observations, :superseded_by_id, :bigint

    add_index :memory_observations, :status
    add_index :memory_observations, [ :memory_entity_id, :status ]
    add_index :memory_observations, :superseded_by_id
    add_foreign_key :memory_observations,
                    :memory_observations,
                    column: :superseded_by_id,
                    on_delete: :nullify
  end
end

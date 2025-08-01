# frozen_string_literal: true

class RemoveLegacyObservationsCountFromMemoryEntities < ActiveRecord::Migration[8.0]
  def change
    remove_column :memory_entities, :observations_count, :integer
  end
end

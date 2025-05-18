class AddMemoryObservationsCountToMemoryEntities < ActiveRecord::Migration[8.0]
  def change
    add_column :memory_entities, :memory_observations_count, :integer
  end
end

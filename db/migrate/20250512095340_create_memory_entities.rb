class CreateMemoryEntities < ActiveRecord::Migration[8.0]
  def change
    create_table :memory_entities do |t|
      t.string :name
      t.string :entity_type
      t.integer :observations_count, default: 0

      t.timestamps
    end
    add_index :memory_entities, :name, unique: true
    add_index :memory_entities, :entity_type
  end
end

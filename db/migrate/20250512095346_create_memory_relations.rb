class CreateMemoryRelations < ActiveRecord::Migration[8.0]
  def change
    create_table :memory_relations do |t|
      t.references :from_entity, null: false, foreign_key: { to_table: :memory_entities }
      t.references :to_entity, null: false, foreign_key: { to_table: :memory_entities }
      t.string :relation_type

      t.timestamps
    end
    add_index :memory_relations, :relation_type
    add_index :memory_relations, [ :from_entity_id, :to_entity_id, :relation_type ], unique: true, name: 'index_memory_relations_uniqueness'
  end
end

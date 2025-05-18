class CreateMemoryObservations < ActiveRecord::Migration[8.0]
  def change
    create_table :memory_observations do |t|
      t.text :content
      t.references :memory_entity, null: false, foreign_key: true

      t.timestamps
    end
  end
end

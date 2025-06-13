class AddAliasesToMemoryEntities < ActiveRecord::Migration[8.0]
  def change
    add_column :memory_entities, :aliases, :text
  end
end

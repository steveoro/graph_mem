# frozen_string_literal: true

class AddDescriptionAndFulltextToMemoryEntities < ActiveRecord::Migration[8.0]
  def change
    add_column :memory_entities, :description, :text, after: :aliases

    reversible do |dir|
      dir.up do
        execute "CREATE FULLTEXT INDEX index_memory_entities_fulltext ON memory_entities (name, aliases)"
      end
      dir.down do
        execute "DROP INDEX index_memory_entities_fulltext ON memory_entities"
      end
    end
  end
end
